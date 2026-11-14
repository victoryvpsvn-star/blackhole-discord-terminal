// ============================================================
//  core/mod.rs — BLACKHOLE CORE
//
//  "Nhân trình duyệt riêng" của BLACKHOLE Browser.
//
//  Phân tầng rõ ràng, mỗi tầng 1 file, không code lộn xộn:
//
//    engine.rs    -> tầng ENGINE  : cấu hình nhân webview (UA riêng,
//                    browser args riêng, profile/cache riêng, GPU args)
//    tabs.rs      -> tầng TABS    : TabManager keep-alive đa webview
//                    (tab KHÔNG bị dựng lại khi chuyển — hết delay),
//                    LRU đóng bớt webview khi mở nhiều tab quá 8
//    ipc.rs       -> tầng IPC     : inbox + giao thức message JSON
//    commands.rs  -> tầng COMMAND : parse + thi hành lệnh trên tabs
//    scheme.rs    -> tầng SCHEME  : trang nội bộ blackhole:// (start,
//                    about, version) — như chrome:// của Chrome
//    prefs.rs     -> tầng PREFS   : cấu hình người dùng (search engine
//                    GOOGLE mặc định, homepage, zoom, turbo)
//    layout.rs    -> tầng LAYOUT  : xếp bounds thanh tab + nội dung
//    hotkeys.rs   -> tầng HOTKEY  : bảng phím tắt gaming (pure fn, test được)
//
//  Nhân JS/render vẫn là nhân Chromium có sẵn trong máy (WebView2/
//  WebKitGTK) — nói THẲNG như vậy: không ai viết lại nhân JS trong
//  một dự án này được. Nhưng VẬN HÀNH nhân đó là BlackholeCore:
//  profile riêng, UA riêng, flags riêng, tabs riêng, scheme riêng —
//  đúng mô hình Brave/Opera/Edge đều đi trên nhân Chromium nhưng
//  khác nhau ở tầng core vận hành.
// ============================================================

pub mod commands;
pub mod engine;
pub mod hotkeys;
pub mod ipc;
pub mod layout;
pub mod prefs;
pub mod scheme;
pub mod tabs;

/// Bản dựng — in ở --version + trang about.
pub const CORE_VERSION: &str = "3.0.0";
pub const CORE_NAME: &str = "BlackholeCore";
