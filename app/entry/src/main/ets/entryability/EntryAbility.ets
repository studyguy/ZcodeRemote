import { UIAbility, Configuration, ConfigurationConstant, errorManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { ZcodeService } from '../service/ZcodeService';
import { BindingStore } from '../store/BindingStore';

const TAG: string = 'ZCRemote';

export default class EntryAbility extends UIAbility {
  private errorListenerId: number = -1;

  onCreate(): void {
    hilog.info(0x0000, TAG, 'onCreate');
    ZcodeService.getInstance().setContext(this.context);
    // 全局未捕获异常兜底：记录日志，避免静默崩溃无从排查
    try {
      const observer: errorManager.ErrorObserver = {
        onUnhandledException(errMsg: string) {
          hilog.error(0x0000, TAG, '[global] uncaught exception: %{public}s', errMsg);
        }
      };
      this.errorListenerId = errorManager.on('error', observer);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'register error observer failed');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code !== 0) {
        hilog.error(0x0000, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      this.applyColorModePreference();
      this.setupFullScreen(windowStage);
      ZcodeService.getInstance().initialize().catch((e: Error) => {
        hilog.error(0x0000, TAG, 'initialize failed: %{public}s', e.message);
      });
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(0x0000, TAG, 'onConfigurationUpdate colorMode=%{public}d', newConfig.colorMode as number);
    this.updateSystemBar();
  }

  /** 应用保存的外观偏好（system/light/dark） */
  private applyColorModePreference(): void {
    const pref = BindingStore.getColorModePref(this.context);
    const appCtx = this.context.getApplicationContext();
    if (pref === 'light') {
      appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } else if (pref === 'dark') {
      appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } else {
      appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    }
  }

  /**
   * 窗口级全屏：布局以真实屏幕为画布，页面自行用状态栏高度做顶部避让，
   * 底部列表内容自然穿过导航条（手势条悬浮叠加在内容上）。
   */
  private setupFullScreen(windowStage: window.WindowStage): void {
    windowStage.getMainWindow((err, mainWin) => {
      if (err !== undefined && err.code !== 0) {
        hilog.error(0x0000, TAG, 'getMainWindow failed: %{public}s', JSON.stringify(err));
        return;
      }
      // 尽早执行：避免首页在高度发布前完成布局
      this.publishAvoidAreaHeights(mainWin);
      mainWin.setWindowLayoutFullScreen(true, (fsErr) => {
        if (fsErr !== undefined && fsErr.code !== 0) {
          hilog.error(0x0000, TAG, 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(fsErr));
        }
        this.publishAvoidAreaHeights(mainWin);
        this.updateSystemBar();
        // 折叠屏展开/收起、转屏等窗口尺寸变化时刷新高度
        mainWin.on('windowSizeChange', () => {
          this.publishAvoidAreaHeights(mainWin);
        });
        // 键盘避让模式（RESIZE：压缩页面而非上抬整页）由 Index 页面 aboutToAppear 设置
        // （setKeyboardAvoidMode 在 UIContext 上，Ability 上下文不可用）
      });
    });
  }

  /** 状态栏/导航条高度写入 AppStorage，供页面做顶部避让与底部缓冲 */
  private publishAvoidAreaHeights(mainWin: window.Window): void {
    try {
      const system = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      // px -> vp：用物理屏幕密度换算（Ability 上下文无 UI 依赖）
      const density = display.getDefaultDisplaySync().densityPixels;
      if (density <= 0) {
        return;
      }
      const statusBar = system.topRect.height / density;
      const navBar = indicator.bottomRect.height / density;
      AppStorage.setOrCreate('statusBarHeight', statusBar);
      AppStorage.setOrCreate('navBarHeight', navBar);
      hilog.info(0x0000, TAG, 'avoid areas: statusBar=%{public}s navBar=%{public}s', String(statusBar), String(navBar));
      this.updateSystemBar();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'publishAvoidAreaHeights failed: %{public}s',
        e instanceof Error ? (e as Error).message : '?');
    }
  }

  /** 系统栏（状态栏/导航条）前景色跟随当前生效的深浅模式 */
  private updateSystemBar(): void {
    try {
      const win = window.getLastWindow(this.context);
      win.then((w: window.Window) => {
        const isDark = this.currentEffectiveDark();
        w.setWindowSystemBarProperties({
          statusBarContentColor: isDark ? '#FFFFFF' : '#1A1C24',
          navigationBarContentColor: isDark ? '#FFFFFF' : '#1A1C24'
        });
      }).catch((e: Error) => {
        hilog.warn(0x0000, TAG, 'getLastWindow failed: %{public}s', (e as Error).message);
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'updateSystemBar exception');
    }
  }

  private currentEffectiveDark(): boolean {
    const config = this.context.resourceManager.getConfigurationSync();
    return (config.colorMode as number) === (ConfigurationConstant.ColorMode.COLOR_MODE_DARK as number);
  }
}
