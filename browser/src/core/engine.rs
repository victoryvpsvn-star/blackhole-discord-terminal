// engine.rs — tầng ENGINE của BlackholeCore.
//
// Đây là nơi BLACKHOLE "làm chủ" nhân webview thay vì dùng mặc định
// như mọi demo webview khác:
//   * USER-AGENT RIÊNG  — nhận diện BlackholeBrowser/3.0 (giữ token
//     Chrome/Chromium để mọi trang web chấp nhận, không bị chặn)
//   * BROWSER ARGS RIÊNG — tắt UI overlay của Edge (WebOOUI/PdfOOUI/
//     SmartScreen), không throttle tab nền (game thủ alt-tab liên tục
//     tab nhạc/tab wiki vẫn chạy full tốc), không render-backgrounding
//   * PROFILE RIÊNG     — data dir ~/.blackhole-browser/data: cookie,
//     cache, storage của Blackhole TÁCH BIỆT khỏi Edge/Chrome/Opera
//   * THEME DARK RIÊNG  — webview mặc định dark (Windows/WebView2)
//
// Webview được tạo qua factory duy nhất này — không ai tự build lẻ tẻ.

use crate::core::prefs::profile_dir;
use wry::WebViewBuilder;

/// User-Agent của Blackhole Browser.
///
/// Cấu trúc: giữ nguyên chuỗi UA chuẩn Chrome/Windows để tương thích
/// 100% mọi trang web, chỉ thêm token `BlackholeBrowser/3.0` ở cuối.
pub fn user_agent() -> String {
    let chrome_token = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
    format!("{} BlackholeBrowser/{}", chrome_token, crate::core::CORE_VERSION)
}

/// Browser args riêng của Blackhole (chỉ áp dụng cho WebView2/Windows).
///
/// Ghi chú: khi tự set args thì PHẢI tự thêm lại các arg mặc định của
/// wry (--disable-features=msWebOOUI,...) như doc của wry ghi rõ.
pub const BROWSER_ARGS: &str = "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection \
     --autoplay-policy=no-user-gesture-required \
     --disable-background-timer-throttling \
     --disable-backgrounding-occluded-windows \
     --disable-renderer-backgrounding";

/// Thư mục dữ liệu profile riêng (cookie/cache/storage của Blackhole).
pub fn data_dir() -> std::path::PathBuf {
    profile_dir().join("data")
}

/// Mô tả nhân đang chạy (hiện ở trang about + log boot).
pub fn engine_label() -> String {
    let v = wry::webview_version().unwrap_or_else(|_| "?".into());
    #[cfg(target_os = "windows")]
    {
        format!("WebView2 (Chromium core) {}", v)
    }
    #[cfg(not(target_os = "windows"))]
    {
        format!("WebKitGTK {}", v)
    }
}

/// Factory dựng 1 webview con ĐÃ cấu hình đầy đủ BlackholeCore:
/// UA + theme dark + gesture + web context (profile riêng).
///
/// Trả builder đã "kỹ thuật hoá" — caller chỉ cần with_url/with_html
/// (+ IPC/title/custom protocol) rồi build_as_child.
pub fn new_core_webview<'a>(
    context: &'a mut wry::WebContext,
) -> WebViewBuilder<'a> {
    let b = WebViewBuilder::with_web_context(context)
        .with_user_agent(user_agent())
        .with_transparent(false)
        .with_back_forward_navigation_gestures(true);

    // Windows/WebView2: theme dark + browser args riêng (trait platform)
    #[cfg(target_os = "windows")]
    let b = {
        use wry::{Theme, WebViewBuilderExtWindows};
        b.with_theme(Theme::Dark)
            .with_additional_browser_args(BROWSER_ARGS)
    };

    b
}

// ================= TEST =================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ua_co_token_blackhole_va_chrome() {
        let ua = user_agent();
        assert!(ua.contains("BlackholeBrowser/"), "thiếu brand: {}", ua);
        assert!(ua.starts_with("Mozilla/5.0"), "UA phải chuẩn Chrome: {}", ua);
        assert!(ua.contains("Chrome/"), "thiếu token Chrome để tương thích");
    }

    #[test]
    fn args_chua_du_chong_throttle() {
        assert!(BROWSER_ARGS.contains("msWebOOUI"), "phải giữ arg mặc định wry");
        assert!(BROWSER_ARGS.contains("no-user-gesture-required"));
        assert!(BROWSER_ARGS.contains("disable-background-timer-throttling"));
        assert!(BROWSER_ARGS.contains("disable-renderer-backgrounding"));
    }

    #[test]
    fn data_dir_la_profile_rieng() {
        assert!(data_dir().ends_with(".blackhole-browser/data"));
        assert!(user_agent().contains(crate::core::CORE_VERSION));
    }

    #[test]
    fn engine_label_khong_rong() {
        assert!(!engine_label().is_empty());
    }
}
