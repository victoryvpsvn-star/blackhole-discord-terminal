// ============================================================
//  bridge.rs — "TRÌNH DUYỆT ẨN" (hidden browser bridge) v2.1
//
//  Ý tưởng chủ dự án: terminal cần 1 "browser riêng siêu nhẹ dành
//  cho Discord". Nhúng hẳn web engine (WebView2/WebKitGTK) sẽ đội
//  binary lên 100–400MB — chết mục tiêu NHẸ. Giải pháp giữ nguyên
//  tinh thần mà KHÔNG thêm 1 KB deps nào:
//
//   1. Terminal TỰ SINH trang xác minh mang giao diện Discord
//      (dark + blurple — NGỤY TRANG Discord) chứa widget hCaptcha
//      với sitekey THẬT Discord API trả về (+ rqdata nếu có).
//   2. Tự mở trang đó bằng trình duyệt có sẵn của máy
//      (xdg-open / start / open) — trình duyệt là render engine,
//      terminal là điều phối: "browser ẩn" đúng nghĩa.
//   3. Người dùng TỰ BẤM captcha (terminal không tự giải — đúng luật).
//   4. JS trong trang tự POST kết quả về local server 127.0.0.1
//      (std::net::TcpListener — 0 deps) → terminal TỰ BẮT token,
//      KHÔNG cần dán tay như v2.0.
//   5. Trang có mục dự phòng: nếu hCaptcha từ chối sitekey trên
//      domain localhost (sitekey khóa theo domain) thì hướng dẫn
//      cách chắc chắn (discord.com/login + F12 lấy token) → dán
//      vào trang → kết quả vẫn tự chảy về terminal.
//
//  Bảo mật (M4 duyệt): server chỉ nghe 127.0.0.1, sống tối đa 6
//  phút, đóng ngay khi nhận kết quả. Request cap 64KB, body cap
//  32KB. Không log, không ghi token ra đĩa.
// ============================================================

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant};

/// Sống tối đa 6 phút — đủ giải captcha, không treo máy yếu
pub const WAIT_SECS: u64 = 360;

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// Trang xác minh phong cách Discord (ngụy trang). Dùng .replace()
/// thay format! để khỏi phải escape dấu {} trong CSS/JS.
pub fn captcha_page(sitekey: &str, rqdata: &str, service: &str) -> String {
    let rq_attr = if rqdata.is_empty() {
        String::new()
    } else {
        format!(" data-rqdata=\"{}\"", html_escape(rqdata))
    };
    PAGE_TPL
        .replace("@@SK@@", &html_escape(sitekey))
        .replace("@@RQ@@", &rq_attr)
        .replace("@@SVC@@", &html_escape(service))
}

/// Trang xanh báo "xong việc" sau khi đã gửi kết quả về terminal
fn done_page() -> &'static str {
    r#"<!doctype html><html lang="vi"><head><meta charset="utf-8"><title>Discord — Xác minh xong</title>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#1e1f22;font-family:'Segoe UI',Roboto,Helvetica,Arial,sans-serif}.card{background:#313338;padding:36px 44px;border-radius:8px;text-align:center;color:#23a55a;font-size:18px;font-weight:700}p{color:#b5bac1;font-size:13px;font-weight:400;margin-top:10px;line-height:1.5}</style>
</head><body><div class="card">&#10004; Đã xác minh xong!<p>Quay lại terminal BLACKHOLE — đăng nhập đang tự chạy tiếp.<br>Cửa sổ này có thể đóng lại.</p></div></body></html>"#
}

const PAGE_TPL: &str = r#"<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Discord</title>
<style>
:root{--bg:#1e1f22;--card:#313338;--blurple:#5865f2;--text:#dbdee1;--dim:#b5bac1;--ok:#23a55a}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:var(--bg);color:var(--text);font-family:'gg sans','Segoe UI',Roboto,Helvetica,Arial,sans-serif}
.card{background:var(--card);width:min(480px,94vw);border-radius:8px;padding:32px;box-shadow:0 8px 24px rgba(0,0,0,.45);text-align:center}
.logo{color:#fff;font-weight:800;font-size:24px;letter-spacing:-.5px}
h1{font-size:20px;color:#f2f3f5;margin:16px 0 6px}
p{font-size:13px;color:var(--dim);margin:0 0 18px;line-height:1.5}
.wbox{display:inline-block;background:#f2f3f5;border-radius:4px;padding:10px 14px}
.btn{display:none;margin-top:16px;background:var(--blurple);color:#fff;border:0;border-radius:4px;padding:11px 16px;font-size:14px;font-weight:600;width:100%;cursor:pointer}
.btn.show{display:block}
.ok{display:none;color:var(--ok);font-weight:700;font-size:16px;margin-top:14px}
textarea{width:100%;margin-top:12px;background:#1e1f22;color:var(--text);border:1px solid #4e5058;border-radius:4px;padding:8px;font-size:12px;resize:vertical}
details{margin-top:16px;text-align:left;font-size:12px;color:var(--dim)}
details summary{cursor:pointer;color:#949ba4}
details li{margin:6px 0;line-height:1.5}
code{background:#1e1f22;border-radius:3px;padding:2px 4px;font-size:11px;word-break:break-all;color:#949ba4}
small{color:#949ba4;display:block;margin-top:14px;font-size:11px;line-height:1.5}
</style>
</head>
<body>
<div class="card">
<div class="logo">Discord</div>
<h1>Xác minh bảo mật</h1>
<p>Oh, có vẻ chúng ta cần kiểm tra xem bạn có phải người thật không.<br>Bấm vào ô bên dưới — kết quả sẽ <b>tự gửi về terminal BLACKHOLE</b>.</p>
<div class="wbox"><div class="h-captcha" data-sitekey="@@SK@@"@@RQ@@ data-callback="onPass" data-theme="dark"></div></div>
<button class="btn" id="btn1" onclick="fnSend1()">Gửi kết quả thủ công</button>
<div class="ok" id="ok">&#10004; Đã xác minh xong — quay lại terminal, mọi thứ tự chạy tiếp</div>
<textarea id="tok" rows="3" placeholder="kết quả xác minh sẽ hiện ở đây"></textarea>
<details>
<summary>Captcha báo lỗi hoặc không hiện ô bấm? — cách chắc chắn 100%</summary>
<ol>
<li>Mở <b>discord.com/login</b> trong trình duyệt, đăng nhập bằng chính tài khoản này (giải captcha ngay trong đó).</li>
<li>Vào được Discord → nhấn <b>F12</b> → tab <b>Console</b>, dán lệnh:<br>
<code>webpackChunkdiscord_app.push([[Math.random()],{},e=&gt;{m=[];for(const c in e.c)m.push(e.c[c])},m]) &amp;&amp; m.find(x=&gt;x.exports?.default?.getToken!==void 0).exports.default.getToken()</code></li>
<li>Copy chuỗi token → dán vào ô dưới → nhấn <b>Gửi</b>. Terminal sẽ nhận được ngay.</li>
</ol>
<textarea id="manual" rows="3" placeholder="dán hCaptcha token hoặc Discord token vào đây"></textarea>
<button class="btn show" id="btn2" onclick="fnSend2()">Gửi</button>
</details>
<small>Cửa sổ này do terminal BLACKHOLE tạo cục bộ (127.0.0.1, dịch vụ @@SVC@@) chỉ để bạn bấm captcha — không gửi dữ liệu đi đâu khác, không lưu gì lên mạng.</small>
</div>
<script src="https://js.hcaptcha.com/1/api.js" async defer></script>
<script>
function onPass(t){show(t);fetch('/done',{method:'POST',body:t}).then(hide).catch(btn1)}
function show(t){var a=document.getElementById('ok');a.style.display='block';document.getElementById('tok').value=t}
function hide(){document.getElementById('btn1').classList.remove('show')}
function btn1(){document.getElementById('btn1').classList.add('show')}
function fnSend1(){var t=document.getElementById('tok').value.trim();if(t){fetch('/done',{method:'POST',body:t}).then(hide).catch(function(){})}}
function fnSend2(){var t=document.getElementById('manual').value.trim();if(t){fetch('/done',{method:'POST',body:t}).then(function(){show(t)}).catch(function(){})}}
</script>
</body>
</html>"#;

/// Bật trình duyệt ẩn: bind local server → sinh trang → mở browser →
/// chờ trang /done POST kết quả về. Trả về chuỗi kết quả (hCaptcha
/// token HOẶC Discord token dán tay ở trang dự phòng).
pub fn captcha_bridge(sitekey: &str, rqdata: &str, service: &str) -> Result<String, String> {
    let listener = TcpListener::bind("127.0.0.1:0")
        .map_err(|e| format!("không mở được server cục bộ 127.0.0.1: {}", e))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("đọc port cục bộ lỗi: {}", e))?
        .port();
    let html = captcha_page(sitekey, rqdata, service);
    let url = format!("http://127.0.0.1:{}", port);
    println!("\x1b[1;36m║  ▶ TRÌNH DUYỆT ẨN đã bật — đang mở: \x1b[4m{}\x1b[0m", url);
    match crate::img::open_system(&url) {
        Ok(()) => println!("║  (trình duyệt đã mở — không thấy cửa sổ thì copy link trên dán vào)"),
        Err(e) => println!("║  ! Không tự mở được trình duyệt ({}) — copy link trên dán vào trình duyệt", e),
    }
    println!("║  Huỷ: Ctrl+C • tự huỷ sau {} phút nếu không bấm gì", WAIT_SECS / 60);
    let tok = accept_until_token(&listener, &html, Duration::from_secs(WAIT_SECS))?;
    println!("║  ✓ Terminal đã TỰ BẮT kết quả xác minh — không cần dán tay!");
    println!("\x1b[1;33m╚═════════════════════════════════════════════════════════════════╝\x1b[0m");
    Ok(tok)
}

/// Vòng accept cho tới khi nhận token (hoặc hết giờ). Không chặn
/// vô hạn: nonblocking + sleep 120ms, đúng tiết kiệm CPU máy yếu.
fn accept_until_token(listener: &TcpListener, html: &str, wait: Duration) -> Result<String, String> {
    listener
        .set_nonblocking(true)
        .map_err(|e| format!("đặt nonblocking lỗi: {}", e))?;
    let deadline = Instant::now() + wait;
    loop {
        if Instant::now() >= deadline {
            return Err("hết thời gian chờ xác minh (6 phút)".into());
        }
        match listener.accept() {
            Ok((stream, _)) => {
                if let Some(tok) = handle_conn(stream, html) {
                    return Ok(tok);
                }
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(120));
            }
            Err(e) => return Err(format!("lỗi server cục bộ: {}", e)),
        }
    }
}

/// Xử lý 1 kết nối HTTP thô. Trả Some(kết quả) khi trang /done POST về.
fn handle_conn(mut stream: TcpStream, html: &str) -> Option<String> {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));

    // ---- đọc tới khi đủ header ----
    let mut buf: Vec<u8> = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        match stream.read(&mut chunk) {
            Ok(0) => return None,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if let Some(p) = find_head_end(&buf) {
                    break p;
                }
                if buf.len() > 65536 {
                    return None; // request quá to — bỏ cho an toàn
                }
            }
            Err(_) => return None,
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let first = head.lines().next().unwrap_or("");
    let mut it = first.split_whitespace();
    let method = it.next().unwrap_or("");
    let path = it.next().unwrap_or("");

    // ---- POST thì đọc nốt body (cap 32KB — token hCaptcha chỉ vài KB) ----
    let mut body = String::new();
    if method == "POST" {
        let clen = head
            .to_ascii_lowercase()
            .lines()
            .filter_map(|l| {
                l.strip_prefix("content-length:")
                    .and_then(|v| v.trim().parse::<usize>().ok())
            })
            .next()
            .unwrap_or(0)
            .min(32768);
        let mut body_bytes: Vec<u8> = buf[head_end + 4..].to_vec();
        while body_bytes.len() < clen {
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    body_bytes.extend_from_slice(&chunk[..n]);
                    if body_bytes.len() > 32768 {
                        return None;
                    }
                }
                Err(_) => break,
            }
        }
        body_bytes.truncate(clen);
        body = String::from_utf8_lossy(&body_bytes).trim().to_string();
    }

    // ---- phân tuyến đường ----
    match (method, path) {
        ("GET", p) if p == "/" || p.starts_with("/?") => {
            respond(&mut stream, "200 OK", "text/html; charset=utf-8", html);
            None
        }
        ("GET", p) if p == "/favicon.ico" || p.starts_with("/favicon") => {
            let _ = stream.write_all(b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n");
            None
        }
        ("POST", "/done") => {
            if body.is_empty() {
                respond(&mut stream, "400 Bad Request", "text/plain; charset=utf-8", "thiếu kết quả");
                None // tiếp tục chờ lần POST đúng sau
            } else {
                respond(&mut stream, "200 OK", "text/html; charset=utf-8", done_page());
                Some(body)
            }
        }
        _ => {
            respond(&mut stream, "404 Not Found", "text/plain; charset=utf-8", "404");
            None
        }
    }
}

/// Tìm vị trí "\r\n\r\n" kết thúc header HTTP
fn find_head_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

/// Ghi 1 HTTP response gọn nhẹ rồi đóng (Connection: close)
fn respond(stream: &mut TcpStream, status: &str, ctype: &str, body: &str) {
    let head = format!(
        "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        status,
        ctype,
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body.as_bytes());
    let _ = stream.flush();
}

// ================= TEST (cargo test) =================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trang_chua_sitekey_va_hcaptcha() {
        let html = captcha_page("SITE-KEY-XYZ", "", "hcaptcha");
        assert!(html.contains("data-sitekey=\"SITE-KEY-XYZ\""), "thiếu sitekey");
        assert!(html.contains("js.hcaptcha.com/1/api.js"), "thiếu script hCaptcha");
        assert!(html.contains("data-callback=\"onPass\""), "thiếu callback");
        assert!(html.contains("fetch('/done'"), "thiếu POST /done về terminal");
        assert!(html.contains("127.0.0.1"), "thiếu ghi chú local");
        assert!(!html.contains("@@"), "còn placeholder chưa thay");
    }

    #[test]
    fn trang_nho_rqdata_va_escape_an_toan() {
        let html = captcha_page("k&<>\"'", "rq/dữ liệu\"", "hcaptcha");
        assert!(html.contains("data-rqdata=\"rq/dữ liệu&quot;\""), "rqdata chưa escape");
        assert!(html.contains("data-sitekey=\"k&amp;&lt;&gt;&quot;&#39;\""), "sitekey chưa escape");
    }

    #[test]
    fn html_escape_dung() {
        assert_eq!(html_escape("a&b<c>d\"e'f"), "a&amp;b&lt;c&gt;d&quot;e&#39;f");
        assert_eq!(html_escape("bình thường"), "bình thường");
    }

    /// END-TO-END: trang POST /done → terminal tự bắt đúng token
    #[test]
    fn bridge_bat_token_post_done() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let html = captcha_page("test-key", "", "hcaptcha");

        // giả lập JS trong trang: POST /done với body là token (14 byte)
        let t = std::thread::spawn(move || {
            let mut c = TcpStream::connect(addr).unwrap();
            c.write_all(
                b"POST /done HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 14\r\nConnection: close\r\n\r\nP1_abCd1234_x9",
            )
            .unwrap();
        });

        let tok = accept_until_token(&listener, &html, Duration::from_secs(10))
            .expect("không bắt được token");
        assert_eq!(tok, "P1_abCd1234_x9");
        t.join().unwrap();
    }

    /// GET / phải trả trang HTML đầy đủ (status 200 + sitekey)
    #[test]
    fn get_len_trang_xac_minh() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let html = captcha_page("KEY-GET-TEST", "", "hcaptcha");

        let t = std::thread::spawn(move || {
            let mut c = TcpStream::connect(addr).unwrap();
            c.write_all(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
                .unwrap();
            let mut s = String::new();
            let _ = c.read_to_string(&mut s);
            s
        });

        // vòng accept: GET / trả html → None → chờ tiếp tới hết giờ thì Err.
        // PHẢI accept TRƯỚC rồi mới join — ngược lại là deadlock.
        let r = accept_until_token(&listener, &html, Duration::from_secs(3));
        assert!(r.is_err(), "GET / không nên trả token");

        let resp = t.join().unwrap();
        assert!(resp.starts_with("HTTP/1.1 200 OK"), "thiếu 200");
        assert!(resp.contains("KEY-GET-TEST"), "trang không chứa sitekey");
        assert!(resp.contains("<!doctype html>"), "thiếu html");
    }

    /// Request rác (favicon) phải trả 204 và KHÔNG làm vòng lặp chết
    #[test]
    fn favicon_tra_204_khong_chet() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let html = captcha_page("k", "", "hcaptcha");
        let t = std::thread::spawn(move || {
            let mut c = TcpStream::connect(addr).unwrap();
            c.write_all(b"GET /favicon.ico HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                .unwrap();
            let mut s = String::new();
            let _ = c.read_to_string(&mut s);
            s
        });
        // PHẢI accept TRƯỚC rồi mới join — ngược lại là deadlock
        let served = accept_until_token(&listener, &html, Duration::from_secs(3));
        assert!(served.is_err(), "favicon không nên trả token");
        let resp = t.join().unwrap();
        assert!(resp.starts_with("HTTP/1.1 204"), "favicon phải 204");
    }
}
