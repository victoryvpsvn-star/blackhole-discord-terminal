// ============================================================
//  gw.rs — Gateway Discord qua WebSocket (1 luồn nền)
//  Realtime: MESSAGE_CREATE / UPDATE / DELETE
//  Heartbeat đúng nhịp + tự nối lại khi rớt (backoff 2s -> 60s)
// ============================================================

use crate::api::parse_msg;
use crate::Ev;
use serde_json::{json, Value};
use std::io;
use std::net::TcpStream;
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{connect, Message, WebSocket};

type Ws = WebSocket<MaybeTlsStream<TcpStream>>;

enum SessErr {
    MainGone,          // cửa sổ chính đã đóng -> dừng luồn
    Net(String),       // lỗi mạng/gateway -> thử lại
}

/// Bật luồn gateway chạy nền suốt chương trình
pub fn spawn(token: String, bot: bool, tx: Sender<Ev>) {
    let _ = std::thread::Builder::new()
        .name("blackhole-gateway".to_string())
        .spawn(move || run(token, bot, tx));
}

fn run(token: String, bot: bool, tx: Sender<Ev>) {
    let mut backoff: u64 = 2;
    loop {
        let started = Instant::now();
        match session(&token, bot, &tx) {
            Err(SessErr::MainGone) => return,
            Err(SessErr::Net(e)) => {
                if started.elapsed() > Duration::from_secs(300) {
                    backoff = 2; // kết nối trước đó tốt -> hồi nhanh
                }
                // Báo qua kênh event thay vì eprintln — để UI tự hiển thị (không phá màn hình TUI)
                let msg = format!(
                    "gateway rớt: {} — thử lại sau {}s (tin nhắn trong lúc rớt sẽ thiếu, gõ /history để nạp lại)",
                    e, backoff
                );
                if tx.send(Ev::NetErr(msg)).is_err() {
                    return;
                }
            }
            Ok(()) => return,
        }
        std::thread::sleep(Duration::from_secs(backoff));
        backoff = (backoff.saturating_mul(2)).min(60);
    }
}

fn session(token: &str, bot: bool, tx: &Sender<Ev>) -> Result<(), SessErr> {
    let (mut ws, interval) = connect_ws().map_err(SessErr::Net)?;

    // User token: không gửi intents (tài khoản cá nhân nhận đủ event)
    // Bot token: cần intents GUILDS | GUILD_MESSAGES | MESSAGE_CONTENT = 33281
    let identify = if bot {
        json!({
            "token": token,
            "intents": 33281,
            "properties": { "os": "linux", "browser": "Chrome", "device": "Chrome" }
        })
    } else {
        json!({
            "token": token,
            "properties": { "os": "windows", "browser": "Chrome", "device": "Chrome" },
            "presence": { "status": "online", "afk": false, "activities": [], "since": null }
        })
    };
    ws.send(Message::text(json!({ "op": 2, "d": identify }).to_string()))
        .map_err(|e| SessErr::Net(format!("gửi identify lỗi: {}", e)))?;

    let mut seq: Option<u64> = None;
    let mut next_hb = Instant::now() + interval;
    loop {
        if Instant::now() >= next_hb {
            let hb = json!({ "op": 1, "d": seq });
            ws.send(Message::text(hb.to_string()))
                .map_err(|e| SessErr::Net(format!("gửi heartbeat lỗi: {}", e)))?;
            next_hb = Instant::now() + interval;
        }
        // Timeout đọc = thời gian còn lại tới nhịp heartbeat
        let wait = next_hb
            .saturating_duration_since(Instant::now())
            .min(Duration::from_secs(15));
        set_timeout(&ws, wait);
        match ws.read() {
            Ok(Message::Text(txt)) => {
                let v: Value = match serde_json::from_str(&txt) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                if let Some(s) = v.get("s").and_then(|x| x.as_u64()) {
                    seq = Some(s);
                }
                match v.get("op").and_then(|x| x.as_u64()).unwrap_or(0) {
                    1 => {
                        // server yêu cầu heartbeat ngay
                        let hb = json!({ "op": 1, "d": seq });
                        ws.send(Message::text(hb.to_string()))
                            .map_err(|e| SessErr::Net(e.to_string()))?;
                        next_hb = Instant::now() + interval;
                    }
                    9 => {
                        return Err(SessErr::Net(
                            "phiên bị từ chối — kiểm tra token (và MESSAGE CONTENT INTENT nếu dùng bot)"
                                .to_string(),
                        ))
                    }
                    0 => dispatch(&v, tx)?,
                    _ => {}
                }
            }
            Ok(Message::Close(_)) => return Err(SessErr::Net("server đóng kết nối".to_string())),
            Ok(Message::Ping(p)) => {
                let _ = ws.send(Message::Pong(p));
            }
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => {}
            Err(e) => return Err(SessErr::Net(e.to_string())),
        }
    }
}

fn dispatch(v: &Value, tx: &Sender<Ev>) -> Result<(), SessErr> {
    let t = v.get("t").and_then(|x| x.as_str()).unwrap_or("");
    let d = v.get("d");
    let cid = d
        .and_then(|x| x.get("channel_id"))
        .and_then(|x| x.as_str())
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    match t {
        "MESSAGE_CREATE" => {
            if cid != 0 {
                if let Some(m) = d.and_then(parse_msg) {
                    tx.send(Ev::New(cid, m)).map_err(|_| SessErr::MainGone)?;
                }
            }
        }
        "MESSAGE_UPDATE" => {
            let mid = d
                .and_then(|x| x.get("id"))
                .and_then(|x| x.as_str())
                .and_then(|s| s.parse::<u64>().ok());
            let content = d
                .and_then(|x| x.get("content"))
                .and_then(|x| x.as_str())
                .map(|s| s.to_string());
            if cid != 0 {
                if let (Some(mid), Some(c)) = (mid, content) {
                    tx.send(Ev::Edited(cid, mid, c)).map_err(|_| SessErr::MainGone)?;
                }
            }
        }
        "MESSAGE_DELETE" => {
            let mid = d
                .and_then(|x| x.get("id"))
                .and_then(|x| x.as_str())
                .and_then(|s| s.parse::<u64>().ok());
            if cid != 0 {
                if let Some(mid) = mid {
                    tx.send(Ev::Deleted(cid, mid)).map_err(|_| SessErr::MainGone)?;
                }
            }
        }
        _ => {}
    }
    Ok(())
}

fn connect_ws() -> Result<(Ws, Duration), String> {
    let (mut ws, _resp) = connect("wss://gateway.discord.gg/?v=10&encoding=json")
        .map_err(|e| format!("không nối được gateway: {}", e))?;
    set_timeout(&ws, Duration::from_secs(15));
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if Instant::now() > deadline {
            return Err("không nhận được HELLO từ gateway".to_string());
        }
        match ws.read() {
            Ok(Message::Text(txt)) => {
                if let Ok(v) = serde_json::from_str::<Value>(&txt) {
                    if v.get("op").and_then(|x| x.as_u64()) == Some(10) {
                        let ms = v
                            .pointer("/d/heartbeat_interval")
                            .and_then(|x| x.as_u64())
                            .unwrap_or(41250);
                        let ms = ms.saturating_sub(2000).max(5000);
                        return Ok((ws, Duration::from_millis(ms)));
                    }
                }
            }
            Ok(Message::Close(_)) => return Err("gateway đóng ngay khi vừa nối".to_string()),
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => {}
            Err(e) => return Err(e.to_string()),
        }
    }
}

/// Đặt read/write timeout cho socket bên dưới (để heartbeat đúng nhịp)
fn set_timeout(ws: &Ws, d: Duration) {
    #[allow(unreachable_patterns)]
    match ws.get_ref() {
        MaybeTlsStream::Plain(s) => {
            let _ = s.set_read_timeout(Some(d));
            let _ = s.set_write_timeout(Some(Duration::from_secs(15)));
        }
        MaybeTlsStream::Rustls(s) => {
            let _ = s.sock.set_read_timeout(Some(d));
            let _ = s.sock.set_write_timeout(Some(Duration::from_secs(15)));
        }
        _ => {}
    }
}
