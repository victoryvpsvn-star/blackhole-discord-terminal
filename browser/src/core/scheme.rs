// scheme.rs — tầng SCHEME của BlackholeCore: trang nội bộ blackhole://
//
// Giống chrome:// của Chrome hay opera:// của Opera — BLACKHOLE có
// scheme RIÊNG của mình: blackhole://start, blackhole://about,
// blackhole://version...
//
// Mapping URL theo nền tảng (wry):
//   * Windows/WebView2: custom protocol chạy dạng https://{name}.{host}
//     (giới hạn của WebView2 — xem WebView2Feedback#73) -> https://blackhole.localhost/start
//   * Linux/WebKitGTK: scheme thật -> blackhole://localhost/start
//
// Handler nhận Request<Vec<u8>> (http crate) và trả Response html.

use wry::http::{Request, Response};

/// Scheme nội bộ của Blackhole.
pub const SCHEME: &str = "blackhole";

/// Dựng URL nội bộ theo nền tảng hiện tại.
pub fn internal_url(path: &str) -> String {
    #[cfg(target_os = "windows")]
    {
        format!("https://{}.localhost/{}", SCHEME, path)
    }
    #[cfg(not(target_os = "windows"))]
    {
        format!("{}://localhost/{}", SCHEME, path)
    }
}

/// Trích path từ URI custom protocol (cả 2 dạng Windows/Linux).
/// "https://blackhole.localhost/start" -> "start"
/// "blackhole://localhost/start"       -> "start"
pub fn parse_path(uri: &str) -> String {
    let after_scheme = match uri.find("://") {
        Some(p) => &uri[p + 3..],
        None => return String::new(),
    };
    // bỏ host (đến '/' đầu tiên)
    let path = match after_scheme.find('/') {
        Some(p) => &after_scheme[p + 1..],
        None => "",
    };
    // bỏ query/fragment
    let path = path.split(['?', '#']).next().unwrap_or(path);
    path.to_string()
}

/// Router trang nội bộ: path -> (html, status).
/// Route: start | newtab (cùng trang speed dial), about, version, blank.
pub fn route(path: &str) -> (u16, &'static str, String) {
    let (status, ctype, body) = match path {
        "" | "start" | "newtab" => (200u16, "text/html; charset=utf-8", crate::ui::dial::dial_html()),
        "about" | "version" => (200, "text/html; charset=utf-8", about_html()),
        "bench" => (200, "text/html; charset=utf-8", crate::ui::bench::bench_html()),
        "blank" => (200, "text/html; charset=utf-8", "<!doctype html><html><body></body></html>".into()),
        _ => (404, "text/plain; charset=utf-8", format!("blackhole://{} không tồn tại", path)),
    };
    (status, ctype, body)
}

/// Handler gắn vào builder — đúng chữ ký wry 0.46:
/// Fn(WebViewId, Request<Vec<u8>>) -> Response<Cow<'static,[u8]>>
pub fn handler(
    _id: &str,
    req: Request<Vec<u8>>,
) -> Response<std::borrow::Cow<'static, [u8]>> {
    let uri = req.uri().to_string();
    let path = parse_path(&uri);
    let (status, ctype, body) = route(&path);
    Response::builder()
        .status(status)
        .header("Content-Type", ctype)
        .header("Cache-Control", "no-store")
        .body(std::borrow::Cow::Owned(body.into_bytes()))
        .unwrap_or_else(|_| Response::new(std::borrow::Cow::Borrowed(b"error" as &[u8])))
}

/// Trang about — nhận diện core riêng của Blackhole.
pub fn about_html() -> String {
    let engine = crate::core::engine::engine_label();
    format!(
        r#"<!doctype html><html><head><meta charset="utf-8"><title>About — BLACKHOLE</title>
<style>
body{{margin:0;min-height:100vh;background:#0b0d12;color:#e5e7eb;font:15px 'Segoe UI',system-ui,sans-serif;
display:flex;align-items:center;justify-content:center}}
.card{{width:min(560px,92vw);background:#12151d;border:1px solid #232936;border-radius:14px;padding:34px 40px}}
h1{{font-size:30px;margin:0 0 4px;background:linear-gradient(90deg,#7c3aed,#22d3ee);
-webkit-background-clip:text;background-clip:text;color:transparent}}
p{{color:#9ca3af;line-height:1.7;margin:8px 0}}
b{{color:#e5e7eb}}
.kv{{display:grid;grid-template-columns:150px 1fr;gap:6px;margin-top:18px}}
.kv span{{color:#9ca3af}} .kv b{{color:#22d3ee}}
</style></head><body><div class="card">
<h1>&#9670; BLACKHOLE Browser</h1>
<p>gaming browser siêu nhẹ — <b>BlackholeCore</b> {v}</p>
<div class="kv">
<span>Nhân render/JS</span><b>{engine}</b>
<span>Core vận hành</span><b>BlackholeCore {v} (Rust)</b>
<span>Tabs</span><b>keep-alive đa webview, LRU memory saver, tối đa 24 tab</b>
<span>Profile</span><b>~/.blackhole-browser (riêng biệt — không đụng Edge/Chrome/Opera)</b>
<span>Search</span><b>Google (mặc định)</b>
<span>Telemetry</span><b>KHÔNG có. Service nền: KHÔNG có.</b>
</div>
<p style="margin-top:20px">Blackhole dùng nhân webview có sẵn trong máy và tự vận hành nó bằng
core riêng: UA riêng, flags riêng (không throttle tab nền), scheme riêng, tabs riêng.
Giống mô hình Edge/Brave/Opera đều đi trên nhân Chromium và khác nhau ở tầng core.</p>
</div></body></html>"#,
        v = crate::core::CORE_VERSION,
        engine = engine,
    )
}

// ================= TEST =================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_path_2_dang_uri() {
        assert_eq!(parse_path("https://blackhole.localhost/start"), "start");
        assert_eq!(parse_path("blackhole://localhost/start"), "start");
        assert_eq!(parse_path("https://blackhole.localhost/"), "");
        assert_eq!(parse_path("blackhole://localhost/about?x=1"), "about");
        assert_eq!(parse_path("https://blackhole.localhost/version#top"), "version");
    }

    #[test]
    fn internal_url_theo_nen_tang() {
        let u = internal_url("start");
        assert!(u.contains("blackhole"), "URL phải mang scheme blackhole: {}", u);
        assert!(u.ends_with("/start"));
    }

    #[test]
    fn router_cac_trang() {
        let (s1, ct1, b1) = route("start");
        assert_eq!(s1, 200);
        assert!(ct1.contains("text/html"));
        assert!(b1.contains("BLACKHOLE"));

        let (s2, _, b2) = route("about");
        assert_eq!(s2, 200);
        assert!(b2.contains("BlackholeCore"));

        let (s3, _, b3) = route("khong-ton-tai");
        assert_eq!(s3, 404);
        assert!(!b3.is_empty());
    }

    #[test]
    fn handler_tra_response_dung() {
        let req = Request::builder().uri("https://blackhole.localhost/start").body(Vec::new()).unwrap();
        let resp = handler("t0", req);
        assert_eq!(resp.status(), 200);
        let req404 = Request::builder().uri("https://blackhole.localhost/xyz").body(Vec::new()).unwrap();
        let resp404 = handler("t0", req404);
        assert_eq!(resp404.status(), 404);
    }
}
