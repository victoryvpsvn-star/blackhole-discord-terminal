// ============================================================
//  tui.rs — GIAO DIỆN FULL-SCREEN KIỂU DISCORDO
//  Cột trái: server + kênh · Khung phải: tin nhắn · Ô nhập có viền
//  Status bar · Overlay (help/ảnh) · Cuộn lịch sử
//
//  Kỹ thuật: crossterm chỉ để raw-mode + đọc phím (nhẹ),
//  vẽ bằng ANSI tự viết — KHÔNG ratatui để binary giữ nhỏ.
//  Mỗi frame = 1 chuỗi buffer duy nhất, 1 lần write → không nhấp nháy.
// ============================================================

use crate::{fmt_time, handle_line, Act, Ev, Out, State};
use crate::api::Api;
use crossterm::event::{poll, read, Event, KeyCode, KeyEvent, KeyModifiers};
use crossterm::terminal;
use std::io::{self, Write};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

#[derive(PartialEq, Clone, Copy)]
enum Focus {
    Input,
    Guilds,
    Chans,
}

struct Overlay {
    title: String,
    lines: Vec<String>,
    scroll: usize,
}

/// Kích thước terminal (fallback 100x40)
pub fn term_size() -> (usize, usize) {
    match terminal::size() {
        Ok((c, r)) => (c as usize, r as usize),
        Err(_) => (100, 40),
    }
}

/// Vào TUI. Err = không bật được raw mode → caller chuyển line-mode.
/// Trả Ok khi người dùng thoát (đã khôi phục terminal sạch sẽ).
pub fn run(
    st: &mut State,
    api: &Api,
    rx: &Receiver<Ev>,
    auto_quit: Option<Duration>,
) -> Result<(), String> {
    terminal::enable_raw_mode().map_err(|e| format!("raw mode: {}", e))?;
    let mut so = io::stdout();
    if so
        .write_all(b"\x1b[?1049h\x1b[?25l\x1b[2J") // alternate screen + ẩn cursor
        .and_then(|_| so.flush())
        .is_err()
    {
        let _ = terminal::disable_raw_mode();
        return Err("stdout lỗi".into());
    }
    let res = loop_ui(st, api, rx, auto_quit, &mut so);
    // khôi phục terminal kể cả khi lỗi/panic-unwrap bên ngoài
    let _ = so.write_all(b"\x1b[?25h\x1b[?1049l\x1b[0m");
    let _ = so.flush();
    let _ = terminal::disable_raw_mode();
    res
}

fn loop_ui(
    st: &mut State,
    api: &Api,
    rx: &Receiver<Ev>,
    auto_quit: Option<Duration>,
    so: &mut io::Stdout,
) -> Result<(), String> {
    let mut input: Vec<char> = Vec::new();
    let mut ipos: usize = 0;
    let mut hist: Vec<String> = Vec::new();
    let mut hidx: usize = 0; // == hist.len() nghĩa là đang gõ dòng mới
    let mut scroll: usize = 0; // số dòng tin nhắn ẩn từ đáy
    let mut focus = Focus::Input;
    let mut sel_g: usize = 1;
    let mut sel_c: usize = 1;
    let mut notice = String::from("Tab: chọn server/kênh • /help: xem lệnh • --demo để xem thử không cần tài khoản");
    let mut overlay: Option<Overlay> = None;
    let mut dirty = true;
    let t0 = Instant::now();

    loop {
        if let Some(d) = auto_quit {
            if t0.elapsed() >= d {
                return Ok(());
            }
        }

        let mut activity = false;

        // ---- 1) sự kiện mạng / line-mode stdin ----
        while let Ok(ev) = rx.try_recv() {
            activity = true;
            match ev {
                Ev::Line(l) => {
                    let (outs, act) = handle_line(st, api, &l, true);
                    apply_outs(&mut overlay, &mut notice, outs);
                    if act == Act::Quit {
                        return Ok(());
                    }
                }
                Ev::New(cid, m) => {
                    let (_p, n) = crate::on_new(st, cid, m);
                    if !n.is_empty() {
                        notice = n;
                    }
                }
                Ev::Edited(cid, mid, c) => {
                    let (_p, n) = crate::on_edited(st, cid, mid, &c);
                    if !n.is_empty() {
                        notice = n;
                    }
                }
                Ev::Deleted(cid, mid) => {
                    let (_p, n) = crate::on_deleted(st, cid, mid);
                    if !n.is_empty() {
                        notice = n;
                    }
                }
                Ev::NetErr(e) => notice = format!("\u{26a0} {}", e),
            }
        }

        // ---- 2) bàn phím (dỏng hết hàng đợi, không ngủ nhầm) ----
        while poll(Duration::from_millis(0)).unwrap_or(false) {
            match read() {
                Ok(Event::Key(k)) => {
                    if k.kind == kind_is_release() {
                        continue;
                    }
                    if quit_or_key(
                        st,
                        api,
                        k,
                        &mut input,
                        &mut ipos,
                        &mut hist,
                        &mut hidx,
                        &mut scroll,
                        &mut focus,
                        &mut sel_g,
                        &mut sel_c,
                        &mut notice,
                        &mut overlay,
                    ) {
                        return Ok(());
                    }
                    activity = true;
                }
                Ok(Event::Resize(_, _)) => activity = true,
                Ok(Event::Paste(s)) => {
                    for c in s.chars() {
                        if c != '\n' && c != '\r' {
                            input.insert(ipos.min(input.len()), c);
                            ipos = ipos.min(input.len()) + 1;
                        }
                    }
                    activity = true;
                }
                Ok(_) => {}
                Err(_) => return Err("lỗi đọc bàn phím".into()),
            }
        }

        // ---- 3) vẽ ----
        if activity || dirty {
            draw(
                so,
                st,
                &input,
                ipos,
                &focus,
                sel_g,
                sel_c,
                scroll,
                &notice,
                &overlay,
            );
            dirty = false;
        } else {
            std::thread::sleep(Duration::from_millis(15));
        }
    }
}

// Windows gửi cả Press lẫn Release — bỏ Release để không gõ 2 lần
#[allow(non_snake_case)]
fn kind_is_release() -> crossterm::event::KeyEventKind {
    crossterm::event::KeyEventKind::Release
}

#[allow(clippy::too_many_arguments)]
fn quit_or_key(
    st: &mut State,
    api: &Api,
    k: KeyEvent,
    input: &mut Vec<char>,
    ipos: &mut usize,
    hist: &mut Vec<String>,
    hidx: &mut usize,
    scroll: &mut usize,
    focus: &mut Focus,
    sel_g: &mut usize,
    sel_c: &mut usize,
    notice: &mut String,
    overlay: &mut Option<Overlay>,
) -> bool {
    let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);

    // ---- overlay đang mở ----
    if let Some(ov) = overlay.as_mut() {
        match k.code {
            KeyCode::Up => ov.scroll = ov.scroll.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => ov.scroll += 1,
            KeyCode::PageUp => ov.scroll = ov.scroll.saturating_sub(10),
            KeyCode::PageDown => ov.scroll += 10,
            _ => *overlay = None, // phím bất kỳ = đóng
        }
        return false;
    }

    match *focus {
        // ================= Ô NHẬP =================
        Focus::Input => match (k.code, ctrl) {
            (KeyCode::Char('c'), true) => return true, // Ctrl+C thoát
            (KeyCode::Char(c), false) => {
                input.insert(*ipos, c);
                *ipos += 1;
            }
            (KeyCode::Backspace, _) => {
                if *ipos > 0 {
                    *ipos -= 1;
                    input.remove(*ipos);
                }
            }
            (KeyCode::Delete, _) => {
                if *ipos < input.len() {
                    input.remove(*ipos);
                }
            }
            (KeyCode::Left, _) => *ipos = ipos.saturating_sub(1),
            (KeyCode::Right, _) => {
                if *ipos < input.len() {
                    *ipos += 1;
                }
            }
            (KeyCode::Home, _) | (KeyCode::Char('a'), true) => *ipos = 0,
            (KeyCode::End, _) | (KeyCode::Char('e'), true) => *ipos = input.len(),
            (KeyCode::Char('u'), true) => {
                input.clear();
                *ipos = 0;
            }
            (KeyCode::Char('l'), true) => *notice = String::new(),
            (KeyCode::Enter, _) => {
                let line: String = input.iter().collect();
                if !line.trim().is_empty() {
                    hist.push(line.clone());
                    if hist.len() > 100 {
                        hist.remove(0);
                    }
                }
                input.clear();
                *ipos = 0;
                *hidx = hist.len();
                let (outs, act) = handle_line(st, api, &line, true);
                apply_outs(overlay, notice, outs);
                if act == Act::Quit {
                    return true;
                }
            }
            (KeyCode::Up, _) => {
                if input.is_empty() {
                    *scroll += 10;
                } else if *hidx > 0 {
                    *hidx -= 1;
                    *input = hist[*hidx].chars().collect();
                    *ipos = input.len();
                }
            }
            (KeyCode::Down, _) => {
                if input.is_empty() {
                    *scroll = scroll.saturating_sub(10);
                } else if *hidx < hist.len() {
                    *hidx += 1;
                    *input = if *hidx == hist.len() {
                        Vec::new()
                    } else {
                        hist[*hidx].chars().collect()
                    };
                    *ipos = input.len();
                }
            }
            (KeyCode::PageUp, _) => *scroll += 40,
            (KeyCode::PageDown, _) => *scroll = scroll.saturating_sub(40),
            (KeyCode::Tab, _) => *focus = Focus::Guilds,
            (KeyCode::Esc, _) => {
                if !input.is_empty() {
                    input.clear();
                    *ipos = 0;
                }
            }
            _ => {}
        },

        // ================= DANH SÁCH SERVER =================
        Focus::Guilds => match (k.code, ctrl) {
            (KeyCode::Char('c'), true) => return true,
            (KeyCode::Up, _) => {
                if *sel_g > 1 {
                    *sel_g -= 1;
                }
            }
            (KeyCode::Down, _) => {
                if *sel_g < st.guilds.len().max(1) {
                    *sel_g += 1;
                }
            }
            (KeyCode::Enter, _) => {
                let gi = *sel_g;
                let outs = crate::load_channels_idx(st, api, gi);
                let mut n = String::new();
                for o in outs {
                    if let Out::Text(t) = o {
                        n = t;
                    }
                }
                if !n.is_empty() {
                    *notice = n;
                }
                *sel_c = 1;
                *focus = Focus::Chans;
            }
            (KeyCode::Esc, _) => *focus = Focus::Input,
            (KeyCode::Tab, _) => *focus = Focus::Chans,
            _ => {}
        },

        // ================= DANH SÁCH KÊNH =================
        Focus::Chans => match (k.code, ctrl) {
            (KeyCode::Char('c'), true) => return true,
            (KeyCode::Up, _) => {
                if *sel_c > 1 {
                    *sel_c -= 1;
                }
            }
            (KeyCode::Down, _) => {
                let n = if st.dm_mode { st.dms.len() } else { st.chans.len() };
                if *sel_c < n.max(1) {
                    *sel_c += 1;
                }
            }
            (KeyCode::Enter, _) => {
                let list: Vec<(u64, String)> = if st.dm_mode {
                    st.dms.clone()
                } else {
                    st.chans.clone()
                };
                if *sel_c >= 1 && *sel_c <= list.len() {
                    let cid = list[*sel_c - 1].0;
                    match crate::open_channel(st, api, cid) {
                        Ok(lines) => {
                            *notice = lines
                                .first()
                                .cloned()
                                .unwrap_or_else(|| "\x1b[32m\u{2713} đã vào kênh\x1b[0m".into());
                            *scroll = 0;
                        }
                        Err(e) => *notice = format!("! {}", e),
                    }
                }
                *focus = Focus::Input;
            }
            (KeyCode::Esc, _) => *focus = Focus::Input,
            (KeyCode::Tab, _) => *focus = Focus::Input, // khép kín chu kỳ: Input→SERVER→KÊNH→Input
            _ => {}
        },
    }
    false
}

fn apply_outs(overlay: &mut Option<Overlay>, notice: &mut String, outs: Vec<Out>) {
    for o in outs {
        match o {
            Out::Text(t) => *notice = t, // giữ thông báo cuối
            Out::Overlay { title, lines } => {
                *overlay = Some(Overlay { title, lines, scroll: 0 });
            }
        }
    }
}

// ============================================================
//                         VẼ MÀN HÌNH
// ============================================================

#[allow(clippy::too_many_arguments)]
fn draw(
    so: &mut io::Stdout,
    st: &State,
    input: &[char],
    ipos: usize,
    focus: &Focus,
    sel_g: usize,
    sel_c: usize,
    scroll: usize,
    notice: &str,
    overlay: &Option<Overlay>,
) {
    let (cols, rows) = term_size();
    let cols = cols.max(24);
    let rows = rows.max(12);

    let mut b = String::with_capacity(48 * 1024);
    b.push_str("\x1b[?25l"); // ẩn cursor trong lúc vẽ

    // header row 1
    let chan_nm = match &st.cur {
        Some((_, n)) => n.clone(),
        None => "chưa vào kênh".into(),
    };
    let hdr = format!(" BLACKHOLE v2.0 \u{2022} {} \u{2022} {}", st.me_name, chan_nm);
    b.push_str(&format!("\x1b[1;1H\x1b[K\x1b[7m{}\x1b[0m", pad(&hdr, cols)));

    let body_top = 2usize;
    let body_bot = rows.saturating_sub(4); // input 3 dòng + status 1
    let sw = if cols >= 60 {
        22
    } else if cols >= 44 {
        16
    } else {
        0
    };

    if sw > 0 {
        draw_sidebar(&mut b, st, sw, body_top, body_bot, focus, sel_g, sel_c);
    }
    draw_msgs(&mut b, st, sw, cols, body_top, body_bot, scroll);

    // ---- ô nhập (3 dòng) ----
    let r1 = body_bot + 1;
    let r2 = body_bot + 2;
    let r3 = body_bot + 3;
    let bc = if *focus == Focus::Input {
        "\x1b[32m" // viền xanh khi focus
    } else {
        "\x1b[90m"
    };
    let title = if *focus == Focus::Input {
        " nhập tin nhắn \u{2022} /help xem lệnh "
    } else {
        " Tab: sang danh sách server "
    };
    b.push_str(&format!(
        "\x1b[{};1H\x1b[K{}{}\x1b[0m",
        r1,
        bc,
        edge_top(cols, title)
    ));
    // dòng nội dung
    let inner = cols.saturating_sub(2); // giữa 2 viền
    let win = inner.saturating_sub(4);
    let start = ipos.saturating_sub(win);
    let mut shown = String::new();
    for i in start..input.len() {
        shown.push(input[i]);
    }
    let shown = if !input.is_empty() && input[0] == '/' {
        format!("\x1b[33m{}\x1b[0m", shown) // lệnh /... màu vàng
    } else {
        shown
    };
    b.push_str(&format!(
        "\x1b[{};1H\x1b[K{}│ \x1b[32m>\x1b[0m {}{}│\x1b[0m",
        r2,
        bc,
        pad(&shown, inner.saturating_sub(2)),
        bc
    ));
    b.push_str(&format!("\x1b[{};1H\x1b[K{}{}\x1b[0m", r3, bc, edge_bot(cols)));

    // ---- status bar ----
    let left = format!(" {} \u{2022} \u{25cf} online \u{2022} {}", chan_nm, st.me_name);
    let notice_trunc = trunc(notice, cols.saturating_sub(4));
    let lw = cols.saturating_sub(disp_w(&notice_trunc).saturating_sub(1));
    b.push_str(&format!(
        "\x1b[{};1H\x1b[K\x1b[2;37m{}\x1b[0m",
        rows,
        pad(&left, lw)
    ));
    // notice màu vàng bên phải status
    let ln = disp_w(&notice_trunc);
    if ln > 1 {
        b.push_str(&format!(
            "\x1b[{};{}H\x1b[33m{}\x1b[0m",
            rows,
            cols - ln + 1,
            notice_trunc
        ));
    }

    // ---- overlay (vẽ sau, đè lên trên) ----
    if let Some(ov) = overlay {
        draw_overlay(&mut b, cols, rows, ov);
        // cursor ẩn khi overlay mở
        b.push_str("\x1b[?25l");
    } else if *focus == Focus::Input {
        let cursor_col = 5 + (ipos - start); // │ > _ = 4 ký tự trước nội dung
        b.push_str(&format!("\x1b[{};{}H\x1b[?25h", r2, cursor_col));
    } else {
        b.push_str("\x1b[?25l");
    }

    let _ = so.write_all(b.as_bytes());
    let _ = so.flush();
}

// ---------- sidebar ----------
fn draw_sidebar(
    b: &mut String,
    st: &State,
    sw: usize,
    top: usize,
    bot: usize,
    focus: &Focus,
    sel_g: usize,
    sel_c: usize,
) {
    let inner = sw - 2;
    let h = bot - top + 1;

    let mut lines: Vec<String> = Vec::new();
    let mut sel_line: Option<usize> = None;

    lines.push("\x1b[1;35mSERVER\x1b[0m".into());
    if st.guilds.is_empty() {
        lines.push("\x1b[90m(chưa nạp —\x1b[0m".into());
        lines.push("\x1b[90m /guilds hoặc Enter)\x1b[0m".into());
    } else {
        for (i, (_, nm)) in st.guilds.iter().enumerate() {
            let g = i + 1;
            let sel = *focus == Focus::Guilds && sel_g == g;
            if sel {
                sel_line = Some(lines.len());
            }
            let mark = if sel { "\u{25b8} " } else { "  " };
            lines.push(if sel {
                format!("\x1b[36m{}{}\x1b[0m", mark, nm)
            } else {
                format!("\x1b[0m{}{}\x1b[0m", mark, nm)
            });
        }
    }
    lines.push("".into());
    lines.push("\x1b[1;35mKÊNH\x1b[0m".into());
    let list = if st.dm_mode { &st.dms } else { &st.chans };
    if list.is_empty() {
        lines.push("\x1b[90m(chưa nạp — Enter ở\x1b[0m".into());
        lines.push("\x1b[90m SERVER, hoặc /dms)\x1b[0m".into());
    } else {
        let pre = if st.dm_mode { "@" } else { "#" };
        for (i, (id, nm)) in list.iter().enumerate() {
            let c = i + 1;
            let sel = *focus == Focus::Chans && sel_c == c;
            if sel {
                sel_line = Some(lines.len());
            }
            let cur = st.cur.as_ref().map(|x| x.0) == Some(*id);
            let mark = if cur {
                "\u{25cf} "
            } else if sel {
                "\u{25b8} "
            } else {
                "  "
            };
            let body = format!("{}{}{}", mark, pre, nm);
            lines.push(if sel {
                format!("\x1b[36;1m{}\x1b[0m", body)
            } else if cur {
                format!("\x1b[32m{}\x1b[0m", body)
            } else {
                format!("\x1b[0m{}\x1b[0m", body)
            });
        }
    }

    // tự cuộn theo selection
    let start = match sel_line {
        Some(s) if s >= h => s + 1 - h,
        _ => 0,
    };
    for r in top..=bot {
        let li = start + (r - top);
        let raw = if li < lines.len() { &lines[li] } else { "" };
        b.push_str(&format!("\x1b[{};1H\x1b[K│{}│", r, pad(raw, inner)));
    }
}

// ---------- khung tin nhắn ----------
fn draw_msgs(
    b: &mut String,
    st: &State,
    sw: usize,
    cols: usize,
    top: usize,
    bot: usize,
    scroll: usize,
) {
    let content_col = if sw > 0 { sw + 2 } else { 1 };
    let pw = cols - content_col + 1;
    let h = bot - top + 1;

    let mut lines: Vec<String> = Vec::new();
    if st.cur.is_none() {
        lines.push("\x1b[1;33mChưa vào kênh nào — 2 cách:\x1b[0m".into());
        lines.push("  Tab → SERVER → Enter → KÊNH → Enter".into());
        lines.push("  hoặc gõ: /channels → /go 1  ·  /dms → /go d1".into());
        lines.push("".into());
        lines.push("\x1b[90mGõ chữ thường = gửi tin nhắn ngay vào kênh đang mở.\x1b[0m".into());
    } else {
        for (i, m) in st.buf.iter().enumerate() {
            let idx = st.buf.len() - i;
            let mut hdr = format!(
                "\x1b[90m[{}]\x1b[0m \x1b[90m{}\x1b[0m \x1b[1;36m{}\x1b[0m",
                idx,
                fmt_time(&m.time, st.tz),
                m.author
            );
            if let Some((_, nm)) = &m.reply_to {
                hdr.push_str(&format!(" \x1b[90m\u{21aa} {}\x1b[0m", nm));
            }
            if m.edited {
                hdr.push_str(" \x1b[90m[đã sửa]\x1b[0m");
            }
            lines.push(hdr);
            for wl in wrap(&m.content, pw.saturating_sub(4)) {
                lines.push(format!("  {}", wl));
            }
            lines.push(String::new());
        }
        if st.buf.is_empty() {
            lines.push("\x1b[90m(kênh trống — gõ gì đó cho vui)\x1b[0m".into());
        }
    }

    let maxscroll = lines.len().saturating_sub(h);
    let s = scroll.min(maxscroll);
    let end = lines.len() - s;
    let start = end.saturating_sub(h);

    for r in top..=bot {
        let li = start + (r - top);
        let content = if li < end { lines[li].clone() } else { String::new() };
        b.push_str(&format!("\x1b[{};{}H\x1b[K{}", r, content_col, content));
    }
    if sw > 0 {
        for r in top..=bot {
            b.push_str(&format!("\x1b[{};{}H│", r, sw + 1));
        }
    }
    if s > 0 {
        b.push_str(&format!(
            "\x1b[{};{}H\x1b[90m\u{2191} lịch sử ({} dòng — ↓ để về mới nhất)\x1b[0m",
            top, content_col, s
        ));
    }
}

// ---------- overlay ----------
fn draw_overlay(b: &mut String, cols: usize, rows: usize, ov: &Overlay) {
    let inner_max = cols.saturating_sub(6);
    let mut width = ov.title.len() + 8;
    for l in &ov.lines {
        width = width.max(disp_w(l).min(inner_max) + 4);
    }
    let width = width.min(inner_max + 4).max(12);
    let h_body = rows.saturating_sub(6);
    let top = 2;
    let left = (cols.saturating_sub(width)) / 2 + 1;
    let inner = width - 4;

    b.push_str(&format!(
        "\x1b[{};{}H\x1b[36m┌─ \x1b[1m{}\x1b[0m\x1b[36m{}┐\x1b[0m",
        top,
        left,
        ov.title,
        "─".repeat(width.saturating_sub(ov.title.chars().count() + 6))
    ));

    let start = ov.scroll.min(ov.lines.len().saturating_sub(1));
    for i in 0..h_body {
        let li = start + i;
        let content = if li < ov.lines.len() {
            trunc(&ov.lines[li], inner)
        } else {
            String::new()
        };
        b.push_str(&format!(
            "\x1b[{};{}H\x1b[36m│\x1b[0m {} \x1b[36m│\x1b[0m",
            top + 1 + i,
            left,
            pad(&content, inner)
        ));
    }
    let foot = "\u{2191}\u{2193} cuộn \u{2022} Esc/phím bất kỳ: đóng";
    b.push_str(&format!(
        "\x1b[{};{}H\x1b[36m└─ {}\u{2500}┘\x1b[0m",
        top + 1 + h_body,
        left,
        pad(&foot, inner.saturating_sub(3))
    ));
}

// ============================================================
//                 TIỆN ÍCH VĂN BẢN / ANSI
// ============================================================

/// Độ rộng hiển thị (bỏ qua escape ANSI)
pub fn disp_w(s: &str) -> usize {
    let mut n = 0usize;
    let mut in_esc = false;
    for c in s.chars() {
        if in_esc {
            if c == 'm' {
                in_esc = false;
            }
            continue;
        }
        if c == '\x1b' {
            in_esc = true;
            continue;
        }
        n += 1;
    }
    n
}

/// Cắt theo độ rộng hiển thị, KHÔNG cắt giữa chuỗi escape
pub fn trunc(s: &str, w: usize) -> String {
    if disp_w(s) <= w {
        return s.to_string();
    }
    let mut out = String::new();
    let mut n = 0usize;
    let mut in_esc = false;
    for c in s.chars() {
        if in_esc {
            out.push(c);
            if c == 'm' {
                in_esc = false;
            }
            continue;
        }
        if c == '\x1b' {
            in_esc = true;
            out.push(c);
            continue;
        }
        if n >= w {
            continue;
        }
        out.push(c);
        n += 1;
    }
    out.push_str("\x1b[0m");
    out
}

/// Đệm phải tới đúng độ rộng (cắt nếu dài hơn)
pub fn pad(s: &str, w: usize) -> String {
    let d = disp_w(s);
    if d >= w {
        return trunc(s, w);
    }
    format!("{}{}", s, " ".repeat(w - d))
}

/// Wrap 1 dòng (có thể chứa ANSI) thành nhiều dòng độ rộng w.
/// Màu đang mở sẽ được "mang" sang dòng kế tiếp.
pub fn wrap(s: &str, w: usize) -> Vec<String> {
    if w == 0 {
        return vec![s.to_string()];
    }
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut cur_w = 0usize;
    let mut active = String::new(); // các mã màu đang mở
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        if c == '\x1b' {
            let mut seq = String::from(c);
            while let Some(&c2) = it.peek() {
                seq.push(c2);
                it.next();
                if c2 == 'm' {
                    break;
                }
            }
            cur.push_str(&seq);
            if seq.ends_with('m') {
                if seq == "\x1b[0m" || seq == "\x1b[m" {
                    active.clear();
                } else {
                    active.push_str(&seq);
                }
            }
            continue;
        }
        cur_w += 1;
        cur.push(c);
        if cur_w == w {
            out.push(std::mem::take(&mut cur));
            cur_w = 0;
            cur.push_str(&active);
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    if out.is_empty() {
        out.push(String::new());
    }
    out
}

// viền khung nhập
fn edge_top(w: usize, title: &str) -> String {
    let dashes = w.saturating_sub(title.chars().count() + 4);
    format!("┌──{}{}┐", title, "─".repeat(dashes))
}
fn edge_bot(w: usize) -> String {
    format!("└{}┘", "─".repeat(w.saturating_sub(2)))
}
