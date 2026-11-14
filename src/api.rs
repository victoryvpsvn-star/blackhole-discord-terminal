// ============================================================
//  api.rs — REST Discord (ureq + rustls, KHONG OpenSSL)
//  Chong 429 (rate limit) tu dong, parse tin nhan gọn nhẹ
// ============================================================

use serde_json::{json, Value};
use std::io::Read;
use std::time::Duration;

pub struct Api {
    agent: ureq::Agent,
    auth: String,
}

/// File đính kèm (ảnh/file) trong tin nhắn
#[derive(Clone, Debug)]
pub struct Att {
    pub name: String,
    pub url: String,
    pub w: u32,
    pub h: u32,
    pub size: u64,
    pub ctype: String,
}

impl Att {
    pub fn is_image(&self) -> bool {
        self.ctype.starts_with("image/") ||
        self.name.to_ascii_lowercase().ends_with(".png") ||
        self.name.to_ascii_lowercase().ends_with(".jpg") ||
        self.name.to_ascii_lowercase().ends_with(".jpeg") ||
        self.name.to_ascii_lowercase().ends_with(".gif") ||
        self.name.to_ascii_lowercase().ends_with(".webp")
    }
}

/// Định dạng kích thước file dễ đọc: 1.2 MB / 350.0 KB / 12 B
pub fn fmt_size(n: u64) -> String {
    if n >= 1_048_576 {
        format!("{:.1} MB", n as f64 / 1_048_576.0)
    } else if n >= 1024 {
        format!("{:.1} KB", n as f64 / 1024.0)
    } else {
        format!("{} B", n)
    }
}

#[derive(Clone, Debug)]
pub struct DiscordMsg {
    pub id: u64,
    pub author_id: u64,
    pub author: String,
    pub content: String,
    pub time: String, // ISO thô từ Discord
    pub edited: bool,
    pub reply_to: Option<(u64, String)>, // (id tin được reply, tên tác giả)
    pub atts: Vec<Att>,                  // file/ảnh đính kèm
}

/// Lấy tên hiển thị đẹp nhất từ object user
pub fn display_name(v: &Value) -> String {
    v.get("global_name")
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .or_else(|| v.get("username").and_then(|x| x.as_str()))
        .unwrap_or("?")
        .to_string()
}

impl Api {
    pub fn new(token: &str, bot: bool) -> Api {
        let auth = if bot && !token.starts_with("Bot ") {
            format!("Bot {}", token)
        } else {
            token.to_string()
        };
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout_read(Duration::from_secs(30))
            .timeout_write(Duration::from_secs(15))
            .user_agent("BlackholeTerminal/2.0")
            .build();
        Api { agent, auth }
    }

    /// Gọi API, tự thử lại khi bị 429, trả về JSON
    fn call(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value, String> {
        let url = format!("https://discord.com/api/v10{}", path);
        for _ in 0..3 {
            let req = self
                .agent
                .request(method, &url)
                .set("Authorization", &self.auth)
                .set("Accept", "application/json");
            let resp = match &body {
                Some(b) => req.send_json(b.clone()),
                None => req.call(),
            };
            match resp {
                Ok(r) => {
                    if r.status() == 204 {
                        return Ok(Value::Null);
                    }
                    let mut txt = String::new();
                    if r.into_reader().read_to_string(&mut txt).is_err() {
                        return Err("đọc dữ liệu lỗi".into());
                    }
                    if txt.is_empty() {
                        return Ok(Value::Null);
                    }
                    return serde_json::from_str(&txt).map_err(|e| format!("JSON lỗi: {}", e));
                }
                Err(ureq::Error::Status(code, r)) => {
                    let mut txt = String::new();
                    let _ = r.into_reader().read_to_string(&mut txt);
                    if code == 429 {
                        let wait: f64 = serde_json::from_str::<Value>(&txt)
                            .ok()
                            .and_then(|v| v.get("retry_after").and_then(|x| x.as_f64()))
                            .unwrap_or(1.0);
                        std::thread::sleep(Duration::from_millis((wait * 1000.0) as u64 + 300));
                        continue;
                    }
                    let msg = serde_json::from_str::<Value>(&txt)
                        .ok()
                        .and_then(|v| v.get("message").and_then(|m| m.as_str()).map(|s| s.to_string()))
                        .unwrap_or_else(|| txt.chars().take(160).collect());
                    return Err(format!("HTTP {}: {}", code, msg));
                }
                Err(e) => return Err(format!("lỗi mạng: {}", e)),
            }
        }
        Err("bị giới hạn (429) nhiều lần, thử lại sau".into())
    }

    pub fn me(&self) -> Result<Value, String> {
        self.call("GET", "/users/@me", None)
    }

    pub fn guilds(&self) -> Result<Value, String> {
        self.call("GET", "/users/@me/guilds?limit=100", None)
    }

    pub fn guild_channels(&self, gid: u64) -> Result<Value, String> {
        self.call("GET", &format!("/guilds/{}/channels", gid), None)
    }

    pub fn dm_channels(&self) -> Result<Value, String> {
        self.call("GET", "/users/@me/channels", None)
    }

    pub fn channel(&self, cid: u64) -> Result<Value, String> {
        self.call("GET", &format!("/channels/{}", cid), None)
    }

    pub fn messages(&self, cid: u64, before: Option<u64>, limit: u32) -> Result<Value, String> {
        let mut path = format!("/channels/{}/messages?limit={}", cid, limit);
        if let Some(b) = before {
            path.push_str(&format!("&before={}", b));
        }
        self.call("GET", &path, None)
    }

    pub fn send(&self, cid: u64, content: &str, reply_to: Option<u64>) -> Result<Value, String> {
        let mut b = json!({ "content": content });
        if let Some(rid) = reply_to {
            // ID phải là STRING Discord mới parse đúng (số lớn mất chính xác)
            b["message_reference"] = json!({ "message_id": rid.to_string(), "type": 0 });
        }
        self.call("POST", &format!("/channels/{}/messages", cid), Some(b))
    }

    pub fn edit(&self, cid: u64, mid: u64, content: &str) -> Result<Value, String> {
        self.call(
            "PATCH",
            &format!("/channels/{}/messages/{}", cid, mid),
            Some(json!({ "content": content })),
        )
    }

    pub fn delete(&self, cid: u64, mid: u64) -> Result<Value, String> {
        self.call("DELETE", &format!("/channels/{}/messages/{}", cid, mid), None)
    }

    pub fn typing(&self, cid: u64) -> Result<Value, String> {
        self.call("POST", &format!("/channels/{}/typing", cid), None)
    }
}

/// Parse 1 object message JSON thành DiscordMsg
pub fn parse_msg(v: &Value) -> Option<DiscordMsg> {
    let id = v.get("id")?.as_str()?.parse::<u64>().ok()?;
    let author_v = v.get("author")?;
    let author_id = author_v.get("id")?.as_str()?.parse::<u64>().ok()?;
    let author = display_name(author_v);

    let mut content = v.get("content").and_then(|x| x.as_str()).unwrap_or("").to_string();

    // Decode mention <@id> / <@!id> thành @tên
    if let Some(ms) = v.get("mentions").and_then(|x| x.as_array()) {
        for u in ms {
            let uid = u.get("id").and_then(|x| x.as_str()).unwrap_or("");
            if uid.is_empty() {
                continue;
            }
            let nm = display_name(u);
            content = content.replace(&format!("<@{}>", uid), &format!("@{}", nm));
            content = content.replace(&format!("<@!{}>", uid), &format!("@{}", nm));
        }
    }
    // Đính kèm: tách từng file — ảnh ghi rõ kích thước để /img xem được
    let mut atts: Vec<Att> = vec![];
    if let Some(arr) = v.get("attachments").and_then(|x| x.as_array()) {
        for a in arr {
            let name = a.get("filename").and_then(|x| x.as_str()).unwrap_or("file").to_string();
            let url = a.get("url").and_then(|x| x.as_str()).unwrap_or("").to_string();
            if url.is_empty() {
                continue;
            }
            let ctype = a.get("content_type").and_then(|x| x.as_str()).unwrap_or("").to_string();
            let w = a.get("width").and_then(|x| x.as_u64()).unwrap_or(0) as u32;
            let h = a.get("height").and_then(|x| x.as_u64()).unwrap_or(0) as u32;
            let size = a.get("size").and_then(|x| x.as_u64()).unwrap_or(0);
            atts.push(Att { name, url, w, h, size, ctype });
        }
    }
    if !atts.is_empty() {
        content.push(' ');
        for a in &atts {
            if a.is_image() {
                content.push_str(&format!("[ảnh: {} {}x{}] ", a.name, a.w, a.h));
            } else {
                content.push_str(&format!("[file: {} ({})] ", a.name, fmt_size(a.size)));
            }
        }
        while content.ends_with(' ') {
            content.pop();
        }
    }
    if v.get("embeds").and_then(|x| x.as_array()).map_or(false, |a| !a.is_empty()) {
        content.push_str(" [embed]");
    }
    if content.is_empty() {
        content.push_str("[trống]");
    }

    let time = v.get("timestamp").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let edited = v.get("edited_timestamp").map_or(false, |x| !x.is_null());
    let reply_to = v.get("referenced_message").and_then(|r| {
        let rid = r.get("id").and_then(|x| x.as_str()).and_then(|s| s.parse::<u64>().ok())?;
        let nm = r
            .get("author")
            .map(display_name)
            .unwrap_or_else(|| "?".to_string());
        Some((rid, nm))
    });

    Some(DiscordMsg { id, author_id, author, content, time, edited, reply_to, atts })
}
