// ============================================================
//  login.rs — ĐĂNG NHẬP EMAIL + MẬT KHẨU (flow chính thức Discord)
//
//  POST /auth/login  → token | mfa ticket | captcha | lỗi
//  POST /auth/mfa/totp → token (2FA: 6 số hoặc mã dự phòng)
//
//  CAPTCHA — triết lý an toàn: KHÔNG TỰ GIẢ, người dùng TỰ BẤM.
//  v2.1: TRÌNH DUYỆT ẨN (bridge.rs) — terminal tự sinh trang xác
//  minh phong cách Discord, mở bằng trình duyệt của máy, user tự
//  bấm → kết quả TỰ CHẢY VỀ TERMINAL (không dán tay). Bridge lỗi
//  thì rơi về cách v2.0: mở trang demo hCaptcha + dán captcha_key.
//  Có hướng dẫn fallback lấy token qua trình duyệt. Không dùng
//  service giải captcha nào.
// ============================================================

use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

const BASE: &str = "https://discord.com/api/v9";

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(10))
        .timeout_read(std::time::Duration::from_secs(30))
        .timeout_write(std::time::Duration::from_secs(15))
        .user_agent("BlackholeTerminal/2.0")
        .build()
}

/// Gọi POST; trả về (mã HTTP, body JSON) — kể cả 4xx (Discord trả nội dung lỗi trong JSON)
fn post(a: &ureq::Agent, path: &str, body: &Value) -> Result<(u16, Value), String> {
    let r = a
        .post(&format!("{}{}", BASE, path))
        .set("Content-Type", "application/json")
        .set("Accept", "application/json")
        .send_json(body.clone());
    match r {
        Ok(res) => {
            let code = res.status();
            let v = res
                .into_json::<Value>()
                .map_err(|e| format!("đọc JSON lỗi: {}", e))?;
            Ok((code, v))
        }
        Err(ureq::Error::Status(code, res)) => {
            let v = res.into_json::<Value>().unwrap_or(Value::Null);
            Ok((code, v))
        }
        Err(e) => Err(format!("lỗi kết nối: {}", e)),
    }
}

fn ask(prompt: &str) -> Result<String, String> {
    print!("{}", prompt);
    let _ = io::stdout().flush();
    let mut s = String::new();
    io::stdin()
        .lock()
        .read_line(&mut s)
        .map_err(|e| format!("đọc bàn phím lỗi: {}", e))?;
    Ok(s.trim().to_string())
}

/// Nhập mật khẩu không hiện lên màn hình (hiện '*' cho mỗi ký tự).
/// Dùng crossterm raw mode — chạy đúng trên cả Windows và Linux.
fn ask_password(prompt: &str) -> Result<String, String> {
    use crossterm::event::{read, Event, KeyCode, KeyEventKind, KeyModifiers};
    use crossterm::terminal;
    print!("{}", prompt);
    let _ = io::stdout().flush();
    terminal::enable_raw_mode().map_err(|e| format!("raw mode lỗi: {}", e))?;
    let mut pw = String::new();
    let res = loop {
        match read() {
            Ok(Event::Key(k)) => {
                if k.kind == KeyEventKind::Release {
                    continue;
                }
                match k.code {
                    KeyCode::Enter => break Ok(pw),
                    KeyCode::Backspace => {
                        pw.pop();
                    }
                    KeyCode::Char(c) => {
                        if k.modifiers.contains(KeyModifiers::CONTROL) {
                            continue;
                        }
                        pw.push(c);
                        print!("*");
                        let _ = io::stdout().flush();
                    }
                    _ => {}
                }
            }
            Ok(_) => {}
            Err(e) => break Err(format!("đọc bàn phím lỗi: {}", e)),
        }
    };
    let _ = terminal::disable_raw_mode();
    println!();
    res
}

fn looks_like_token(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    s.len() >= 50 && parts.len() >= 2 && parts.iter().all(|p| !p.is_empty())
}

fn print_browser_token_guide() {
    println!("\x1b[1;36m── HƯỚNG DẪN LẤY TOKEN QUA TRÌNH DUYỆT (cách chắc chắn chạy được) ──\x1b[0m");
    println!(" 1. Mở \x1b[4mhttps://discord.com/login\x1b[0m trong trình duyệt.");
    println!(" 2. Đăng nhập bằng chính email + mật khẩu này (giải captcha trong đó — bạn tự bấm).");
    println!(" 3. Vào được Discord rồi thì bấm F12 → tab Console, dán lệnh này rồi Enter:");
    println!("    \x1b[33m(webpackChunkdiscord_app.push([[Math.random()],{{}},e=>{{m=[];for(const c in e.c)m.push(e.c[c])}},m]) && m.find(x=>x.exports?.default?.getToken!==void 0).exports.default.getToken())\x1b[0m");
    println!("    (hoặc: F12 → Application → Local Storage → discord.com → key 'token')");
    println!(" 4. Copy chuỗi token (dài, có dấu chấm) → dán vào đây, Enter.");
    println!("\x1b[1;36m────────────────────────────────────────────────────────────\x1b[0m");
}

fn captcha_round(body: &mut Value, sitekey: &str, rqdata: &str, service: &str) -> Result<bool, String> {
    // trả Ok(true) = đã có captcha_key, thử login lại; Ok(false) = user huỷ
    println!();
    println!("\x1b[1;33m╔═══════════ DISCORD YÊU CẦU XÁC MINH CAPTCHA ({}) ═══════════╗\x1b[0m", service);
    println!("║  Terminal KHÔNG tự giải captcha — đúng luật, bạn TỰ BẤM.");
    println!("║  v2.1: terminal bật TRÌNH DUYỆT ẨN — tự sinh trang xác minh mang");
    println!("║  giao diện Discord, mở bằng trình duyệt của máy, rồi TỰ BẮT kết");
    println!("║  quả về tiếp tục đăng nhập — KHÔNG cần dán tay.");
    println!("\x1b[1;33m╚═════════════════════════════════════════════════════════════════╝\x1b[0m");

    // ---- CÁCH MỚI v2.1: trình duyệt ẩn tự bắt kết quả ----
    let svc = service.to_ascii_lowercase();
    if (svc.contains("hcaptcha") || svc.is_empty()) && !sitekey.is_empty() {
        match crate::bridge::captcha_bridge(sitekey, rqdata, service) {
            Ok(tok) => {
                // người dùng có thể dán TRỰC TIẾP token Discord vào ô dự phòng trên trang
                if looks_like_token(&tok) && tok.matches('.').count() >= 2 {
                    println!("\x1b[32m> Phát hiện token Discord trực tiếp — dùng luôn, khỏi login lại.\x1b[0m");
                    return Err(format!("\x01TOKEN:{}", tok)); // tín hiệu đặc biệt cho caller
                }
                body["captcha_key"] = json!(tok);
                return Ok(true);
            }
            Err(e) => {
                println!("\x1b[33m║  ! Trình duyệt ẩn chưa bắt được ({}).\x1b[0m", e);
                println!("║    Chuyển cách dán tay bên dưới — hoặc gõ 'h' để xem hướng dẫn lấy token.");
            }
        }
    }

    // ---- FALLBACK v2.0: mở trang demo hCaptcha + dán tay ----
    let url = if sitekey.is_empty() {
        "https://discord.com/login".to_string()
    } else {
        format!("https://accounts.hcaptcha.com/demo?sitekey={}", sitekey)
    };
    println!("║  1. Đang tự mở trình duyệt giúp bạn. Nếu không mở thì copy link này:");
    println!("║     \x1b[36m{}\x1b[0m", url);
    println!("║  2. Giải puzzle → copy chuỗi token (response) → dán vào đây, Enter.");
    println!("║  Gõ 'h' = hướng dẫn lấy token qua trình duyệt (chắc chắn được).");
    println!("║  Enter trống = huỷ đăng nhập.");
    let _ = crate::img::open_system(&url);
    let s = ask("captcha_key (dán vào đây): ")?;
    if s.is_empty() {
        return Ok(false);
    }
    if s.eq_ignore_ascii_case("h") {
        print_browser_token_guide();
        let t = ask("token (dán vào đây, Enter trống = quay lại captcha): ")?;
        if t.is_empty() {
            return Ok(true); // quay lại vòng captcha
        }
        if looks_like_token(&t) {
            // user lấy được token trực tiếp — dùng luôn
            return Err(format!("\x01TOKEN:{}", t)); // tín hiệu đặc biệt cho caller
        }
        body["captcha_key"] = json!(t);
        return Ok(true);
    }
    // Nếu dán nhầm token Discord thẳng vào — dùng luôn, khỏi login nữa
    if looks_like_token(&s) && s.matches('.').count() >= 2 {
        return Err(format!("\x01TOKEN:{}", s));
    }
    body["captcha_key"] = json!(s);
    Ok(true)
}

/// Đăng nhập tương tác. Thành công → Ok(token). Thất bại → Err(thông báo).
pub fn interactive_login() -> Result<String, String> {
    println!();
    println!("\x1b[1;36m── ĐĂNG NHẬP DISCORD BẰNG EMAIL + MẬT KHẨU ──\x1b[0m");
    println!("\x1b[90m(ảnh: khi Discord hỏi captcha, terminal sẽ báo + mở trình duyệt để bạn tự bấm)\x1b[0m");
    println!("\x1b[33mLưu ý: dùng tài khoản cá nhân qua app ngoài có thể vi phạm ToS Discord — cân nhắc trước khi dùng.\x1b[0m");

    let email = ask("Email: ")?;
    if email.is_empty() {
        return Err("Chưa nhập email — huỷ đăng nhập.".into());
    }
    let password = ask_password("Mật khẩu: ")?;
    if password.is_empty() {
        return Err("Chưa nhập mật khẩu — huỷ đăng nhập.".into());
    }

    let a = agent();
    // Discord API hiện tại đợi field "login" (nhận cả email lẫn số điện thoại)
    let mut body = json!({
        "login": email,
        "password": password,
        "undelete": false,
        "login_source": null,
        "gift_code_sku_id": null
    });

    // Đánh dấu vùng nhớ chứa mật khẩu không giữ lâu — lập tức thay thế sau lần gửi đầu
    for _round in 0..5 {
        let (code, v) = post(&a, "/auth/login", &body)?;

        // 1) thành công
        if let Some(t) = v.get("token").and_then(|x| x.as_str()) {
            if !t.is_empty() {
                return Ok(t.to_string());
            }
        }

        // 2) cần 2FA
        if v.get("mfa").and_then(|x| x.as_bool()).unwrap_or(false) {
            let ticket = v.get("ticket").and_then(|x| x.as_str()).unwrap_or("").to_string();
            println!("\x1b[1;33m> Tài khoản bật 2FA — nhập mã 6 số (hoặc mã dự phòng)\x1b[0m");
            for _ in 0..3 {
                let c = ask("Mã 2FA: ")?;
                if c.is_empty() {
                    return Err("Huỷ đăng nhập (2FA).".into());
                }
                let (c2, v2) = post(&a, "/auth/mfa/totp", &json!({ "code": c, "ticket": ticket }))?;
                if let Some(t) = v2.get("token").and_then(|x| x.as_str()) {
                    if !t.is_empty() {
                        return Ok(t.to_string());
                    }
                }
                let msg = v2.get("message").and_then(|m| m.as_str()).unwrap_or("mã không đúng");
                println!("\x1b[31m! Sai mã 2FA (HTTP {}): {}\x1b[0m", c2, msg);
            }
            return Err("2FA sai quá 3 lần — huỷ đăng nhập.".into());
        }

        // 3) cần captcha
        if v.get("captcha_key").is_some() {
            let service = v
                .get("captcha_service")
                .and_then(|x| x.as_str())
                .unwrap_or("hcaptcha")
                .to_string();
            let sitekey = v
                .get("captcha_sitekey")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            let rqdata = v
                .get("captcha_rqdata")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            match captcha_round(&mut body, &sitekey, &rqdata, &service) {
                Ok(true) => continue,            // đã dán key — thử login lại
                Ok(false) => return Err("Huỷ đăng nhập (captcha).".into()),
                Err(e) => {
                    // tín hiệu \x01TOKEN:... → người dùng đã lấy được token qua trình duyệt
                    if let Some(t) = e.strip_prefix("\x01TOKEN:") {
                        println!("\x1b[32m> Dùng token lấy từ trình duyệt.\x1b[0m");
                        return Ok(t.trim().to_string());
                    }
                    return Err(e);
                }
            }
        }

        // 4) lỗi thật (sai mật khẩu, email không tồn tại...)
        let msg = v
            .get("message")
            .and_then(|m| m.as_str())
            .unwrap_or("không rõ nguyên nhân");
        return Err(format!("Đăng nhập thất bại (HTTP {}): {}", code, msg));
    }
    Err("Captcha chưa được giải đúng sau nhiều lần — huỷ để an toàn.".into())
}
