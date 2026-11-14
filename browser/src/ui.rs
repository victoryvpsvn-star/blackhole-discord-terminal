// ui.rs — toàn bộ UI HTML của BLACKHOLE Browser.
// Không bundle engine, không framework: HTML/CSS/JS thuần, render bằng
// webview hệ thống -> nhẹ nhất có thể, mượt nhờ GPU compositor của OS.

/// THANH TAB (child webview trên cùng, cao 52px).
/// Giao tiếp với Rust qua window.ipc.postMessage(JSON).
pub const TABBAR_HTML: &str = r#"<!doctype html>
<html><head><meta charset="utf-8">
<style>
:root{--bg:#0b0d12;--pill:#161a22;--acc:#7c3aed;--acc2:#22d3ee;--txt:#e5e7eb;--dim:#9ca3af}
*{box-sizing:border-box;user-select:none}
body{margin:0;height:100vh;display:flex;align-items:center;gap:6px;
  background:linear-gradient(180deg,#0b0d12,#11141c);color:var(--txt);
  font:13px 'Segoe UI',system-ui,sans-serif;padding:0 10px;
  border-bottom:1px solid #1f2430;overflow:hidden}
.brand{font-weight:800;letter-spacing:1px;font-size:14px;
  background:linear-gradient(90deg,var(--acc),var(--acc2));
  -webkit-background-clip:text;background-clip:text;color:transparent;
  margin-right:4px;white-space:nowrap}
button{background:var(--pill);border:1px solid #232936;color:var(--txt);
  border-radius:6px;height:32px;min-width:32px;cursor:pointer;font-size:15px;line-height:1}
button:hover{border-color:var(--acc);color:#fff;background:#1d2330}
#tabs{display:flex;gap:4px;overflow-x:auto;max-width:44vw;scrollbar-width:none}
#tabs::-webkit-scrollbar{display:none}
.tab{display:flex;align-items:center;gap:8px;background:var(--pill);
  border:1px solid #232936;border-radius:6px;padding:6px 10px;cursor:pointer;
  white-space:nowrap;max-width:210px}
.tab.on{background:#1d2330;border-color:var(--acc);box-shadow:0 0 0 1px var(--acc) inset}
.tab .t{overflow:hidden;text-overflow:ellipsis;max-width:140px}
.tab .x{color:var(--dim)} .tab .x:hover{color:#f87171}
#url{flex:1;height:32px;background:#0f131b;border:1px solid #232936;border-radius:8px;
  color:var(--txt);padding:0 12px;font:13px 'Segoe UI',system-ui,sans-serif;outline:none;user-select:text}
#url:focus{border-color:var(--acc2);box-shadow:0 0 8px rgba(34,211,238,.15)}
.badge{font-size:10px;font-weight:700;color:#22d3ee;border:1px solid #164e63;
  border-radius:999px;padding:3px 9px;white-space:nowrap;letter-spacing:.5px}
</style></head><body>
<span class="brand">&#9670; BLACKHOLE</span>
<button onclick="send({cmd:'back'})"  title="Back">&#8592;</button>
<button onclick="send({cmd:'fwd'})"  title="Forward">&#8594;</button>
<button onclick="send({cmd:'reload'})" title="Reload (Ctrl+R)">&#8635;</button>
<button onclick="send({cmd:'home'})" title="Speed Dial (Ctrl+H)">&#8962;</button>
<div id="tabs"></div>
<button onclick="send({cmd:'new'})" title="Tab moi (Ctrl+T)">+</button>
<input id="url" placeholder="Nhập link… Enter để đi (Ctrl+L focus)">
<span class="badge">TURBO &#183; ZERO-BLOAT</span>
<script>
function send(o){window.ipc.postMessage(JSON.stringify(o))}
function esc(s){return (s||'').replace(/[&<>"]/g,function(c){
  return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
window.__bh_update=function(d){
  var h='';
  d.tabs.forEach(function(t,i){
    var u=t.url||'';
    var label=t.title;
    if(!label||label==='about:blank'){label=u.replace(/^https?:\/\//,'').split('/')[0]||'Speed Dial'}
    h+='<div class="tab'+(i===d.active?' on':'')+'" onclick="send({cmd:\'switch\',i:'+i+'})">'
      +'<span class="t">'+esc(label)+'</span>'
      +'<span class="x" onclick="event.stopPropagation();send({cmd:\'close\',i:'+i+'})"> &times;</span></div>';
  });
  document.getElementById('tabs').innerHTML=h;
  var u=document.getElementById('url');
  if(document.activeElement!==u){u.value=d.url||''}
};
var urlEl=document.getElementById('url');
urlEl.addEventListener('keydown',function(e){
  if(e.key==='Enter'){
    var v=this.value.trim();
    if(v){
      if(!/^https?:\/\//i.test(v) && v.indexOf('.')>0 && v.indexOf(' ')<0){v='https://'+v}
      send({cmd:'nav',url:v}); this.blur();
    }
  }
});
</script></body></html>"#;

/// TRANG SPEED DIAL — mở trong webview nội dung (tab mới / nút home).
pub const DIAL_HTML: &str = r#"<!doctype html>
<html><head><meta charset="utf-8"><title>Speed Dial — BLACKHOLE</title>
<style>
:root{--acc:#7c3aed;--acc2:#22d3ee}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;background:#0b0d12;color:#e5e7eb;
  font:15px 'Segoe UI',system-ui,sans-serif;display:flex;flex-direction:column;
  align-items:center;justify-content:center;padding:40px 20px;
  background-image:radial-gradient(600px 300px at 50% 0%,rgba(124,58,237,.25),transparent),
                   radial-gradient(500px 260px at 80% 100%,rgba(34,211,238,.12),transparent)}
h1{font-size:44px;margin:0 0 6px;letter-spacing:-1px;
  background:linear-gradient(90deg,var(--acc),var(--acc2));
  -webkit-background-clip:text;background-clip:text;color:transparent}
p.sub{color:#9ca3af;margin:0 0 28px;font-size:14px}
.search{width:min(640px,92vw);display:flex;margin-bottom:34px}
.search input{flex:1;height:46px;background:#12151d;border:1px solid #232936;
  border-radius:10px 0 0 10px;color:#e5e7eb;padding:0 16px;font-size:15px;outline:none}
.search input:focus{border-color:var(--acc2)}
.search button{height:46px;padding:0 22px;border:0;border-radius:0 10px 10px 0;
  background:linear-gradient(90deg,var(--acc),var(--acc2));color:#fff;font-weight:700;cursor:pointer}
.grid{display:grid;grid-template-columns:repeat(auto-fit,120px,1fr);gap:16px;width:min(760px,94vw)}
.tile{display:flex;flex-direction:column;align-items:center;gap:10px;
  background:#12151d;border:1px solid #232936;border-radius:12px;padding:18px 8px;
  cursor:pointer;text-decoration:none;color:#e5e7eb;font-size:13px;text-align:center;
  transition:transform .12s,border-color .12s}
.tile:hover{transform:translateY(-3px);border-color:var(--acc)}
.tile .ic{font-size:26px}
.hint{margin-top:34px;color:#6b7280;font-size:12px;line-height:1.8;text-align:center}
.hint b{color:#9ca3af}
</style></head><body>
<h1>&#9670; BLACKHOLE</h1>
<p class="sub">gaming browser &#183; webview hệ thống &#183; không bloat</p>
<div class="search">
  <input id="q" placeholder="Tìm gì đó… (Enter = tìm bằng DuckDuckGo)">
  <button onclick="go()">ĐI</button>
</div>
<div class="grid">
  <a class="tile" href="https://www.google.com"><span class="ic">&#127760;</span>Google</a>
  <a class="tile" href="https://www.youtube.com"><span class="ic">&#9654;&#65039;</span>YouTube</a>
  <a class="tile" href="https://github.com"><span class="ic">&#128038;</span>GitHub</a>
  <a class="tile" href="https://store.steampowered.com"><span class="ic">&#127918;</span>Steam</a>
  <a class="tile" href="https://discord.com"><span class="ic">&#127918;</span>Discord</a>
  <a class="tile" href="https://www.twitch.tv"><span class="ic">&#127916;</span>Twitch</a>
  <a class="tile" href="https://www.reddit.com"><span class="ic">&#128493;</span>Reddit</a>
  <a class="tile" href="https://vi.wikipedia.org"><span class="ic">&#128218;</span>Wikipedia</a>
</div>
<div class="hint">
  <b>Ctrl+T</b> tab mới &#183; <b>Ctrl+W</b> đóng tab &#183; <b>Ctrl+Tab</b> tab kế &#183;
  <b>Ctrl+1..8</b> nhảy tab &#183; <b>Ctrl+L</b> focus thanh địa chỉ &#183; <b>Ctrl+R/F5</b> reload &#183; <b>F11</b> fullscreen
</div>
<script>
function go(){var v=document.getElementById('q').value.trim();
  if(v){window.ipc.postMessage(JSON.stringify({cmd:'nav',url:'https://duckduckgo.com/?q='+encodeURIComponent(v)}))}}
document.getElementById('q').addEventListener('keydown',function(e){if(e.key==='Enter')go()});
</script></body></html>"#;

/// Init script bắn vào MỌI trang trong webview nội dung — tự báo cáo
/// title + url về Rust qua IPC (rất nhẹ: interval 400ms, 1 compare string).
pub const PAGE_HOOK_JS: &str = r#"
var __bhT=null,__bhU=null;
setInterval(function(){
  try{
    var t=document.title||'';
    if(t&&t!==__bhT){__bhT=t;window.ipc.postMessage(JSON.stringify({cmd:'title',v:t}))}
    var u=location.href||'';
    if(u&&u!==__bhU){__bhU=u;window.ipc.postMessage(JSON.stringify({cmd:'url',v:u}))}
  }catch(e){}
},400);
"#;
