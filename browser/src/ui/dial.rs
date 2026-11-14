// dial.rs — SPEED DIAL của Blackhole Browser.
//
// v2.0: TÌM KIẾM BẰNG GOOGLE (yêu cầu chủ dự án: "dùng google.com đừng
// duckduckgo"). Query đưa thẳng google.com/search?q= — nơi nhận là
// Command::Nav (từ IPC của chính trang này).
// Dùng .replace() thay format! — CSS/JS chứa dấu {} thoải mái.

pub fn dial_html() -> String {
    let tpl = r#"<!doctype html>
<html><head><meta charset="utf-8"><title>Speed Dial — BLACKHOLE</title>
<style>@@THEME@@
body{min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;
  padding:40px 20px;background-image:radial-gradient(600px 300px at 50% 0%,rgba(124,58,237,.25),transparent),
  radial-gradient(500px 260px at 80% 100%,rgba(34,211,238,.12),transparent)}
h1{font-size:44px;margin:0 0 6px;letter-spacing:-1px;
  background:linear-gradient(90deg,var(--acc),var(--acc2));
  -webkit-background-clip:text;background-clip:text;color:transparent}
p.sub{color:var(--dim);margin:0 0 28px;font-size:14px}
.search{width:min(640px,92vw);display:flex;margin-bottom:34px}
.search input{flex:1;height:46px;background:var(--bg2);border:1px solid var(--border);
  border-radius:10px 0 0 10px;color:var(--txt);padding:0 16px;font-size:15px;outline:none;user-select:text}
.search input:focus{border-color:var(--acc2)}
.search button{height:46px;padding:0 26px;border:0;border-radius:0 10px 10px 0;
  background:linear-gradient(90deg,var(--acc),var(--acc2));color:#fff;font-weight:700;cursor:pointer}
.grid{display:grid;grid-template-columns:repeat(auto-fit,120px,1fr);gap:16px;width:min(760px,94vw)}
.tile{display:flex;flex-direction:column;align-items:center;gap:10px;
  background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:18px 8px;
  cursor:pointer;text-decoration:none;color:var(--txt);font-size:13px;text-align:center;
  transition:transform .12s,border-color .12s}
.tile:hover{transform:translateY(-3px);border-color:var(--acc)}
.tile .ic{font-size:26px}
.hint{margin-top:34px;color:#6b7280;font-size:12px;line-height:1.8;text-align:center}
.hint b{color:var(--dim)}
.foot{position:fixed;bottom:10px;right:14px;color:#4b5563;font-size:11px}
</style></head><body>
<h1>&#9670; BLACKHOLE</h1>
<p class="sub">gaming browser &#183; BlackholeCore &#183; webview hệ thống &#183; zero bloat</p>
<div class="search">
  <input id="q" placeholder="Tìm Google hoặc nhập link… (Enter)">
  <button onclick="go()">ĐI</button>
</div>
<div class="grid">
  <a class="tile" href="https://www.google.com"><span class="ic">&#128269;</span>Google</a>
  <a class="tile" href="https://www.youtube.com"><span class="ic">&#9654;&#65039;</span>YouTube</a>
  <a class="tile" href="https://github.com"><span class="ic">&#128038;</span>GitHub</a>
  <a class="tile" href="https://store.steampowered.com"><span class="ic">&#127918;</span>Steam</a>
  <a class="tile" href="https://discord.com"><span class="ic">&#127918;</span>Discord</a>
  <a class="tile" href="https://www.twitch.tv"><span class="ic">&#127916;</span>Twitch</a>
  <a class="tile" href="https://www.reddit.com"><span class="ic">&#128493;</span>Reddit</a>
  <a class="tile" href="@@ABOUT@@"><span class="ic">&#8506;&#65039;</span>About</a>
</div>
<div class="hint">
  <b>Ctrl+T</b> tab mới &#183; <b>Ctrl+W</b> đóng tab &#183; <b>Ctrl+Tab</b> chuyển tab &#183;
  <b>Ctrl+1..8</b> nhảy tab &#183; <b>Ctrl+L</b> địa chỉ &#183; <b>F9</b> TURBO &#183; <b>F11</b> fullscreen
</div>
<div class="foot">Search: Google &#183; BlackholeCore @@V@@</div>
<script>
function go(){
  var v=document.getElementById('q').value.trim();
  if(v){window.ipc.postMessage(JSON.stringify({cmd:'nav',url:v}))}
}
document.getElementById('q').addEventListener('keydown',function(e){
  if(e.key==='Enter')go()
});
</script></body></html>"#;
    tpl.replace("@@THEME@", crate::ui::theme::CSS)
        .replace("@@ABOUT@", &crate::core::scheme::internal_url("about"))
        .replace("@@V@", crate::core::CORE_VERSION)
}

#[cfg(test)]
mod tests {
    #[test]
    fn dial_co_google_va_het_placeholder() {
        let html = super::dial_html();
        assert!(html.contains("BLACKHOLE"));
        assert!(html.contains("Tìm Google"), "phải nói rõ Google");
        assert!(html.contains("cmd:'nav'"));
        assert!(html.contains("--acc2:#22d3ee"), "thiếu theme nhúng");
        assert!(!html.contains("@@"), "còn placeholder chưa thay");
    }
}
