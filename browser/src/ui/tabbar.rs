// tabbar.rs — THANH TAB của Blackhole Browser (child webview trên cùng).
//
// Nâng cấp v2.0 so với v1.0:
//   * hiển thị trạng thái TURBO (badge đổi màu khi bật, F9)
//   * toast thông báo (zoom/turbo) — không alert() xấu xí
//   * nút zoom nhanh +/0/-
//   * Esc trong url bar = bỏ focus (thoát nhanh về trang)
//
// Giao tiếp: window.ipc.postMessage(JSON) — giao thức trong core/ipc.rs.
// Dùng .replace() thay format! — CSS/JS chứa dấu {} thoải mái.

pub fn tabbar_html() -> String {
    let tpl = r#"<!doctype html>
<html><head><meta charset="utf-8">
<style>@@THEME@@
body{height:100vh;display:flex;align-items:center;gap:6px;
  background:linear-gradient(180deg,#0b0d12,#11141c);
  padding:0 10px;border-bottom:1px solid #1f2430;overflow:hidden}
.brand{font-weight:800;letter-spacing:1px;font-size:14px;
  background:linear-gradient(90deg,var(--acc),var(--acc2));
  -webkit-background-clip:text;background-clip:text;color:transparent;
  margin-right:4px;white-space:nowrap}
button{background:var(--pill);border:1px solid var(--border);color:var(--txt);
  border-radius:6px;height:32px;min-width:32px;cursor:pointer;font-size:15px;line-height:1}
button:hover{border-color:var(--acc);color:#fff;background:#1d2330}
#tabs{display:flex;gap:4px;overflow-x:auto;max-width:42vw;scrollbar-width:none}
#tabs::-webkit-scrollbar{display:none}
.tab{display:flex;align-items:center;gap:8px;background:var(--pill);
  border:1px solid var(--border);border-radius:6px;padding:6px 10px;cursor:pointer;
  white-space:nowrap;max-width:210px;flex:none}
.tab.on{background:#1d2330;border-color:var(--acc);box-shadow:0 0 0 1px var(--acc) inset}
.tab .t{overflow:hidden;text-overflow:ellipsis;max-width:140px}
.tab .x{color:var(--dim)} .tab .x:hover{color:#f87171}
#url{flex:1;height:32px;background:#0f131b;border:1px solid var(--border);border-radius:8px;
  color:var(--txt);padding:0 12px;font:13px 'Segoe UI',system-ui,sans-serif;outline:none;user-select:text}
#url:focus{border-color:var(--acc2);box-shadow:0 0 8px rgba(34,211,238,.15)}
.badge{font-size:10px;font-weight:700;color:#22d3ee;border:1px solid #164e63;
  border-radius:999px;padding:3px 9px;white-space:nowrap;letter-spacing:.5px}
.badge.turbo{color:#f59e0b;border-color:#92400e;background:rgba(120,53,15,.15);
  animation:bhpulse 1.6s infinite}
@keyframes bhpulse{50%{opacity:.55}}
#toast{position:fixed;left:50%;bottom:6px;transform:translateX(-50%) translateY(30px);
  background:#1d2330;border:1px solid var(--acc);color:var(--txt);padding:6px 14px;
  border-radius:8px;font-size:12px;opacity:0;transition:all .25s;pointer-events:none;white-space:nowrap}
#toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
</style></head><body>
<span class="brand">&#9670; BLACKHOLE</span>
<button onclick="send({cmd:'back'})" title="Back">&#8592;</button>
<button onclick="send({cmd:'fwd'})" title="Forward">&#8594;</button>
<button onclick="send({cmd:'reload'})" title="Reload (Ctrl+R)">&#8635;</button>
<button onclick="send({cmd:'home'})" title="Speed Dial (Ctrl+H)">&#8962;</button>
<div id="tabs"></div>
<button onclick="send({cmd:'new'})" title="Tab mới (Ctrl+T)">+</button>
<input id="url" placeholder="Nhập link hoặc tìm Google… (Ctrl+L focus)">
<button class="badge" id="turbo" onclick="send({cmd:'turbo'})" title="TURBO: dọn cache, trả RAM về game (F9)">TURBO</button>
<button onclick="send({cmd:'zoom-out'})" title="Zoom out (Ctrl+-)">&minus;</button>
<button onclick="send({cmd:'zoom-reset'})" title="Zoom 100% (Ctrl+0)">&#37;</button>
<button onclick="send({cmd:'zoom-in'})" title="Zoom in (Ctrl+=)">+</button>
<div id="toast"></div>
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
  var tb=document.getElementById('turbo');
  tb.classList.toggle('turbo',!!d.turbo);
};
window.__bh_toast=function(msg){
  var t=document.getElementById('toast');
  t.textContent=msg;t.classList.add('show');
  clearTimeout(window.__bhT);window.__bhT=setTimeout(function(){t.classList.remove('show')},1800);
};
var urlEl=document.getElementById('url');
urlEl.addEventListener('keydown',function(e){
  if(e.key==='Enter'){
    var v=this.value.trim();
    if(v){send({cmd:'nav',url:v});this.blur()}
  } else if(e.key==='Escape'){this.blur()}
});
</script></body></html>"#;
    tpl.replace("@@THEME@", crate::ui::theme::CSS)
}

#[cfg(test)]
mod tests {
    #[test]
    fn tabbar_du_cac_phan_tu() {
        let html = super::tabbar_html();
        assert!(html.contains("id=\"url\""));
        assert!(html.contains("__bh_update"));
        assert!(html.contains("__bh_toast"));
        assert!(html.contains("cmd:'turbo'"));
        assert!(html.contains("cmd:'zoom-in'"));
        assert!(html.contains("ipc.postMessage"));
        assert!(html.contains("--acc:#7c3aed"), "thiếu theme nhúng");
        assert!(!html.contains("@@"), "còn placeholder chưa thay");
    }
}
