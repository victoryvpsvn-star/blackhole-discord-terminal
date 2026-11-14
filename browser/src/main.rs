// ============================================================
//  BLACKHOLE Browser v1.0 — gaming browser SIÊU NHẸ
//
//  Triết lý "đấu với browser gaming thế hệ 5" (Opera GX & co):
//   * KHÔNG bundle engine (browser gaming kiểu Opera GX: cài 300-500MB,
//     RAM bật máy ~500MB+). BLACKHOLE dùng WEBVIEW HỆ THỐNG có sẵn:
//     Windows = WebView2 (Edge runtime), Linux = WebKitGTK.
//     -> binary chỉ vài MB, RAM thấp vì engine nằm sẵn trong OS.
//   * KHÔNG service nền, KHÔNG telemetry, KHÔNG sidebar casino.
//     Mọi MB RAM đều dành cho trang web đang mở — tối ưu cho game thủ.
//   * UI = 1 webview thanh tab + 1 webview nội dung, IPC siêu nhẹ.
//
//  Kiến trúc chống-deadlock: webview KHÔNG nằm trong Mutex chung.
//  IPC (từ UI) chỉ đẩy JSON vào inbox: Arc<Mutex<Vec<String>>>;
//  event loop rút mess xử lý — không lock nào giữ qua lần gọi webview.
// ============================================================

mod ui;

use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tao::dpi::{PhysicalPosition, PhysicalSize, Position, Size};
use tao::event::{ElementState, Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoop};
use tao::keyboard::{KeyCode, ModifiersState};
use tao::window::{Fullscreen, WindowBuilder};
use wry::{Rect, WebView, WebViewBuilder};

const TABBAR_H: i32 = 52;
const MAX_TABS: usize = 24;

#[derive(Clone)]
struct Tab {
    url: Option<String>, // None = Speed Dial
    title: String,
}

impl Tab {
    fn dial() -> Self {
        Tab { url: None, title: String::new() }
    }
    fn web(url: &str) -> Self {
        Tab { url: Some(url.to_string()), title: String::new() }
    }
    fn label(&self) -> String {
        if self.title.is_empty() {
            match &self.url {
                Some(u) => u
                    .split("//")
                    .nth(1)
                    .unwrap_or(u)
                    .split('/')
                    .next()
                    .unwrap_or(u)
                    .to_string(),
                None => "Speed Dial".into(),
            }
        } else {
            self.title.clone()
        }
    }
}

struct State {
    tabs: Vec<Tab>,
    active: usize,
    full: bool,
}

thread_local! {
    static CTRL_CACHE: std::cell::RefCell<ModifiersState> =
        std::cell::RefCell::new(ModifiersState::empty());
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("BLACKHOLE Browser 1.0.0 — gaming browser siêu nhẹ (webview hệ thống)");
        println!("Chạy:  blackhole-browser [tuỳ chọn]");
        println!("  (không gì cả)   mở Speed Dial");
        println!("  --url <link>    mở thẳng 1 trang");
        println!("  --help          xem hướng dẫn này");
        println!("Phím tắt: Ctrl+T tab mới • Ctrl+W đóng • Ctrl+Tab chuyển • Ctrl+1..8 nhảy");
        println!("          Ctrl+L focus URL • Ctrl+R/F5 reload • Ctrl+H speed dial • F11 fullscreen");
        return;
    }
    let start_url = args
        .iter()
        .position(|a| a == "--url")
        .and_then(|i| args.get(i + 1))
        .cloned();

    let event_loop = EventLoop::new();
    let window = Arc::new(
        WindowBuilder::new()
            .with_title("BLACKHOLE Browser — gaming edition")
            .with_inner_size(tao::dpi::LogicalSize::new(1280.0, 820.0))
            .build(&event_loop)
            .expect("không tạo được cửa sổ"),
    );

    let state = Arc::new(Mutex::new(State {
        tabs: vec![match &start_url {
            Some(u) => Tab::web(u),
            None => Tab::dial(),
        }],
        active: 0,
        full: false,
    }));
    let inbox: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));

    // ---- thanh tab (child webview trên cùng) — chỉ ĐẨY mess vào inbox ----
    let tabbar = {
        let inbox2 = inbox.clone();
        WebViewBuilder::new()
            .with_html(ui::TABBAR_HTML)
            .with_ipc_handler(move |req| {
                if let Ok(v) = serde_json::from_str::<Value>(req.body()) {
                    if let Ok(mut q) = inbox2.lock() {
                        q.push(v.to_string());
                    }
                }
            })
            .build_as_child(&window)
            .expect("không tạo được thanh tab")
    };
    render_tabbar(&tabbar, &state);

    // ---- webview nội dung cho tab đầu ----
    let mut content: Option<WebView> =
        Some(build_content(&window, inbox.clone(), &state));
    layout(&tabbar, content.as_ref(), window.inner_size());

    let win2 = window.clone();
    let state2 = state.clone();
    let inbox2 = inbox.clone();

    event_loop.run(move |event, _, control_flow| {
        // Đợi đã có việc thì Poll, rảnh thì Wait — tiết kiệm CPU tối đa
        match event {
            Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => {
                *control_flow = ControlFlow::Exit;
            }
            Event::WindowEvent { event: WindowEvent::Resized(size), .. } => {
                layout(&tabbar, content.as_ref(), size);
                *control_flow = ControlFlow::Wait;
            }
            Event::WindowEvent {
                event: WindowEvent::ModifiersChanged(m), ..
            } => {
                CTRL_CACHE.with(|c| *c.borrow_mut() = m);
            }
            Event::WindowEvent {
                event:
                    WindowEvent::KeyboardInput {
                        event: key_event, ..
                    },
                ..
            } => {
                if key_event.state == ElementState::Pressed {
                    let ctrl = CTRL_CACHE.with(|c| c.borrow().control_key());
                    hotkey(&window, &inbox, &state, ctrl, key_event.physical_key);
                    drain(&mut content, &tabbar, &win2, &state2, &inbox2);
                }
            }
            // rút lệnh từ IPC (thanh tab + trang web) sau khi hệ thống giao sự kiện
            Event::MainEventsCleared => {
                drain(&mut content, &tabbar, &win2, &state2, &inbox2);
                let pending = inbox2.lock().map(|q| !q.is_empty()).unwrap_or(false);
                *control_flow = if pending { ControlFlow::Poll } else { ControlFlow::Wait };
            }
            _ => {}
        }
    });
}

/// Rút inbox và xử lý toàn bộ lệnh. Mỗi nhánh lock ngắn,
/// KHÔNG giữ lock qua lần gọi webview (chống deadlock IPC).
fn drain(
    content: &mut Option<WebView>,
    tabbar: &WebView,
    window: &Arc<tao::window::Window>,
    state: &Arc<Mutex<State>>,
    inbox: &Arc<Mutex<Vec<String>>>,
) {
    let msgs: Vec<String> = match inbox.lock() {
        Ok(mut q) => q.drain(..).collect(),
        Err(_) => Vec::new(),
    };
    if msgs.is_empty() {
        return;
    }
    let mut need_rebuild = false;
    for m in &msgs {
        let Ok(v) = serde_json::from_str::<Value>(m) else { continue };
        match v.get("cmd").and_then(|x| x.as_str()).unwrap_or("") {
            "title" | "url" => apply_page_meta(state, &v),
            "back" => {
                if let Some(c) = content.as_ref() {
                    let _ = c.evaluate_script("history.back()");
                }
            }
            "fwd" => {
                if let Some(c) = content.as_ref() {
                    let _ = c.evaluate_script("history.forward()");
                }
            }
            "reload" => {
                if let Some(c) = content.as_ref() {
                    let _ = c.evaluate_script("location.reload()");
                }
            }
            "focus-url" => {
                let _ = tabbar
                    .evaluate_script("var e=document.getElementById('url');e.focus();e.select()");
            }
            "nav" | "new" | "close" | "switch" | "home" => {
                if apply_cmd(state, &v) {
                    need_rebuild = true;
                }
            }
            _ => {}
        }
    }
    if need_rebuild {
        *content = Some(build_content(window, inbox.clone(), state));
        layout(tabbar, content.as_ref(), window.inner_size());
    }
    render_tabbar(tabbar, state);
}

/// Lệnh đổi cấu trúc tab. Trả true = cần dựng lại webview nội dung.
fn apply_cmd(state: &Arc<Mutex<State>>, v: &Value) -> bool {
    let mut s = state.lock().unwrap();
    match v.get("cmd").and_then(|x| x.as_str()).unwrap_or("") {
        "nav" => {
            if let Some(u) = v.get("url").and_then(|x| x.as_str()) {
                let i = s.active;
                s.tabs[i] = Tab::web(u);
                return true;
            }
            false
        }
        "new" => {
            if s.tabs.len() >= MAX_TABS {
                return false;
            }
            let u = v.get("url").and_then(|x| x.as_str()).map(String::from);
            let i = s.active + 1;
            s.tabs.insert(i, match u.as_deref() { Some(x) => Tab::web(x), None => Tab::dial() });
            s.active = i;
            true
        }
        "close" => {
            let i = v.get("i").and_then(|x| x.as_u64()).unwrap_or(s.active as u64) as usize;
            if i < s.tabs.len() {
                s.tabs.remove(i);
            }
            if s.tabs.is_empty() {
                s.tabs.push(Tab::dial());
            }
            if s.active >= s.tabs.len() {
                s.active = s.tabs.len() - 1;
            }
            true
        }
        "switch" => {
            let i = v.get("i").and_then(|x| x.as_u64()).unwrap_or(0) as usize;
            if i < s.tabs.len() {
                s.active = i;
                true
            } else {
                false
            }
        }
        "home" => {
            let i = s.active;
            s.tabs[i] = Tab::dial();
            true
        }
        _ => false,
    }
}

/// Cập nhật title/url tab hiện tại (do init script trong trang báo về).
fn apply_page_meta(state: &Arc<Mutex<State>>, v: &Value) {
    let val = v.get("v").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let mut s = state.lock().unwrap();
    let i = s.active;
    match v.get("cmd").and_then(|x| x.as_str()).unwrap_or("") {
        "title" => {
            if !val.is_empty() {
                s.tabs[i].title = val;
            }
        }
        "url" => {
            // about:blank/data: = nội dung Speed Dial — giữ None
            if !val.starts_with("about:") && !val.starts_with("data:") {
                s.tabs[i].url = Some(val);
            }
        }
        _ => {}
    }
}

fn render_tabbar(tabbar: &WebView, state: &Arc<Mutex<State>>) {
    let s = state.lock().unwrap();
    let active_url = s.tabs[s.active].url.clone();
    let payload = json!({
        "tabs": s.tabs.iter().map(|t| json!({"title": t.label(), "url": t.url})).collect::<Vec<_>>(),
        "active": s.active,
        "url": active_url,
    });
    drop(s);
    let js = format!("window.__bh_update({})", payload);
    let _ = tabbar.evaluate_script(&js);
}

/// Dựng webview nội dung cho tab đang active (dial = with_html, web = with_url).
fn build_content(
    window: &tao::window::Window,
    inbox: Arc<Mutex<Vec<String>>>,
    state: &Arc<Mutex<State>>,
) -> WebView {
    let url = {
        let s = state.lock().unwrap();
        s.tabs[s.active].url.clone()
    };
    let inbox2 = inbox;
    let builder = WebViewBuilder::new()
        .with_initialization_script(ui::PAGE_HOOK_JS)
        .with_ipc_handler(move |req| {
            if let Ok(v) = serde_json::from_str::<Value>(req.body()) {
                if let Ok(mut q) = inbox2.lock() {
                    q.push(v.to_string());
                }
            }
        });
    let builder = match url {
        Some(u) => builder.with_url(&u),
        None => builder.with_html(ui::DIAL_HTML),
    };
    builder
        .build_as_child(window)
        .expect("không tạo được webview nội dung")
}

/// Xếp bounds: thanh tab trên cùng, nội dung chiếm phần còn lại.
fn layout(tabbar: &WebView, content: Option<&WebView>, size: PhysicalSize<u32>) {
    let w = size.width as i32;
    let h = size.height as i32;
    let bar = TABBAR_H.min((h - 1).max(1));
    let _ = tabbar.set_bounds(Rect {
        position: Position::Physical(PhysicalPosition::new(0, 0)),
        size: Size::Physical(PhysicalSize::new(w.max(1) as u32, bar as u32)),
    });
    if let Some(c) = content {
        let _ = c.set_bounds(Rect {
            position: Position::Physical(PhysicalPosition::new(0, bar)),
            size: Size::Physical(PhysicalSize::new(w.max(1) as u32, (h - bar).max(1) as u32)),
        });
    }
}

/// Phím tắt gaming — tất cả đều đẩy lệnh vào inbox (một đường xử lý duy nhất).
fn hotkey(
    window: &tao::window::Window,
    inbox: &Arc<Mutex<Vec<String>>>,
    state: &Arc<Mutex<State>>,
    ctrl: bool,
    key: KeyCode,
) {
    use KeyCode as K;
    // F11 không cần Ctrl
    if key == K::F11 {
        let full = { state.lock().unwrap().full };
        if full {
            window.set_fullscreen(None);
        } else {
            window.set_fullscreen(Some(Fullscreen::Borderless(None)));
        }
        state.lock().unwrap().full = !full;
        return;
    }
    let (active, len) = {
        let s = state.lock().unwrap();
        (s.active, s.tabs.len())
    };
    let mut cmd: Option<Value> = None;
    match (ctrl, key) {
        (true, K::KeyT) => cmd = Some(json!({"cmd": "new"})),
        (true, K::KeyW) => cmd = Some(json!({"cmd": "close", "i": active})),
        (true, K::Tab) => cmd = Some(json!({"cmd": "switch", "i": (active + 1) % len.max(1)})),
        (true, K::Digit1) => cmd = Some(json!({"cmd": "switch", "i": 0})),
        (true, K::Digit2) => cmd = Some(json!({"cmd": "switch", "i": 1})),
        (true, K::Digit3) => cmd = Some(json!({"cmd": "switch", "i": 2})),
        (true, K::Digit4) => cmd = Some(json!({"cmd": "switch", "i": 3})),
        (true, K::Digit5) => cmd = Some(json!({"cmd": "switch", "i": 4})),
        (true, K::Digit6) => cmd = Some(json!({"cmd": "switch", "i": 5})),
        (true, K::Digit7) => cmd = Some(json!({"cmd": "switch", "i": 6})),
        (true, K::Digit8) => cmd = Some(json!({"cmd": "switch", "i": 7})),
        (true, K::KeyL) => cmd = Some(json!({"cmd": "focus-url"})),
        (true, K::KeyR) => cmd = Some(json!({"cmd": "reload"})),
        (true, K::KeyH) => cmd = Some(json!({"cmd": "home"})),
        _ => {}
    }
    if let Some(c) = cmd {
        if let Ok(mut q) = inbox.lock() {
            q.push(c.to_string());
        }
    }
}
