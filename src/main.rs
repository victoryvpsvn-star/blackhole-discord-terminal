// ============================================================
//  BLACKHOLE v2.1 — Discord terminal siêu nhẹ (100% Rust)
//
//  Mới trong v2.1:
//   • TRÌNH DUYỆT ẨN (bridge.rs): tự sinh trang xác minh phong cách Discord,
//     mở bằng trình duyệt của máy, bạn tự bấm captcha → terminal TỰ BẮT kết quả
//   • /voice: mượn trình duyệt vào được voice/stage channel (voice chạy trên browser,
//     terminal vẫn chat realtime song song)
//   • Đẩy lên GitHub: Actions build 5 bản tự gửi Discord webhook
//
//  Từ v2.0:
//   • Giao diện full-screen kiểu discordo (tui.rs) + line-mode cũ
//   • Xem ảnh ngay trong terminal: /img · /save · /open (img.rs)
//   • Đăng nhập EMAIL + PASSWORD, 2FA (login.rs)
//   • --demo: xem giao diện không cần tài khoản
//   • Lỗi gateway hiện thành notice, không phá màn hình
//
//  Không tokio, không ratatui, không openssl — chỉ std + ureq +
//  tungstenite + crossterm (raw/phím) + image (decode ảnh)
//
//  Luồng: main (UI + REST)  |  gateway (WS realtime)  |  input
// ============================================================

use std::collections::VecDeque;
use std::io::{self, BufRead, IsTerminal, Write};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::Duration;

mod api;
mod bridge;
mod gw;
mod img;
mod login;
mod tui;

use api::{display_name, parse_msg, Api, DiscordMsg};

/// Số tin nhắn giữ trong RAM cho mỗi kênh (ring buffer)
pub const CAP: usize = 200;

/// Sự kiện đổ về vòng lặp chính
pub enum Ev {
    Line(String),             // một dòng người dùng gõ (chế độ line)
    New(u64, DiscordMsg),     // tin nhắn mới (kênh_id)
    Edited(u64, u64, String), // tin bị sửa (kênh_id, tin_id, nội dung)
    Deleted(u64, u64),        // tin bị xóa (kênh_id, tin_id)
    NetErr(String),           // lỗi gateway → notice (không eprintln — phá TUI)
}

/// Kết quả của một lệnh
#[derive(PartialEq)]
pub enum Act {
    Continue,
    Quit,
}

/// Đầu ra của một lệnh — 2 chế độ UI cùng dùng
pub enum Out {
    Text(String), // notice 1 dòng (có màu ANSI)
    Overlay { title: String, lines: Vec<String> }, // /help, /img → overlay
}

pub struct State {
    me_id: u64,
    me_name: String,
    guilds: Vec<(u64, String)>,
    chans: Vec<(u64, String)>,
    dms: Vec<(u64, String)>,
    cur: Option<(u64, String)>, // kênh hiện tại (id, tên)
    buf: VecDeque<DiscordMsg>,
    tz: i32,
    demo: bool,    // --demo: dữ liệu giả, chặn mọi call mạng
    dm_mode: bool, // danh sách kênh trong sidebar = danh sách DM
}

fn txt(s: String) -> Out {
    Out::Text(s)
}

fn main() {
    // ---- tham số dòng lệnh ----
    let mut token: Option<String> = None;
    let mut bot_flag = false;
    let mut save_flag = false;
    let mut plain = false;
    let mut demo = false;
    let mut smoke = false;
    let mut force_login = false;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--token" => token = args.next().map(|t| t.trim().to_string()),
            "--bot" => bot_flag = true,
            "--save" => save_flag = true,
            "--plain" => plain = true,   // ép chế độ dòng lệnh
            "--demo" => demo = true,     // dữ liệu giả, không cần mạng
            "--smoke" => { demo = true; smoke = true; } // test tự thoát (CI)
            "--login" => force_login = true, // ép đăng nhập lại bằng email
            "--help" | "-h" => {
                print_usage();
                return;
            }
            _ => {}
        }
    }

    enable_ansi();

    if demo {
        run_demo(plain, smoke);
        return;
    }

    // ---- đăng nhập ----
    let (token, bot, persist, me) = match auth_flow(token, bot_flag, save_flag, force_login) {
        Some(x) => x,
        None => return,
    };
    let me_id = me
        .get("id")
        .and_then(|x| x.as_str())
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    let me_name = display_name(&me);

    banner();
    println!("> Đăng nhập: {} (id {})", me_name, me_id);
    let api = Api::new(&token, bot);
    if persist {
        save_config(Some(&token), None);
        println!("\x1b[90m> Đã lưu token vào ~/.blackhole/config (mở lần sau khỏi nhập) — /logout để xóa\x1b[0m");
    }
    if bot {
        println!("> Chế độ BOT — nhớ bật MESSAGE CONTENT INTENT trong Developer Portal");
    }

    let mut st = State {
        me_id,
        me_name,
        guilds: vec![],
        chans: vec![],
        dms: vec![],
        cur: None,
        buf: VecDeque::new(),
        tz: tz_offset(),
        demo: false,
        dm_mode: false,
    };

    // ---- mở kênh đã lưu lần chạy trước (mở phát chạy liền) ----
    let (_, cfg_channel) = load_config();
    if let Some(cid) = cfg_channel {
        match open_channel(&mut st, &api, cid) {
            Ok(lines) => {
                for l in lines {
                    println!("{}", l);
                }
                save_config(None, Some(cid));
            }
            Err(e) => println!("! Không mở được kênh đã lưu ({}): {}", cid, e),
        }
    }

    // ---- luồn gateway realtime ----
    let (tx, rx) = mpsc::channel::<Ev>();
    gw::spawn(token.clone(), bot, tx.clone());

    // ---- chọn chế độ giao diện ----
    let use_tui = !plain && io::stdin().is_terminal() && io::stdout().is_terminal();
    if use_tui {
        println!("> Vào giao diện — Tab: chọn server/kênh • /help: mọi lệnh • Ctrl+C: thoát");
        match tui::run(&mut st, &api, &rx, None) {
            Ok(()) => {}
            Err(e) => println!("\x1b[33m! Giao diện không bật được ({}) — chuyển chế độ dòng lệnh\x1b[0m", e),
        }
        save_config(if persist { Some(&token) } else { None }, st.cur.as_ref().map(|x| x.0));
        println!("Tạm biệt. BLACKHOLE out.");
    } else {
        line_mode(&mut st, &api, &rx, &tx, persist, &token);
    }
}

// ================= ĐĂNG NHẬP =================

/// Chuỗi đăng nhập đầy đủ: tham số > env > config > menu email/token,
/// kiểm tra token bằng /users/@me, hỏng thì đề nghị đăng nhập lại.
fn auth_flow(
    token_arg: Option<String>,
    bot_flag: bool,
    save_flag: bool,
    force_login: bool,
) -> Option<(String, bool, bool, serde_json::Value)> {
    let (cfg_token, _) = load_config();
    let had_cfg = cfg_token.is_some();
    let mut persist = save_flag || had_cfg;

    let mut tok = token_arg
        .or_else(|| std::env::var("BLACKHOLE_TOKEN").ok())
        .filter(|t| !t.trim().is_empty());
    if force_login {
        tok = None;
    }
    if tok.is_none() {
        tok = cfg_token.filter(|t| !t.is_empty());
    }

    loop {
        let cur = match tok.take() {
            Some(t) => t,
            None => {
                println!("\x1b[1;36m╔══════════════════════════════════════════════════╗");
                println!("║   BLACKHOLE v2.1 — ĐĂNG NHẬP DISCORD             ║");
                println!("╚══════════════════════════════════════════════════╝\x1b[0m");
                println!(" 1) Email + mật khẩu  (gặp captcha: mở TRÌNH DUYỆT ẨN phong cách");
                println!("    Discord — bạn tự bấm, terminal tự bắt kết quả tiếp tục)");
                println!(" 2) Dán token trực tiếp (user token, hoặc 'Bot xxx' cho bot)");
                print!("Chọn [1/2] (mặc định 1): ");
                let _ = io::stdout().flush();
                let mut s = String::new();
                let _ = io::stdin().read_line(&mut s);
                if s.trim() == "2" {
                    print!("Token: ");
                    let _ = io::stdout().flush();
                    let mut t = String::new();
                    if io::stdin().read_line(&mut t).is_err() {
                        return None;
                    }
                    let t = t.trim().to_string();
                    if t.is_empty() {
                        println!("Không có token — thoát.");
                        return None;
                    }
                    t
                } else {
                    match login::interactive_login() {
                        Ok(t) => {
                            persist = true; // đăng nhập email thì tự lưu token
                            t
                        }
                        Err(e) => {
                            println!("! {}", e);
                            return None;
                        }
                    }
                }
            }
        };

        let bot = bot_flag || cur.starts_with("Bot ");
        let api = Api::new(&cur, bot);
        match api.me() {
            Ok(me) => return Some((cur, bot, persist, me)),
            Err(e) => {
                println!("! Token không dùng được: {}", e);
                print!("Đăng nhập lại bằng email + mật khẩu? [Y/n]: ");
                let _ = io::stdout().flush();
                let mut s = String::new();
                let _ = io::stdin().read_line(&mut s);
                let s = s.trim().to_ascii_lowercase();
                if s.is_empty() || s == "y" || s == "yes" {
                    tok = None; // vòng lặp → hiện menu đăng nhập
                    continue;
                }
                return None;
            }
        }
    }
}

// ================= CHẾ ĐỘ DÒNG LỆNH (fallback / pipe) =================

fn line_mode(st: &mut State, api: &Api, rx: &Receiver<Ev>, tx: &Sender<Ev>, persist: bool, token: &str) {
    // ---- luồn đọc bàn phím ----
    {
        let tx2 = tx.clone();
        std::thread::spawn(move || {
            let stdin = io::stdin();
            for line in stdin.lock().lines() {
                match line {
                    Ok(l) => {
                        if tx2.send(Ev::Line(l)).is_err() {
                            return;
                        }
                    }
                    Err(_) => return,
                }
            }
        });
    }

    print_prompt(st);
    let _ = io::stdout().flush();

    while let Ok(ev) = rx.recv() {
        match ev {
            Ev::Line(l) => {
                let (outs, act) = handle_line(st, api, &l, false);
                for o in outs {
                    match o {
                        Out::Text(t) => println!("{}", t),
                        Out::Overlay { lines, .. } => {
                            for l in lines {
                                println!("{}", l);
                            }
                        }
                    }
                }
                if act == Act::Quit {
                    break;
                }
            }
            Ev::New(cid, m) => {
                let (prints, n) = on_new(st, cid, m);
                for p in prints {
                    println!("{}", p);
                }
                if !n.is_empty() {
                    println!("\x1b[90m{}\x1b[0m", n);
                }
            }
            Ev::Edited(cid, mid, c) => {
                let (prints, n) = on_edited(st, cid, mid, &c);
                for p in prints {
                    println!("{}", p);
                }
                if !n.is_empty() {
                    println!("\x1b[90m{}\x1b[0m", n);
                }
            }
            Ev::Deleted(cid, mid) => {
                let (prints, n) = on_deleted(st, cid, mid);
                for p in prints {
                    println!("{}", p);
                }
                if !n.is_empty() {
                    println!("\x1b[90m{}\x1b[0m", n);
                }
            }
            Ev::NetErr(e) => println!("\x1b[33m!\x1b[0m {}", e),
        }
        print_prompt(st);
        let _ = io::stdout().flush();
    }
    save_config(if persist { Some(token) } else { None }, st.cur.as_ref().map(|x| x.0));
    println!("Tạm biệt. BLACKHOLE out.");
}

// ================= LỆNH (dùng chung cho cả 2 chế độ UI) =================

pub fn handle_line(st: &mut State, api: &Api, line: &str, _tui: bool) -> (Vec<Out>, Act) {
    let mut outs: Vec<Out> = vec![];
    let line = line.trim();
    if line.is_empty() {
        return (outs, Act::Continue);
    }
    // Gõ thường = gửi tin nhắn luôn
    if !line.starts_with('/') {
        send_msg(st, api, line, None, &mut outs);
        return (outs, Act::Continue);
    }
    let (cmd, rest) = split2(line);
    match cmd {
        "/help" => outs.push(Out::Overlay {
            title: "LỆNH & PHÍM BLACKHOLE".into(),
            lines: help_lines(),
        }),
        "/quit" | "/exit" => return (outs, Act::Quit),
        "/me" => outs.push(txt(format!("> Đăng nhập: {} (id {})", st.me_name, st.me_id))),
        "/logout" => {
            clear_token_config();
            outs.push(txt("✓ Đã xóa token khỏi config — lần sau mở app sẽ phải đăng nhập lại".into()));
        }
        "/guilds" => cmd_guilds(st, api, &mut outs),
        "/channels" | "/ch" => cmd_channels_cmd(st, api, rest, &mut outs),
        "/dms" => cmd_dms(st, api, &mut outs),
        "/go" => cmd_go(st, api, rest, &mut outs),
        "/voice" => cmd_voice(st, api, rest, &mut outs),
        "/more" => cmd_more(st, api, &mut outs),
        "/history" | "/hist" => cmd_history(st, api, &mut outs),
        "/clear" => {
            st.buf.clear();
            outs.push(txt("✓ Đã dọn khung tin nhắn (dùng ↑ để cuộn, /history nạp lại)".into()));
        }
        "/m" => {
            if rest.is_empty() {
                outs.push(txt("! Dùng: /m <nội dung>".into()));
            } else {
                send_msg(st, api, rest, None, &mut outs);
            }
        }
        "/r" | "/reply" => cmd_reply(st, api, rest, &mut outs),
        "/e" | "/edit" => cmd_edit(st, api, rest, &mut outs),
        "/d" | "/del" | "/delete" => cmd_del(st, api, rest, &mut outs),
        "/id" => cmd_id(st, rest, &mut outs),
        "/typing" => cmd_typing(st, api, &mut outs),
        "/img" => cmd_img(st, rest, &mut outs),
        "/save" => cmd_save(st, rest, &mut outs),
        "/open" => cmd_open(st, rest, &mut outs),
        _ => outs.push(txt(format!("! Lệnh không biết: {} — gõ /help", cmd))),
    }
    (outs, Act::Continue)
}

fn pick_att(st: &State, rest: &str) -> Result<(usize, api::Att, usize), String> {
    let (num, k) = split2(rest.trim());
    let idx: usize = num
        .parse()
        .map_err(|_| "Dùng: /img <số tin> [ảnh thứ mấy]  (vd: /img 3, /img 3 2)".to_string())?;
    let m = get_msg(st, idx).ok_or(format!("! Không có tin số {}", idx))?;
    if m.atts.is_empty() {
        return Err(format!("! Tin [{}] không có file đính kèm", idx));
    }
    let kidx = if k.is_empty() {
        // mặc định lấy ảnh đầu tiên; không có ảnh thì lấy file đầu
        m.atts.iter().position(|a| a.is_image()).unwrap_or(0)
    } else {
        k.parse::<usize>()
            .map_err(|_| "Số thứ tự file không hợp lệ".to_string())?
            .saturating_sub(1)
    };
    if kidx >= m.atts.len() {
        return Err(format!("! Tin [{}] chỉ có {} file đính kèm", idx, m.atts.len()));
    }
    Ok((idx, m.atts[kidx].clone(), kidx + 1))
}

fn cmd_img(st: &mut State, rest: &str, outs: &mut Vec<Out>) {
    if st.demo {
        outs.push(txt("(demo) ảnh chỉ là dữ liệu giả — chạy thật sẽ tải từ Discord về vẽ ngay ở đây".into()));
        return;
    }
    let (idx, att, k) = match pick_att(st, rest) {
        Ok(x) => x,
        Err(e) => {
            outs.push(txt(e));
            return;
        }
    };
    if !att.is_image() {
        outs.push(txt(format!(
            "! Tin [{}] file '{}' không phải ảnh — dùng /save {} {} để tải về",
            idx, att.name, idx, k
        )));
        return;
    }
    outs.push(txt(format!("… đang tải {} …", att.name)));
    match img::download(&att.url, img::MAX_DL) {
        Ok(bytes) => {
            let (cols, rows) = if io::stdout().is_terminal() {
                tui::term_size()
            } else {
                (100, 40)
            };
            match img::render_ansi(&bytes, cols.saturating_sub(6).max(20) as u32, rows.saturating_sub(6).max(8) as u32) {
                Ok(art) => outs.push(Out::Overlay {
                    title: format!("{} ({}x{})", att.name, att.w, att.h),
                    lines: art,
                }),
                Err(e) => outs.push(txt(format!("! {} — hoặc /save {} {}", e, idx, k))),
            }
        }
        Err(e) => outs.push(txt(format!("! {}", e))),
    }
}

fn dl_path(name: &str) -> PathBuf {
    let base = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_else(|_| ".".into());
    PathBuf::from(base).join(".blackhole").join("downloads").join(img::safe_name(name))
}

fn cmd_save(st: &mut State, rest: &str, outs: &mut Vec<Out>) {
    if st.demo {
        outs.push(txt("(demo) không tải được — chỉ xem giao diện".into()));
        return;
    }
    let (idx, att, k) = match pick_att(st, rest) {
        Ok(x) => x,
        Err(e) => {
            outs.push(txt(e));
            return;
        }
    };
    let p = dl_path(&att.name);
    match img::download_to(&att.url, &p) {
        Ok(path) => outs.push(txt(format!("✓ Đã lưu [{}] file #{} → {}", idx, k, path))),
        Err(e) => outs.push(txt(format!("! {}", e))),
    }
}

fn cmd_open(st: &mut State, rest: &str, outs: &mut Vec<Out>) {
    if st.demo {
        outs.push(txt("(demo) không mở được — chỉ xem giao diện".into()));
        return;
    }
    let (idx, att, k) = match pick_att(st, rest) {
        Ok(x) => x,
        Err(e) => {
            outs.push(txt(e));
            return;
        }
    };
    let p = dl_path(&att.name);
    match img::download_to(&att.url, &p) {
        Ok(path) => match img::open_system(&path) {
            Ok(()) => outs.push(txt(format!("✓ Đang mở [{}] file #{} — {}", idx, k, path))),
            Err(e) => outs.push(txt(format!("! {} (file đã lưu ở {})", e, path))),
        },
        Err(e) => outs.push(txt(format!("! {}", e))),
    }
}

/// /voice — mượn trình duyệt vào voice/stage channel (voice bridge).
/// Terminal không truyền tiếng (WebRTC quá nặng cho mục tiêu nhẹ),
/// nhưng 1 lệnh là mở đúng kênh voice trong Discord web đã đăng nhập.
fn cmd_voice(st: &State, api: &Api, rest: &str, outs: &mut Vec<Out>) {
    if st.demo {
        outs.push(txt("(demo) voice bridge cần đăng nhập thật — chạy không có --demo".into()));
        return;
    }
    let cid = if rest.is_empty() {
        match st.cur.as_ref() {
            Some(x) => x.0,
            None => {
                outs.push(txt("! Chưa vào kênh nào — /go <số> trước, hoặc /voice <channel_id>".into()));
                return;
            }
        }
    } else {
        match rest.parse::<u64>() {
            Ok(id) => id,
            Err(_) => {
                outs.push(txt("! /voice chỉ nhận ID kênh (Discord: bật Chế độ nhà phát triển → Copy ID)".into()));
                return;
            }
        }
    };
    let info = match api.channel(cid) {
        Ok(v) => v,
        Err(e) => {
            outs.push(txt(format!("! Không đọc được kênh: {}", e)));
            return;
        }
    };
    let ctype = info.get("type").and_then(|x| x.as_u64()).unwrap_or(0);
    let name = info.get("name").and_then(|x| x.as_str()).unwrap_or("kênh").to_string();
    if ctype != 2 && ctype != 13 {
        outs.push(txt(format!(
            "! '{}' không phải kênh voice/stage (loại {}) — /voice chỉ vào được voice",
            name, ctype
        )));
        return;
    }
    let gid = info
        .get("guild_id")
        .and_then(|x| x.as_str())
        .and_then(|s| s.parse::<u64>().ok());
    let url = match gid {
        Some(g) => format!("https://discord.com/channels/{}/{}", g, cid),
        None => format!("https://discord.com/channels/@me/{}", cid),
    };
    outs.push(txt(format!(
        "🔊 Đang mượn trình duyệt vào voice '{}' — voice chạy trên browser, terminal vẫn chat bình thường",
        name
    )));
    match img::open_system(&url) {
        Ok(()) => {
            outs.push(txt(format!("✓ Đã mở: {}", url)));
            outs.push(txt("• Trình duyệt cần đã đăng nhập Discord web (vào voice = bấm đúng kênh trong web)".into()));
            outs.push(txt("• Muốn về thì đóng tab — gateway chat của terminal không bị ảnh hưởng".into()));
        }
        Err(e) => outs.push(txt(format!(
            "! Không tự mở được trình duyệt ({}). Copy link vào trình duyệt:\n  {}",
            e, url
        ))),
    }
}

fn send_msg(st: &mut State, api: &Api, content: &str, reply_to: Option<u64>, outs: &mut Vec<Out>) {
    if st.demo {
        outs.push(txt("\x1b[33m(demo) không gửi được — không nối mạng thật. Chạy không có --demo để dùng thật.\x1b[0m".into()));
        return;
    }
    let cid = match st.cur.as_ref() {
        Some(x) => x.0,
        None => {
            outs.push(txt("! Chưa vào kênh nào — Tab chọn server → kênh, hoặc /channels rồi /go".into()));
            return;
        }
    };
    if content.chars().count() > 2000 {
        outs.push(txt("! Tin nhắn > 2000 ký tự, Discord sẽ từ chối".into()));
        return;
    }
    match api.send(cid, content, reply_to) {
        Ok(v) => {
            // Echo cục bộ cho khỏi chờ gateway; gateway sẽ tự bỏ qua (trùng id)
            if let Some(m) = parse_msg(&v) {
                st.buf.push_back(m.clone());
                while st.buf.len() > CAP {
                    st.buf.pop_front();
                }
                let idx = st.buf.len();
                outs.push(txt(format!("\x1b[32m✓\x1b[0m {}", render(idx, &m, st.tz))));
            } else {
                outs.push(txt("\x1b[32m✓ đã gửi\x1b[0m".into()));
            }
        }
        Err(e) => outs.push(txt(format!("! Gửi lỗi: {}", e))),
    }
}

fn cmd_reply(st: &mut State, api: &Api, rest: &str, outs: &mut Vec<Out>) {
    let (num, text) = split2(rest);
    let idx: usize = match num.parse() {
        Ok(n) => n,
        Err(_) => {
            outs.push(txt("! Dùng: /r <số tin> <nội dung>  (vd: /r 3 ừ đúng đó)".into()));
            return;
        }
    };
    let m = match get_msg(st, idx) {
        Some(m) => m,
        None => {
            outs.push(txt(format!("! Không có tin số {}", idx)));
            return;
        }
    };
    let preview: String = m.content.chars().take(60).collect();
    outs.push(txt(format!("\x1b[90m↪ trả lời [{}] {}:\x1b[0m {}", idx, m.author, preview)));
    send_msg(st, api, text, Some(m.id), outs);
}

fn cmd_edit(st: &mut State, api: &Api, rest: &str, outs: &mut Vec<Out>) {
    let (num, text) = split2(rest);
    let idx: usize = match num.parse() {
        Ok(n) => n,
        Err(_) => {
            outs.push(txt("! Dùng: /e <số tin> <nội dung mới>".into()));
            return;
        }
    };
    if text.is_empty() {
        outs.push(txt("! Thiếu nội dung mới".into()));
        return;
    }
    let m = match get_msg(st, idx) {
        Some(m) => m,
        None => {
            outs.push(txt(format!("! Không có tin số {}", idx)));
            return;
        }
    };
    if m.author_id != st.me_id {
        outs.push(txt(format!(
            "! Tin [{}] là của {} — chỉ sửa được tin nhắn của bạn",
            idx, m.author
        )));
        return;
    }
    let cid = match st.cur.as_ref() {
        Some(x) => x.0,
        None => return,
    };
    match api.edit(cid, m.id, text) {
        Ok(_) => {
            for mm in st.buf.iter_mut() {
                if mm.id == m.id {
                    mm.content = text.to_string();
                    mm.edited = true;
                    break;
                }
            }
            outs.push(txt(format!("\x1b[32m✓ đã sửa tin [{}]\x1b[0m", idx)));
        }
        Err(e) => outs.push(txt(format!("! Sửa lỗi: {}", e))),
    }
}

fn cmd_del(st: &mut State, api: &Api, rest: &str, outs: &mut Vec<Out>) {
    let idx: usize = match rest.trim().parse() {
        Ok(n) => n,
        Err(_) => {
            outs.push(txt("! Dùng: /d <số tin>".into()));
            return;
        }
    };
    let m = match get_msg(st, idx) {
        Some(m) => m,
        None => {
            outs.push(txt(format!("! Không có tin số {}", idx)));
            return;
        }
    };
    let cid = match st.cur.as_ref() {
        Some(x) => x.0,
        None => return,
    };
    match api.delete(cid, m.id) {
        Ok(_) => {
            if let Some(i) = st.buf.iter().position(|x| x.id == m.id) {
                st.buf.remove(i);
            }
            outs.push(txt(format!("\x1b[32m✓ đã xóa tin [{}]\x1b[0m", idx)));
        }
        Err(e) => outs.push(txt(format!("! Xóa lỗi: {}", e))),
    }
}

fn cmd_id(st: &State, rest: &str, outs: &mut Vec<Out>) {
    let idx: usize = match rest.trim().parse() {
        Ok(n) => n,
        Err(_) => {
            outs.push(txt("! Dùng: /id <số tin>".into()));
            return;
        }
    };
    match get_msg(st, idx) {
        Some(m) => outs.push(txt(format!("[{}] id = {} — tác giả id = {}", idx, m.id, m.author_id))),
        None => outs.push(txt(format!("! Không có tin số {}", idx))),
    }
}

fn cmd_typing(st: &State, api: &Api, outs: &mut Vec<Out>) {
    let cid = match st.cur.as_ref() {
        Some(x) => x.0,
        None => {
            outs.push(txt("! Chưa vào kênh".into()));
            return;
        }
    };
    match api.typing(cid) {
        Ok(_) => outs.push(txt("\x1b[32m✓ đã báo đang gõ\x1b[0m".into())),
        Err(e) => outs.push(txt(format!("! {}", e))),
    }
}

fn cmd_guilds(st: &mut State, api: &Api, outs: &mut Vec<Out>) {
    if st.demo {
        for (i, (_, nm)) in st.guilds.iter().enumerate() {
            outs.push(txt(format!(" [{}] {}", i + 1, nm)));
        }
        return;
    }
    match api.guilds() {
        Ok(v) => {
            let arr = v.as_array().cloned().unwrap_or_default();
            st.guilds = arr
                .iter()
                .filter_map(|g| {
                    let id = g
                        .get("id")
                        .and_then(|x| x.as_str())
                        .and_then(|s| s.parse::<u64>().ok())?;
                    let nm = g.get("name").and_then(|x| x.as_str()).unwrap_or("?").to_string();
                    Some((id, nm))
                })
                .collect();
            if st.guilds.is_empty() {
                outs.push(txt("(không có server nào)".into()));
            }
            for (i, (_, nm)) in st.guilds.iter().enumerate() {
                outs.push(txt(format!(" [{}] {}", i + 1, nm)));
            }
            outs.push(txt("\x1b[90m(danh sách đã hiện ở cột trái — Tab để chọn)\x1b[0m".into()));
        }
        Err(e) => outs.push(txt(format!("! {}", e))),
    }
}

/// Nạp kênh của server thứ `gi` vào st.chans (dùng cho cả lệnh và TUI Enter)
pub fn load_channels_idx(st: &mut State, api: &Api, gi: usize) -> Vec<Out> {
    let mut outs: Vec<Out> = vec![];
    if st.demo {
        if gi == 0 || gi > st.guilds.len() {
            outs.push(txt("! Số server không hợp lệ".into()));
        } else {
            let nm = st.guilds[gi - 1].1.clone();
            st.dm_mode = false;
            outs.push(txt(format!("\x1b[32m✓\x1b[0m (demo) chọn server {} — chọn kênh ở cột KÊNH", nm)));
        }
        return outs;
    }
    if st.guilds.is_empty() {
        cmd_guilds(st, api, &mut outs);
        if st.guilds.is_empty() {
            return outs;
        }
    }
    if gi == 0 || gi > st.guilds.len() {
        outs.push(txt("! Số server không hợp lệ".into()));
        return outs;
    }
    let (gid, gname) = st.guilds[gi - 1].clone();
    match api.guild_channels(gid) {
        Ok(v) => {
            let mut out: Vec<(u64, String)> = vec![];
            if let Some(arr) = v.as_array() {
                for c in arr {
                    let t = c.get("type").and_then(|x| x.as_i64()).unwrap_or(-1);
                    if t != 0 && t != 5 {
                        continue; // chỉ kênh text + thông báo
                    }
                    let id = match c
                        .get("id")
                        .and_then(|x| x.as_str())
                        .and_then(|s| s.parse::<u64>().ok())
                    {
                        Some(i) => i,
                        None => continue,
                    };
                    let nm = c.get("name").and_then(|x| x.as_str()).unwrap_or("?").to_string();
                    out.push((id, nm));
                }
            }
            st.chans = out;
            st.dm_mode = false;
            outs.push(txt(format!(
                "\x1b[32m✓\x1b[0m Server {} — {} kênh (xem cột KÊNH, Tab → chọn → Enter)",
                gname,
                st.chans.len()
            )));
        }
        Err(e) => outs.push(txt(format!("! {}", e))),
    }
    outs
}

fn cmd_channels_cmd(st: &mut State, api: &Api, rest: &str, outs: &mut Vec<Out>) {
    if st.guilds.is_empty() {
        cmd_guilds(st, api, outs);
        if st.guilds.is_empty() {
            return;
        }
    }
    let gi = if rest.is_empty() {
        if st.guilds.len() == 1 {
            1
        } else {
            outs.push(txt("! Có nhiều server — dùng: /channels <số server> (xem /guilds)".into()));
            return;
        }
    } else {
        match rest.parse::<usize>() {
            Ok(n) if n >= 1 && n <= st.guilds.len() => n,
            _ => {
                outs.push(txt("! Số server không hợp lệ".into()));
                return;
            }
        }
    };
    let sub = load_channels_idx(st, api, gi);
    outs.extend(sub);
    if !st.chans.is_empty() {
        for (i, (_, nm)) in st.chans.iter().enumerate() {
            outs.push(txt(format!(" [{}] #{}", i + 1, nm)));
        }
    }
}

fn cmd_dms(st: &mut State, api: &Api, outs: &mut Vec<Out>) {
    if st.demo {
        st.dm_mode = true;
        for (i, (_, nm)) in st.dms.iter().enumerate() {
            outs.push(txt(format!(" [d{}] @{}", i + 1, nm)));
        }
        return;
    }
    match api.dm_channels() {
        Ok(v) => {
            let mut out: Vec<(u64, String)> = vec![];
            if let Some(arr) = v.as_array() {
                for c in arr {
                    let t = c.get("type").and_then(|x| x.as_i64()).unwrap_or(-1);
                    if t != 1 && t != 3 {
                        continue;
                    }
                    let id = match c
                        .get("id")
                        .and_then(|x| x.as_str())
                        .and_then(|s| s.parse::<u64>().ok())
                    {
                        Some(i) => i,
                        None => continue,
                    };
                    let names: Vec<String> = c
                        .get("recipients")
                        .and_then(|x| x.as_array())
                        .map(|a| a.iter().map(display_name).collect())
                        .unwrap_or_default();
                    let nm = if names.is_empty() { "DM".to_string() } else { names.join(", ") };
                    out.push((id, nm));
                }
            }
            st.dms = out;
            st.dm_mode = true;
            for (i, (_, nm)) in st.dms.iter().enumerate() {
                outs.push(txt(format!(" [d{}] @{}", i + 1, nm)));
            }
            outs.push(txt("\x1b[90m(đã hiện ở cột KÊNH với dấu @ — Tab để chọn)\x1b[0m".into()));
        }
        Err(e) => outs.push(txt(format!("! {}", e))),
    }
}

fn cmd_go(st: &mut State, api: &Api, rest: &str, outs: &mut Vec<Out>) {
    let rest = rest.trim();
    let cid = if let Some(r) = rest.strip_prefix('d') {
        match r.trim().parse::<usize>() {
            Ok(n) if n >= 1 && n <= st.dms.len() => st.dms[n - 1].0,
            _ => {
                outs.push(txt("! Gõ /dms trước rồi /go d<số>".into()));
                return;
            }
        }
    } else if rest.len() >= 15 {
        match rest.parse::<u64>() {
            Ok(v) => v, // chuỗi ~17 số = ID kênh thô
            Err(_) => {
                outs.push(txt("! ID kênh không hợp lệ".into()));
                return;
            }
        }
    } else {
        match rest.parse::<usize>() {
            Ok(n) if n >= 1 && n <= st.chans.len() => st.chans[n - 1].0,
            _ => {
                outs.push(txt("! Dùng: /go <số kênh>  (hoặc /dms rồi /go d<số>)".into()));
                return;
            }
        }
    };
    match open_channel(st, api, cid) {
        Ok(lines) => {
            for l in lines {
                outs.push(txt(l));
            }
            save_config(None, Some(cid));
        }
        Err(e) => outs.push(txt(format!("! {}", e))),
    }
}

/// Mở kênh: lấy thông tin + 20 tin mới nhất vào buf. Trả các dòng để in.
pub fn open_channel(st: &mut State, api: &Api, cid: u64) -> Result<Vec<String>, String> {
    let mut lines: Vec<String> = vec![];
    if st.demo {
        demo_switch(st, cid);
        lines.push(format!("\x1b[32m✓\x1b[0m (demo) đã vào {}", st.cur.as_ref().map(|x| x.1.clone()).unwrap_or_default()));
        return Ok(lines);
    }
    let info = api
        .channel(cid)
        .map_err(|e| format!("không mở được kênh {}: {}", cid, e))?;
    let (name, is_dm) = match info.get("type").and_then(|x| x.as_i64()) {
        Some(1) | Some(3) => {
            let names: Vec<String> = info
                .get("recipients")
                .and_then(|x| x.as_array())
                .map(|a| a.iter().map(display_name).collect())
                .unwrap_or_default();
            (
                if names.is_empty() { "DM".to_string() } else { format!("@{}", names.join(", ")) },
                true,
            )
        }
        _ => (info.get("name").and_then(|x| x.as_str()).unwrap_or("#kênh").to_string(), false),
    };
    let msgs = api.messages(cid, None, 20)?;
    let mut ms: Vec<DiscordMsg> = msgs
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .filter_map(parse_msg)
        .collect();
    ms.reverse();
    st.buf.clear();
    for m in ms {
        st.buf.push_back(m);
    }
    st.cur = Some((cid, name.clone()));
    st.dm_mode = is_dm;
    lines.push(format!("\x1b[32m✓\x1b[0m Đã vào {} — {} tin mới nhất", name, st.buf.len()));
    let n = st.buf.len();
    for (i, m) in st.buf.iter().enumerate() {
        lines.push(render(n - i, m, st.tz));
    }
    Ok(lines)
}

fn demo_switch(st: &mut State, cid: u64) {
    let list: Vec<(u64, String)> = st
        .chans
        .iter()
        .chain(st.dms.iter())
        .cloned()
        .collect();
    if let Some((_, nm)) = list.iter().find(|(id, _)| *id == cid) {
        st.cur = Some((cid, nm.clone()));
        st.dm_mode = st.dms.iter().any(|(id, _)| *id == cid);
    }
}

fn cmd_more(st: &mut State, api: &Api, outs: &mut Vec<Out>) {
    if st.demo {
        outs.push(txt("(demo) không có tin cũ hơn".into()));
        return;
    }
    let cid = match st.cur.as_ref() {
        Some(x) => x.0,
        None => {
            outs.push(txt("! Chưa vào kênh nào — Tab chọn server → kênh, hoặc /channels rồi /go".into()));
            return;
        }
    };
    let oldest = st.buf.front().map(|m| m.id);
    match api.messages(cid, oldest, 20) {
        Ok(v) => {
            let mut older: Vec<DiscordMsg> = v
                .as_array()
                .cloned()
                .unwrap_or_default()
                .iter()
                .filter_map(parse_msg)
                .collect();
            older.reverse();
            let added = older.len();
            if added == 0 {
                outs.push(txt("(hết tin cũ hơn nữa)".into()));
                return;
            }
            for m in older {
                st.buf.push_front(m);
            }
            outs.push(txt(format!("✓ Nạp thêm {} tin cũ — cuộn ↑ để xem", added)));
        }
        Err(e) => outs.push(txt(format!("! {}", e))),
    }
}

fn cmd_history(st: &mut State, api: &Api, outs: &mut Vec<Out>) {
    if st.demo {
        outs.push(txt("(demo) đã có sẵn lịch sử giả".into()));
        return;
    }
    let cid = match st.cur.as_ref() {
        Some(x) => x.0,
        None => {
            outs.push(txt("! Chưa vào kênh nào".into()));
            return;
        }
    };
    match api.messages(cid, None, 20) {
        Ok(v) => {
            let mut ms: Vec<DiscordMsg> = v
                .as_array()
                .cloned()
                .unwrap_or_default()
                .iter()
                .filter_map(parse_msg)
                .collect();
            ms.reverse();
            st.buf.clear();
            for m in ms {
                st.buf.push_back(m);
            }
            outs.push(txt(format!("✓ Nạp lại {} tin mới nhất", st.buf.len())));
        }
        Err(e) => outs.push(txt(format!("! {}", e))),
    }
}

// ================= EVENT TỪ GATEWAY =================

pub fn on_new(st: &mut State, cid: u64, m: DiscordMsg) -> (Vec<String>, String) {
    let cur = st.cur.as_ref().map(|x| x.0);
    if cur == Some(cid) {
        // Nếu vừa tự gửi (đã echo cục bộ) thì khỏi nạp lại
        if st.buf.iter().rev().take(10).any(|x| x.id == m.id) {
            return (vec![], String::new());
        }
        st.buf.push_back(m.clone());
        while st.buf.len() > CAP {
            st.buf.pop_front();
        }
        let idx = st.buf.len();
        (vec![render(idx, &m, st.tz)], format!("→ tin mới từ {}", m.author))
    } else {
        let preview: String = m.content.chars().take(50).collect();
        (vec![], format!("→ {} (kênh khác): {}", m.author, preview))
    }
}

pub fn on_edited(st: &mut State, cid: u64, mid: u64, content: &str) -> (Vec<String>, String) {
    let cur = st.cur.as_ref().map(|x| x.0);
    if cur != Some(cid) {
        return (vec![], String::new());
    }
    let mut hit: Option<usize> = None;
    for (i, m) in st.buf.iter().enumerate() {
        if m.id == mid {
            hit = Some(i);
            break;
        }
    }
    if let Some(i) = hit {
        if st.buf[i].content == content {
            return (vec![], String::new()); // đã cập nhật khi /e
        }
        let n = st.buf.len();
        st.buf[i].content = content.to_string();
        st.buf[i].edited = true;
        (
            vec![format!("\x1b[90m~ [{}] {} đã sửa\x1b[0m: {}", n - i, st.buf[i].author, content)],
            format!("~ [{}] {} đã sửa tin nhắn", n - i, st.buf[i].author),
        )
    } else {
        (vec![], String::new())
    }
}

pub fn on_deleted(st: &mut State, cid: u64, mid: u64) -> (Vec<String>, String) {
    let cur = st.cur.as_ref().map(|x| x.0);
    if cur != Some(cid) {
        return (vec![], String::new());
    }
    if let Some(i) = st.buf.iter().position(|m| m.id == mid) {
        let n = st.buf.len();
        st.buf.remove(i);
        (vec![format!("\x1b[90m~ [{}] tin nhắn đã bị xóa\x1b[0m", n - i)], String::new())
    } else {
        (vec![], String::new())
    }
}

// ================= HIỂN THỊ CHUNG =================

fn render(idx: usize, m: &DiscordMsg, tz: i32) -> String {
    let mut s = format!(
        "\x1b[33m[{}]\x1b[0m \x1b[90m{}\x1b[0m \x1b[36m{}\x1b[0m",
        idx,
        fmt_time(&m.time, tz),
        m.author
    );
    if let Some((_, nm)) = &m.reply_to {
        s.push_str(&format!(" \x1b[90m↪ {}\x1b[0m", nm));
    }
    if m.edited {
        s.push_str(" \x1b[90m[đã sửa]\x1b[0m");
    }
    s.push_str(&format!(": {}", m.content));
    s
}

fn print_prompt(st: &State) {
    match &st.cur {
        Some((_, nm)) => print!("\x1b[35m{}\x1b[0m > ", nm),
        None => print!("(chưa vào kênh — /channels rồi /go) > "),
    }
}

fn banner() {
    println!("============================================================");
    println!("  BLACKHOLE v2.1 — Discord Terminal siêu nhẹ (Rust)");
    println!("  TUI discordo-style • xem ảnh trong terminal • /voice qua browser");
    println!("  đăng nhập email+password • TRÌNH DUYỆT ẨN tự bắt captcha");
    println!("  Gõ /help để xem lệnh — --demo để xem thử giao diện");
    println!("============================================================");
}

pub fn help_lines() -> Vec<String> {
    vec![
        "\x1b[1;36m── PHÍM TẮT (giao diện đầy đủ) ──\x1b[0m".into(),
        "  Tab              chuyển ô: nhập → SERVER → KÊNH".into(),
        "  ↑/↓ + Enter      chọn server / kênh (ở cột trái)".into(),
        "  ↑/↓ (ô nhập trống)  cuộn tin nhắn cũ/mới".into(),
        "  PageUp/PageDown  cuộn nhanh".into(),
        "  ↑/↓ (ô nhập có chữ)  gọi lại tin đã gửi".into(),
        "  Esc              đóng overlay / xóa ô nhập".into(),
        "  Ctrl+C           thoát (dọn terminal sạch sẽ)".into(),
        "".into(),
        "\x1b[1;36m── LỆNH ──\x1b[0m".into(),
        "  gõ text thường      gửi tin nhắn".into(),
        "  /guilds             liệt kê server".into(),
        "  /channels [số]      liệt kê kênh text của server".into(),
        "  /dms                liệt kê DM".into(),
        "  /go <số|id|dN>      vào kênh (vd /go 2, /go d1)".into(),
        "  /m <nội dung>       gửi tin nhắn".into(),
        "  /r <số> <nội dung>  REPLY tin số <số> (tin mới nhất = 1)".into(),
        "  /e <số> <nội dung>  SỬA tin nhắn của bạn".into(),
        "  /d <số>             XÓA tin nhắn".into(),
        "".into(),
        "\x1b[1;36m── ẢNH / FILE ĐÍNH KÈM ──\x1b[0m".into(),
        "  /img <số> [k]       XEM ảnh ngay trong terminal (k = ảnh thứ k)".into(),
        "  /save <số> [k]      tải file gốc về ~/.blackhole/downloads/".into(),
        "  /open <số> [k]      tải + mở bằng app xem file của máy".into(),
        "".into(),
        "\x1b[1;36m── VOICE · TRÌNH DUYỆT ẨN ──\x1b[0m".into(),
        "  /voice [id]         MƯỢN TRÌNH DUYỆT vào voice/stage (1 lệnh là vào)".into(),
        "  • voice chạy trên browser, terminal vẫn chat realtime song song".into(),
        "  • login gặp captcha: terminal tự mở TRANG XÁC MINH phong cách Discord".into(),
        "    — bạn tự bấm, kết quả TỰ CHẢY VỀ TERMINAL (không cần dán tay)".into(),
        "".into(),
        "  /more               nạp 20 tin cũ hơn".into(),
        "  /history            nạp lại 20 tin mới nhất".into(),
        "  /typing             báo đang gõ".into(),
        "  /id <số>            xem id đầy đủ của tin".into(),
        "  /me                 thông tin tài khoản".into(),
        "  /clear              dọn khung tin nhắn".into(),
        "  /logout             xóa token đã lưu khỏi máy".into(),
        "  /quit               thoát".into(),
        "".into(),
        "\x1b[90m--demo: xem giao diện không cần tài khoản • --plain: chế độ dòng lệnh cũ\x1b[0m".into(),
    ]
}

fn print_usage() {
    println!("BLACKHOLE v2.1 — Discord terminal siêu nhẹ (Rust)");
    println!("Chạy:  blackhole [tuỳ chọn]");
    println!("  (không gì cả)          menu đăng nhập: email+password hoặc dán token");
    println!("  --login                ép đăng nhập lại bằng email+password");
    println!("  --token <token>        vào thẳng bằng token (bot thì 'Bot xxx' hoặc thêm --bot)");
    println!("  --bot                  nhận diện là bot");
    println!("  --save                 lưu token vào ~/.blackhole/config (đừng dùng máy chung)");
    println!("  --demo                 xem giao diện với dữ liệu giả, không cần tài khoản");
    println!("  --plain                ép chế độ dòng lệnh (không giao diện full-screen)");
    println!("Lệnh trong app: /help  (mới: /voice mượn browser vào voice)");
}

// ================= TIỆN ÍCH =================

fn split2(s: &str) -> (&str, &str) {
    match s.find(' ') {
        Some(i) => (&s[..i], s[i + 1..].trim()),
        None => (s, ""),
    }
}

fn get_msg(st: &State, idx: usize) -> Option<DiscordMsg> {
    let n = st.buf.len();
    if idx == 0 || idx > n {
        return None;
    }
    st.buf.get(n - idx).cloned()
}

/// Múi giờ: env BLACKHOLE_TZ (số giờ lệch UTC), mặc định +7 (Việt Nam)
fn tz_offset() -> i32 {
    std::env::var("BLACKHOLE_TZ")
        .ok()
        .and_then(|s| s.trim().parse::<i32>().ok())
        .unwrap_or(7)
}

/// ISO "2025-11-13T02:45:09.xxx+00:00" -> "13/11 09:45" (theo múi giờ)
pub fn fmt_time(iso: &str, tz_off: i32) -> String {
    if iso.len() < 16 {
        return iso.chars().take(16).collect();
    }
    let num = |a: usize, z: usize| -> i64 { iso[a..z].parse::<i64>().unwrap_or(0) };
    let y = num(0, 4);
    let mo = num(5, 7);
    let d = num(8, 10);
    let h = num(11, 13);
    let mi = num(14, 16);
    let days = days_from_civil(y, mo, d);
    let mins = h * 60 + mi + (tz_off as i64) * 60;
    let shift = mins.div_euclid(1440);
    let mm = mins.rem_euclid(1440);
    let (_y2, mo2, d2) = civil_from_days(days + shift);
    format!("{:02}/{:02} {:02}:{:02}", d2, mo2, mm / 60, mm % 60)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn config_path() -> Option<PathBuf> {
    let base = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .ok()?;
    Some(PathBuf::from(base).join(".blackhole").join("config"))
}

fn load_config() -> (Option<String>, Option<u64>) {
    let p = match config_path() {
        Some(p) => p,
        None => return (None, None),
    };
    let s = match std::fs::read_to_string(p) {
        Ok(s) => s,
        Err(_) => return (None, None),
    };
    let mut tok = None;
    let mut chan = None;
    for line in s.lines() {
        if let Some(v) = line.strip_prefix("token=") {
            let v = v.trim();
            if !v.is_empty() {
                tok = Some(v.to_string());
            }
        }
        if let Some(v) = line.strip_prefix("channel=") {
            chan = v.trim().parse::<u64>().ok();
        }
    }
    (tok, chan)
}

/// Lưu config; token=None nghĩa là GIỮ token cũ như đã có (không tự lưu token mới)
fn save_config(token: Option<&str>, channel: Option<u64>) {
    let p = match config_path() {
        Some(p) => p,
        None => return,
    };
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let mut tok: Option<String> = token.map(|t| t.to_string());
    if tok.is_none() {
        let (old, _) = load_config();
        tok = old;
    }
    let mut s = String::new();
    if let Some(t) = tok {
        s.push_str("token=");
        s.push_str(&t);
        s.push('\n');
    }
    if let Some(c) = channel {
        s.push_str("channel=");
        s.push_str(&c.to_string());
        s.push('\n');
    }
    let _ = std::fs::write(&p, s);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(meta) = std::fs::metadata(&p) {
            let mut perm = meta.permissions();
            perm.set_mode(0o600); // chỉ mình mình đọc — token nhạy cảm
            let _ = std::fs::set_permissions(&p, perm);
        }
    }
}

/// Xóa token khỏi config (giữ channel)
fn clear_token_config() {
    let (_, chan) = load_config();
    let p = match config_path() {
        Some(p) => p,
        None => return,
    };
    let mut s = String::new();
    if let Some(c) = chan {
        s.push_str("channel=");
        s.push_str(&c.to_string());
        s.push('\n');
    }
    let _ = std::fs::write(&p, s);
}

// ================= DEMO (--demo: xem giao diện không cần tài khoản) =================

fn run_demo(plain: bool, smoke: bool) {
    let mut st = demo_state();
    let (tx, rx) = mpsc::channel::<Ev>();
    drop(tx); // demo không có event nền

    let use_tui = !plain && io::stdin().is_terminal() && io::stdout().is_terminal();
    if use_tui {
        let dur = if smoke { Some(Duration::from_millis(700)) } else { None };
        if let Err(e) = tui::run(&mut st, &Api::new("demo", false), &rx, dur) {
            println!("! giao diện lỗi: {} — dùng --plain", e);
        }
    } else {
        banner();
        println!("(demo — chế độ dòng lệnh: chỉ in lịch sử giả rồi thoát)");
        let n = st.buf.len();
        for (i, m) in st.buf.iter().enumerate() {
            println!("{}", render(n - i, m, st.tz));
        }
        if smoke {
            println!("SMOKE-OK");
        }
    }
}

fn demo_state() -> State {
    let mk = |id: u64, author: &str, content: &str, h: u32, mi: u32| DiscordMsg {
        id,
        author_id: 1000 + id,
        author: author.into(),
        content: content.into(),
        time: format!("2026-11-14T{:02}:{:02}:12.000+00:00", h, mi),
        edited: false,
        reply_to: None,
        atts: vec![],
    };
    let mut buf: VecDeque<DiscordMsg> = VecDeque::new();
    buf.push_back(mk(1, "Trang", "xin chào cả nhà, Blackhole v2 đây à :o", 10, 21));
    buf.push_back(mk(2, "Huy dev", "ừ lên đồ rồi đó, nhẹ vẫn nhẹ như cũ, binary chỉ vài MB", 10, 22));
    buf.push_back(mk(3, "Trang", "giao diện nay nhìn giống discordo thiệt luôn, đẹp ra xỉu", 10, 23));
    let mut m4 = mk(4, "hunghx", "gửi meme cho cả nhà xem nè", 10, 25);
    m4.atts.push(api::Att {
        name: "memehoa.png".into(),
        url: "".into(),
        w: 800,
        h: 600,
        size: 123_456,
        ctype: "image/png".into(),
    });
    m4.content.push_str(" [ảnh: memehoa.png 800x600]");
    buf.push_back(m4);
    buf.push_back(mk(5, "Huy dev", "bấm /img 2 để xem ảnh ngay trong terminal luôn nhé", 10, 26));
    buf.push_back(mk(6, "Trang", "đăng nhập email password luôn hả, khỏi dán token?", 10, 27));
    buf.push_back(mk(7, "hunghx", "ừ có captcha thì nó mở trình duyệt cho mình tự bấm", 10, 28));
    let mut m8 = mk(8, "Trang", "hay quá, sửa được tin nhắn luôn nè", 10, 30);
    m8.edited = true;
    buf.push_back(m8);
    let mut m9 = mk(9, "Huy dev", "", 10, 31);
    m9.reply_to = Some((4, "hunghx".into()));
    m9.content = "reply được luôn, mượt".into();
    buf.push_back(m9);
    buf.push_back(mk(10, "hunghx", "máy 1GB RAM vẫn chạy ngon, tin cậy độ nhẹ", 10, 33));

    State {
        me_id: 1000,
        me_name: "bạn".into(),
        guilds: vec![(1, "Blackhole Corp".into()), (2, "Gaming VN".into())],
        chans: vec![
            (11, "general".into()),
            (12, "dev".into()),
            (13, "memes".into()),
        ],
        dms: vec![(21, "Trang".into()), (22, "Huy dev".into())],
        cur: Some((11, "#general".into())),
        buf,
        tz: tz_offset(),
        demo: true,
        dm_mode: false,
    }
}

// ================= ANSI CHO WINDOWS CŨ =================

#[cfg(windows)]
fn enable_ansi() {
    use std::os::windows::raw::HANDLE;
    extern "system" {
        fn GetStdHandle(n: i32) -> HANDLE;
        fn GetConsoleMode(h: HANDLE, m: *mut u32) -> i32;
        fn SetConsoleMode(h: HANDLE, m: u32) -> i32;
    }
    unsafe {
        let h = GetStdHandle(-11);
        let mut mode: u32 = 0;
        if GetConsoleMode(h, &mut mode) != 0 {
            SetConsoleMode(h, mode | 0x0004); // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        }
    }
}

#[cfg(not(windows))]
fn enable_ansi() {}
