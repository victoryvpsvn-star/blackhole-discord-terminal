// commands.rs — tầng COMMAND của BlackholeCore.
//
// Mọi tương tác (IPC từ UI, phím tắt, link _blank) đều quy về Command,
// rồi thi hành DUY NHẤT qua exec() — không logic rải rác trong main.

use crate::core::ipc::Msg;
use crate::core::prefs::{url_or_search, Prefs};
use crate::core::tabs::TabManager;

#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// Đi tới URL (url bar / tile speed dial / tìm kiếm Google)
    Nav { tab: usize, url: String },
    /// Tab mới (None = Speed Dial)
    NewTab { after: usize, url: Option<String> },
    /// Đóng tab i
    CloseTab { i: usize },
    /// Chuyển tab
    SwitchTab { i: usize },
    /// Về Speed Dial tab hiện tại
    Home { tab: usize },
    Back { tab: usize },
    Forward { tab: usize },
    Reload { tab: usize },
    FocusUrl,
    ZoomIn { tab: usize },
    ZoomOut { tab: usize },
    ZoomReset { tab: usize },
    /// Bật/tắt TURBO (dọn cache + giải phóng RAM của nhân)
    ToggleTurbo,
    /// Devtools tab hiện tại (F12)
    Devtools { tab: usize },
    /// Trang web tự báo title/url (tab id đi kèm)
    PageTitle { tab: usize, title: String },
    PageUrl { tab: usize, url: String },
}

impl Command {
    /// Parse Msg -> Command. Nhận cả "url" và "v" cho nav.
    pub fn from_msg(m: &Msg, active: usize) -> Option<Command> {
        let tab = m.tab.unwrap_or(active);
        match m.cmd.as_str() {
            "nav" => Some(Command::Nav { tab, url: m.value.clone() }),
            "new" => Some(Command::NewTab {
                after: tab,
                url: if m.value.is_empty() { None } else { Some(m.value.clone()) },
            }),
            "close" => Some(Command::CloseTab { i: tab }),
            "switch" => Some(Command::SwitchTab { i: tab }),
            "home" => Some(Command::Home { tab }),
            "back" => Some(Command::Back { tab }),
            "fwd" => Some(Command::Forward { tab }),
            "reload" => Some(Command::Reload { tab }),
            "focus-url" => Some(Command::FocusUrl),
            "zoom-in" => Some(Command::ZoomIn { tab }),
            "zoom-out" => Some(Command::ZoomOut { tab }),
            "zoom-reset" => Some(Command::ZoomReset { tab }),
            "turbo" => Some(Command::ToggleTurbo),
            "devtools" => Some(Command::Devtools { tab }),
            "title" => Some(Command::PageTitle { tab, title: m.value.clone() }),
            "url" => Some(Command::PageUrl { tab, url: m.value.clone() }),
            _ => None,
        }
    }

    /// Nav có thông minh: gõ "github.com" -> https, gõ câu hỏi -> GOOGLE search.
    pub fn smart_nav(tab: usize, input: &str, prefs: &Prefs) -> Command {
        Command::Nav { tab, url: url_or_search(input, &prefs.search_engine) }
    }
}

/// Kết quả exec — cho UI biết có cần render lại tab bar không.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ExecOutcome {
    pub rerender: bool,
    pub rebuilt: bool,
}

/// Thi hành lệnh trên TabManager. `notify` = đẩy toast vào tab bar.
/// `make_webview` = factory của main (dùng khi nav/switch cần tạo webview).
pub fn exec(
    cmd: &Command,
    tabs: &mut TabManager,
    prefs: &mut Prefs,
    tabbar: &wry::WebView,
    notify: &dyn Fn(&str),
    make_webview: &mut dyn FnMut(usize, Option<&str>, f64) -> Result<wry::WebView, String>,
) -> ExecOutcome {
    let mut out = ExecOutcome { rerender: false, rebuilt: false };
    match cmd {
        Command::Nav { tab, url } => {
            tabs.navigate(*tab, url, prefs.zoom, make_webview);
            tabs.ensure_active_ready(prefs.zoom, make_webview);
            out.rerender = true;
            out.rebuilt = true;
        }
        Command::NewTab { after, url } => {
            let i = tabs.insert_after(*after, url.clone());
            tabs.activate(i, prefs.zoom);
            tabs.ensure_active_ready(prefs.zoom, make_webview);
            out.rerender = true;
            out.rebuilt = true;
        }
        Command::CloseTab { i } => {
            tabs.close(*i);
            tabs.activate(tabs.active, prefs.zoom);
            tabs.ensure_active_ready(prefs.zoom, make_webview);
            out.rerender = true;
            out.rebuilt = true;
        }
        Command::SwitchTab { i } => {
            tabs.activate(*i, prefs.zoom);
            tabs.ensure_active_ready(prefs.zoom, make_webview);
            out.rerender = true;
            out.rebuilt = true;
        }
        Command::Home { tab } => {
            let url = scheme_start_url();
            tabs.navigate(*tab, &url, prefs.zoom, make_webview);
            tabs.ensure_active_ready(prefs.zoom, make_webview);
            out.rerender = true;
            out.rebuilt = true;
        }
        Command::Back { tab } => {
            tabs.with_entry(*tab, |wv| {
                let _ = wv.evaluate_script("history.back()");
            });
        }
        Command::Forward { tab } => {
            tabs.with_entry(*tab, |wv| {
                let _ = wv.evaluate_script("history.forward()");
            });
        }
        Command::Reload { tab } => {
            tabs.with_entry(*tab, |wv| {
                let _ = wv.evaluate_script("location.reload()");
            });
        }
        Command::FocusUrl => {
            let _ = tabbar.evaluate_script(
                "var e=document.getElementById('url');if(e){e.focus();e.select()}",
            );
        }
        Command::ZoomIn { tab } => {
            prefs.zoom = (prefs.zoom + 0.1).min(3.0);
            tabs.apply_zoom(*tab, prefs.zoom);
            prefs.save();
            notify(&format!("Zoom {}%", (prefs.zoom * 100.0) as u32));
            out.rerender = true;
        }
        Command::ZoomOut { tab } => {
            prefs.zoom = (prefs.zoom - 0.1).max(0.3);
            tabs.apply_zoom(*tab, prefs.zoom);
            prefs.save();
            notify(&format!("Zoom {}%", (prefs.zoom * 100.0) as u32));
            out.rerender = true;
        }
        Command::ZoomReset { tab } => {
            prefs.zoom = 1.0;
            tabs.apply_zoom(*tab, 1.0);
            prefs.save();
            notify("Zoom 100%");
            out.rerender = true;
        }
        Command::ToggleTurbo => {
            prefs.turbo = !prefs.turbo;
            prefs.save();
            if prefs.turbo {
                // TURBO BẬT: quét toàn bộ tab sống — dọn cache + free RAM của nhân
                let freed = tabs.clear_browsing_data_all();
                notify(&format!(
                    "TURBO ON — đã dọn cache {} tab, giải phóng RAM cho game",
                    freed
                ));
            } else {
                notify("TURBO OFF");
            }
            out.rerender = true;
        }
        Command::Devtools { tab } => {
            tabs.open_devtools(*tab);
        }
        Command::PageTitle { tab, title } => {
            tabs.set_title(*tab, title);
            out.rerender = true;
        }
        Command::PageUrl { tab, url } => {
            // about:blank/data: = trang nội sinh (speed dial sinh html) — giữ nguyên
            if !url.starts_with("about:") && !url.starts_with("data:") {
                tabs.set_url(*tab, url);
                out.rerender = true;
            }
        }
    }
    out
}

/// URL trang Speed Dial (qua scheme riêng của Blackhole).
pub fn scheme_start_url() -> String {
    crate::core::scheme::internal_url("start")
}

// ================= TEST =================
#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::ipc::Msg;

    #[test]
    fn parse_len_thanh_command() {
        let m = Msg::parse(r#"{"cmd":"switch","tab":2}"#).unwrap();
        let c = Command::from_msg(&m, 0).unwrap();
        assert_eq!(c, Command::SwitchTab { i: 2 });

        let m = Msg::parse(r#"{"cmd":"title","tab":1,"v":"GitHub"}"#).unwrap();
        let c = Command::from_msg(&m, 0).unwrap();
        assert_eq!(c, Command::PageTitle { tab: 1, title: "GitHub".into() });
    }

    #[test]
    fn nav_thong_minh_google() {
        let p = Prefs::default();
        let c = Command::smart_nav(0, "github.com", &p);
        assert_eq!(c, Command::Nav { tab: 0, url: "https://github.com".into() });
        let c = Command::smart_nav(0, "cách build rust", &p);
        match c {
            Command::Nav { url, .. } => assert!(url.contains("google.com/search?q=")),
            _ => panic!("sai"),
        }
    }

    #[test]
    fn len_la_khong_noi_lan() {
        assert_eq!(Command::from_msg(&Msg::parse(r#"{"cmd":"abc"}"#).unwrap(), 0), None);
    }
}
