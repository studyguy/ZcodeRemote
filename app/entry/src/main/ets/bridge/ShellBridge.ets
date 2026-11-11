import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ZCRemote';

/**
 * 壳 ↔ 网页 消息桥 v2（壳优先重构 2026-11-11）
 *
 * 设计原则"数据面窄接口"：
 *  - Web → Shell：注入脚本暴露唯一发送函数 __zrPost(tag, json)，javaScriptProxy 只注册
 *    一个方法 post(tag, payload)，按 tag 分发到回调。事件目录：
 *      hello       {v:2}                          脚本注入即发（握手）
 *      auth        {t,p}                          登录态变化（localStorage 轮询 2s）
 *      theme       "dark|bodyBg|topColor"         主题/取色变化（节流）
 *      view        kind                           网页视图类型（login/connecting/waiting/list/unknown）
 *      attention   "1"/"0"                        审批/提问卡出现/消失（防抖）
 *      taskDone    {title,status}                 任务 运行中→终态
 *      pairInvalid "1"/"0"                        官方配对失效卡出现/消失
 *  - Shell → Web：window.__zrReceive(json) 单函数，cmd: reload / navigate / restoreAuth
 *
 * 旧版 reportXxx 多方法桥已废弃（方法堆积易漂移，事件无版本）。
 */

/** 注入脚本需要的安全化字符串：去反斜杠/引号/换行（ArkTS 正则字面量反斜杠易被吞，运行时替换更稳） */
function sanitizeJs(s: string): string {
  const bs: string = String.fromCharCode(92);
  return s.split(bs).join('')
    .split('"').join('')
    .split(String.fromCharCode(39)).join('')
    .split('\n').join('')
    .split('\r').join('');
}

/**
 * 构造 documentStart 注入脚本。
 * 必须先于页面脚本执行：①重写 navigator.platform（桌面"已连接设备"显示手机名）；
 * ②恢复登录态到 localStorage（ArkWeb localStorage 不保证跨进程持久，auth_mirror 兜底）；
 * ③建立 __zrPost/__zrReceive 通道与全部探测器。
 */
export function buildInjectScript(deviceName: string, token: string, provider: string, restoreAuth: boolean = true): string {
  let safeName = sanitizeJs(deviceName).trim();
  if (safeName.length === 0) {
    safeName = 'HarmonyOS Phone';
  }
  const safeToken = sanitizeJs(token);
  const safeProvider = sanitizeJs(provider);
  let s = '(function(){';
  s += 'if(window.__zrV2){return}window.__zrV2=1;';
  s += 'try{Object.defineProperty(navigator,"platform",{get:function(){return "' + safeName + '"},configurable:true})}catch(e){}';
  if (restoreAuth) {
    s += 'try{var __t="' + safeToken + '";var __p="' + safeProvider + '";' +
      'if(__t&&!localStorage.getItem("zcodejwttoken")){localStorage.setItem("zcodejwttoken",__t)}' +
      'if(__p&&!localStorage.getItem("oauth:active_provider")){localStorage.setItem("oauth:active_provider",__p)}}catch(e){}';
  }
  // 发送通道 + 接收通道
  s += 'function send(a,b){try{if(window.zrNative){window.zrNative.post(a,JSON.stringify(b))}}catch(e){}}';
  s += 'window.__zrReceive=function(m){try{if(m.cmd==="reload"){location.reload()}else if(m.cmd==="navigate"&&m.url){location.href=m.url}else if(m.cmd==="click"&&m.text){var els=document.querySelectorAll("button,div[role=button],a,span");for(var i=0;i<els.length;i++){var t=(els[i].textContent||"").trim();if(t.indexOf(m.text)>=0){els[i].click();send("clicked",{text:m.text});return}}}send("clicked",{text:m.text,found:false})}catch(e){}};';
  s += 'send("hello",{v:2});';
  // 登录态轮询（变化才发）
  s += 'var lastAuth="";function auth(){try{var t=localStorage.getItem("zcodejwttoken")||"";var p=localStorage.getItem("oauth:active_provider")||"";var k=t+"|"+p;if(k!==lastAuth){lastAuth=k;send("auth",{t:t,p:p})}}catch(e){}}' +
    'setInterval(auth,2000);auth();';
  // 主题取色（elementFromPoint 采样顶部不透明背景，节流去重）
  s += 'function nums(s){var o=[],i=0,v="";for(i=0;i<s.length;i++){var c=s.charAt(i);if(c>="0"&&c<="9"){v+=c}else if(v){o.push(+v);v=""}}if(v){o.push(+v)}return o}' +
    'function bgOf(el){try{return getComputedStyle(el).backgroundColor||""}catch(e){return ""}}' +
    'function opaque(n){return n.length>=3&&!(n.length>=4&&n[3]===0)}' +
    'function rep(){try{var cs=document.body?bgOf(document.body):"";var n=nums(cs);if(!opaque(n)){cs=document.documentElement?bgOf(document.documentElement):"";n=nums(cs)}var dark=false;if(opaque(n)){dark=(0.299*n[0]+0.587*n[1]+0.114*n[2])<128}else{try{dark=window.matchMedia("(prefers-color-scheme: dark)").matches}catch(e){}}var top="";try{var e2=document.elementFromPoint(8,2);var g=0;while(e2&&g<6){var c=bgOf(e2);var nn=nums(c);if(opaque(nn)){top=c;break}e2=e2.parentElement;g++}}catch(e){}' +
    'var key=(dark?"1":"0")+"|"+(opaque(n)?cs:"")+"|"+(opaque(nums(top))?top:"");if(key===rep.last){return}rep.last=key;send("theme",key)}catch(e){}}';
  // 视图类型探测（状态胶囊数据源）：文本特征 → kind（含新版 SPA 失效卡文案，2026-11-11）
  s += 'function view(){try{var t=document.body?(document.body.textContent||""):"";' +
    'var k="unknown";' +
    'if(t.indexOf("二维码失效后需要回到桌面端重新连接")>=0||t.indexOf("手机连接已失效")>=0||t.indexOf("校验失败")>=0){k="invalid"}' +
    'else if(t.indexOf("登录后继续")>=0||t.indexOf("连接 BigModel")>=0||t.indexOf("连接 Z.ai")>=0){k="login"}' +
    'else if(t.indexOf("正在连接中转服务")>=0||t.indexOf("正在认证设备")>=0){k="connecting"}' +
    'else if(t.indexOf("等待桌面端确认配对")>=0||t.indexOf("等待桌面端")>=0){k="waiting"}' +
    'else if(t.indexOf("任务列表")>=0||t.indexOf("工作区和任务")>=0){k="list"}' +
    'else if(t.indexOf("添加指令")>=0||t.indexOf("发送")>=0&&t.indexOf("上下文")>=0){k="session"}' +
    'if(k!==view.last){view.last=k;send("view",{kind:k})}}catch(e){}}';
  // 审批/提问卡探测（防抖去重）
  // 审批/提问是全局待处理状态，不冒充精确数量。只检测可见交互卡，向壳上报 0/1 指示。
  s += 'function att(){try{var keys=["需要你的确认","待你确认","待确认","等待你的确认","等待你确认","是否同意","需要你的批准","等待你的批准","权限请求","审批请求","需要你的输入"];var found=false;var els=document.querySelectorAll("div,section,article,[role=dialog],[role=alertdialog]");for(var i=0;i<els.length&&!found;i++){var el=els[i];var r=el.getBoundingClientRect();if(r.width<180||r.height<28||r.height>700){continue}var t=(el.innerText||el.textContent||"").replace(/\\s+/g," ").trim();if(t.length<8||t.length>900){continue}var semantic=false;for(var k=0;k<keys.length;k++){if(t.indexOf(keys[k])>=0){semantic=true;break}}if(semantic&&el.querySelector("button,[role=button]")){found=true}}var v=found?"1":"0";if(v!==att.last){att.last=v;send("attention",v)}}catch(e){}}';
  // 任务行级状态检测：实测新版 DOM 的任务行是 li[data-testid^=task-item-]，
  // 唯一键=data-task-item-key，标题=data-task-title-copy=original，运行标记=行内 animate-spin。
  // 运行状态连续两次扫描出现/消失才确认；离开列表重置基线，避免刷新/视图切换误报完成。
  s += 'function tasks(){try{var bt=document.body?(document.body.textContent||""):"";if(bt.indexOf("任务列表")<0&&bt.indexOf("工作区和任务")<0){if(tasks.lastPage){tasks.lastPage=false;tasks.last={};tasks.cand={};tasks.missing={};tasks.sig="";send("taskStats",{running:0,titles:[]})}return}var now=Date.now();if(tasks.scanAt&&now-tasks.scanAt<900){return}tasks.scanAt=now;var rows=document.querySelectorAll(\'li[data-testid^="task-item-"]\');var raw={};for(var i=0;i<rows.length;i++){var li=rows[i];var titleEl=li.querySelector(\'[data-task-title-copy="original"]\')||li.querySelector("[data-task-title-marquee-track]");var title=(titleEl?(titleEl.textContent||""):(li.textContent||"")).replace(/\\s+/g," ").trim();if(title.length<2){continue}if(title.length>60){title=title.substring(0,60)}var key=li.getAttribute("data-task-item-key")||li.getAttribute("data-testid")||title;if(li.querySelectorAll("[class]").length>0&&[...li.querySelectorAll("[class]")].some(function(e){return e.classList&&e.classList.contains("animate-spin")})){raw[key]=title}}var nc={};for(var k in raw){nc[k]=(tasks.cand&&tasks.cand[k]?tasks.cand[k]:0)+1}tasks.cand=nc;var stable={};for(var k2 in nc){if(nc[k2]>=2){stable[k2]=raw[k2]}}var titles=[];var ids=[];for(var k3 in stable){titles.push(stable[k3]);ids.push(k3)}var sig=ids.length+"|"+ids.join("\\u0001");if(sig!==tasks.sig){tasks.sig=sig;send("taskStats",{running:titles.length,titles:titles})}if(!tasks.lastPage){tasks.last=stable;tasks.missing={};tasks.lastPage=true;return}if(!tasks.last){tasks.last={};tasks.missing={}}for(var old in tasks.last){if(!stable[old]){tasks.missing[old]=(tasks.missing[old]||0)+1;if(tasks.missing[old]>=2){send("taskDone",{title:tasks.last[old],status:"已完成"});delete tasks.last[old];delete tasks.missing[old]}}else{delete tasks.missing[old]}}for(var active in stable){tasks.last[active]=stable[active];delete tasks.missing[active]}}catch(e){}}';
  // 配对失效卡探测（新版 SPA："手机连接已失效/校验失败"；兼容旧文案）
  s += 'function inv(){try{var v="0";var els=document.querySelectorAll("p,div,span");for(var i=0;i<els.length;i++){var t=els[i].textContent||"";if((t.indexOf("手机连接已失效")>=0||t.indexOf("二维码失效后需要回到桌面端重新连接")>=0||t.indexOf("校验失败")>=0)&&t.length<130){var r=els[i].getBoundingClientRect();if(r.height>0){v="1";break}}}if(v!==inv.last){inv.last=v;send("pairInvalid",v)}}catch(e){}}';
  // 调度：DOM 变化统一触发轻探测，属性变化触发主题
  s += 'function light(){rep();view();att();inv();tasks()}';
  s += 'function start(){light();setInterval(tasks,1200);setInterval(att,1500);' +
    'try{new MutationObserver(function(){light()}).observe(document.documentElement,{childList:true,subtree:true})}catch(e){}' +
    'try{new MutationObserver(function(){rep()}).observe(document.documentElement,{attributes:true,attributeFilter:["class","data-theme","style"]})}catch(e){}}';
  s += 'if(document.body){start()}else{document.addEventListener("DOMContentLoaded",start)}';
  s += '})();';
  return s;
}

/**
 * 兼容垫片（已停用，2026-11-11 真机实测）：
 * 合成占位 hash/t 能骗过客户端解析，但 /ws 中继会校验 HMAC 证明 → "校验失败/手机连接已失效"。
 * 手机端实际拿到的是【新版 V2 SPA】（含"选择其他设备"账号级设备选择器——本地 10-25 切片
 * 无此文案，PC 侧 CDN 取样为旧包造成了"SPA 未更新"的误判）。
 * 结论：sid-only 纯净 URL 直接交给新 SPA 处理；失效卡出现时走账号设备选择器。
 */
export function compatUrl(url: string): string {
  return url;
}

/** 桥对象：javaScriptProxy 注册物（方法名必须出现在 methodList） */
export class ShellBridge {
  onEvent: (tag: string, payload: string) => void = (_tag: string, _payload: string) => {};

  post(tag: string, payload: string): void {
    hilog.info(0x0000, TAG, '[bridge] %{public}s len=%{public}d', tag, payload.length);
    this.onEvent(tag, payload);
  }
}
