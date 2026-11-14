// ============================================================
//  BLACKHOLE Browser v2.0-core — bootstrap + event loop
//
//  Toàn bộ logic nằm trong core/ (BlackholeCore) — file này chỉ:
//    1. parse args (--help/--version/--url)
//    2. dựng cửa sổ + thanh tab + webview đầu tiên
//    3. bơm message IPC + phím tắt vào Command rồi exec() qua core
//    4. layout lại khi resize
//
//  Factory webview duy nhất: mọi tab đi qua new_core_webview() của
//  core/engine.rs — UA riêng, args riêng, profile riêng, scheme riêng.
// ============================================================

mod core;
mod ui;

use std::sync::Arc;

use serde_json::{json, Value};
use tao::event::{ElementState, Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoop};
use tao::keyboard::{KeyCode, ModifiersState};
use tao::window::{Fullscreen, WindowBuilder};
use wry::{WebView, WebViewBuilder};

use crate::core::commands::{Command, exec};
use crate::core::engine::{data_dir, new_core_webview};
use crate::core::hotkeys;
use crate::core::ipc::{Inbox, Msg};
use crate::core::layout;
use crate::core::prefs::Prefs;
use crate::core::scheme;
use crate::core::tabs::TabManager;
use crate::core::CORE_NAME;
use crate::core::CORE_VERSION;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("BLACKHOLE Browser {} ({} {}) — gaming browser siêu nhẹ", CORE_VERSION, CORE_NAME, core::engine::engine_label());
        println!();
        println!("Chạy:  blackhole-browser [tuỳ chọn]");
        println!("  (không gì cả)   mở Speed Dial");
        println!("  --url <link>    mở thẳng 1 trang");
        println!("  --bench         chạy BH-Bench 3 lần, in điểm JS rồi thoát");
        println!("  --help          hướng dẫn này");
        println!("  --version       phiên bản core");
        println!();
        println!("{}", hotkeys::HOTKEY_HELP);
        println!();
        println!("Profile: {} (riêng biệt)", core::prefs::profile_dir().display());
        println!("Search mặc định: Google");
        return;
    }
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("BLACKHOLE Browser {} ({} {})", CORE_VERSION, CORE_NAME, core::engine::engine_label());
        return;
    }
    let start_url = args
        .iter()
        .position(|a| a == "--url")
        .and_then(|i| args.get(i + 1))
        .cloned();
    // --bench: mở trang bench nội bộ, chạy 3 vòng BH-Bench, in điểm rồi thoát
    let bench_mode = args.iter().any(|a| a == "--bench");

    let _ = std::fs::create_dir_all(data_dir());

    let event_loop = EventLoop::new();
    let window = Arc::new(
        WindowBuilder::new()
            .with_title("BLACKHOLE Browser — gaming edition")
            .with_inner_size(tao::dpi::LogicalSize::new(1280.0, 820.0))
            .build(&event_loop)
            .expect("không tạo được cửa sổ"),
    );
    // clone riêng cho factory — factory là move closure giữ Arc này
    let window_f = window.clone();

    // ---- BlackholeCore state (chỉ dùng trên main thread) ----
    let mut prefs = Prefs::load();
    let inbox = Inbox::new();
    let mut tabs = TabManager::new(start_url);
    tabs.turbo = prefs.turbo;
    if bench_mode {
        // tab đầu = trang bench nội bộ (qua scheme blackhole://bench)
        let bench_url = scheme::internal_url("bench");
        tabs.set_url(0, &bench_url);
        tabs.set_title(0, "BH-Bench");
    }
    let dial_html = ui::dial::dial_html();
    let mut webctx = wry::WebContext::new(Some(data_dir()));

    // ---- thanh tab ----
    let tabbar = WebViewBuilder::new()
        .with_html(ui::tabbar::tabbar_html())
        .with_ipc_handler({
            let inbox2 = inbox.clone();
            move |req| {
                if let Ok(v) = serde_json::from_str::<Value>(req.body()) {
                    inbox2.push_json(v);
                }
            }
        })
        .build_as_child(&window)
        .expect("không tạo được thanh tab");

    // ---- FACTORY webview duy nhất của BlackholeCore ----
    // Mỗi tab: IPC riêng theo tab id + title handler native + scheme riêng.
    let inbox_f = inbox.clone();
    let mut make_webview = move |tab_id: usize,
                                 url: Option<&str>,
                                 _zoom: f64|
          -> Result<WebView, String> {
        let inbox_ipc = inbox_f.clone();
        let inbox_title = inbox_f.clone();
        let inbox_blank = inbox_f.clone();
        let hook = ui::pagehook::pagehook(tab_id);
        let mut b = new_core_webview(&mut webctx)
            .with_initialization_script(&hook)
            .with_ipc_handler(move |req| {
                if let Ok(v) = serde_json::from_str::<Value>(req.body()) {
                    inbox_ipc.push_json(v);
                }
            })
            .with_document_title_changed_handler(move |title| {
                inbox_title.push_json(json!({"cmd": "title", "tab": tab_id, "v": title}));
            })
            .with_new_window_req_handler(move |new_url| {
                // target=_blank -> mở thành TAB MỚI của Blackhole, không thoát app
                inbox_blank.push_json(json!({"cmd": "new", "tab": tab_id, "url": new_url}));
                false
            })
            .with_custom_protocol("blackhole".to_string(), scheme::handler);
        b = match url {
            Some(u) => b.with_url(u),
            None => b.with_html(&dial_html),
        };
        b.build_as_child(&window_f).map_err(|e| e.to_string())
    };

    // ---- tab đầu tiên ----
    let _ = tabs.ensure_webview(0, prefs.zoom, &mut make_webview);
    if let Some(wv) = tabs.alive_webview(tabs.active) {
        let _ = wv.set_visible(true);
        let _ = wv.focus();
        let _ = wv.zoom(prefs.zoom);
    }
    let _ = tabbar.evaluate_script(&format!("window.__bh_update({})", tabs.view_model()));
    layout::apply(&tabbar, window.inner_size(), &mut tabs.alive());

    // ---- vòng lặp sự kiện ----
    let win2 = window.clone();
    let mut ctrl_state = ModifiersState::empty();
    let mut bench_count = 0usize;
    let bench_total = if bench_mode { 3 } else { 0 };

    event_loop.run(move |event, _, control_flow| match event {
        Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => {
            *control_flow = ControlFlow::Exit;
        }

        Event::WindowEvent { event: WindowEvent::Resized(size), .. } => {
            layout::apply(&tabbar, size, &mut tabs.alive());
            *control_flow = ControlFlow::Wait;
        }

        Event::WindowEvent { event: WindowEvent::ModifiersChanged(m), .. } => {
            ctrl_state = m;
        }

        Event::WindowEvent {
            event: WindowEvent::KeyboardInput { event: key_event, .. }, ..
        } => {
            if key_event.state != ElementState::Pressed {
                return;
            }
            // F11 fullscreen xử lý tại chỗ (đổi window state)
            if key_event.physical_key == KeyCode::F11 {
                if win2.fullscreen().is_some() {
                    win2.set_fullscreen(None);
                } else {
                    win2.set_fullscreen(Some(Fullscreen::Borderless(None)));
                }
                return;
            }
            let ctrl = ctrl_state.control_key();
            let cmd = match key_event.physical_key {
                KeyCode::F5 => Some(Command::Reload { tab: tabs.active }),
                _ => hotkeys::map(ctrl, key_event.physical_key, tabs.active, tabs.tabs.len()),
            };
            if let Some(cmd) = cmd {
                handle(
                    cmd,
                    &mut tabs,
                    &mut prefs,
                    &tabbar,
                    &window,
                    &mut make_webview,
                );
                *control_flow = ControlFlow::Wait;
            }
        }

        Event::MainEventsCleared => {
            // rút toàn bộ IPC -> Command -> exec
            for raw in inbox.drain() {
                let Some(m) = Msg::parse(&raw) else { continue };
                // chế độ --bench: nhận từng kết quả, in rồi thoát sau 3 lần
                if m.cmd == "bench" {
                    bench_count += 1;
                    println!("BH-BENCH-RESULT {} {}", bench_count, m.value);
                    if bench_count >= bench_total {
                        println!("BH-BENCH-DONE (core {} / {})", CORE_VERSION, core::engine::engine_label());
                        *control_flow = ControlFlow::Exit;
                        return;
                    }
                    continue;
                }
                let active = tabs.active;
                let cmd = match m.cmd.as_str() {
                    // nav từ url bar / speed dial: thông minh hoá (link hay GOOGLE search)
                    "nav" => Command::smart_nav(m.tab.unwrap_or(active), &m.value, &prefs),
                    _ => match Command::from_msg(&m, active) {
                        Some(c) => c,
                        None => continue,
                    },
                };
                handle(cmd, &mut tabs, &mut prefs, &tabbar, &window, &mut make_webview);
            }
            *control_flow = if inbox.is_empty() { ControlFlow::Wait } else { ControlFlow::Poll };
        }

        _ => {}
    });
}

/// Thi hành 1 Command: exec qua core, render lại UI + layout.
/// (fn thuần ở file này để KeyboardInput + IPC dùng chung một đường.)
fn handle(
    cmd: Command,
    tabs: &mut TabManager,
    prefs: &mut Prefs,
    tabbar: &WebView,
    window: &Arc<tao::window::Window>,
    make_webview: &mut dyn FnMut(usize, Option<&str>, f64) -> Result<WebView, String>,
) {
    let _ = exec(
        &cmd,
        tabs,
        prefs,
        tabbar,
        &|msg: &str| {
            let js = format!("window.__bh_toast({})", serde_json::json!(msg));
            let _ = tabbar.evaluate_script(&js);
        },
        make_webview,
    );
    let _ = tabbar.evaluate_script(&format!("window.__bh_update({})", tabs.view_model()));
    layout::apply(tabbar, window.inner_size(), &mut tabs.alive());
}
