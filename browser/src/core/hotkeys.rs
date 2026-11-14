// hotkeys.rs — tầng HOTKEY của BlackholeCore: bảng phím tắt gaming.
//
// Pure function: (ctrl, KeyCode) -> Option<Command> — không phụ thuộc
// platform, test được đầy đủ. F11 fullscreen + F9 TURBO xử lý riêng
// (đổi window state / không qua Command).

use crate::core::commands::Command;
use tao::keyboard::KeyCode;

/// Map phím -> Command. Trả None nếu không phải hotkey.
pub fn map(ctrl: bool, key: KeyCode, active: usize, len: usize) -> Option<Command> {
    use KeyCode as K;
    let tab = active;
    match (ctrl, key) {
        // --- tab ---
        (true, K::KeyT) => Some(Command::NewTab { after: active, url: None }),
        (true, K::KeyW) => Some(Command::CloseTab { i: active }),
        (true, K::Tab) => Some(Command::SwitchTab { i: (active + 1) % len.max(1) }),
        (true, K::Digit1) => Some(Command::SwitchTab { i: 0 }),
        (true, K::Digit2) => Some(Command::SwitchTab { i: 1 }),
        (true, K::Digit3) => Some(Command::SwitchTab { i: 2 }),
        (true, K::Digit4) => Some(Command::SwitchTab { i: 3 }),
        (true, K::Digit5) => Some(Command::SwitchTab { i: 4 }),
        (true, K::Digit6) => Some(Command::SwitchTab { i: 5 }),
        (true, K::Digit7) => Some(Command::SwitchTab { i: 6 }),
        (true, K::Digit8) => Some(Command::SwitchTab { i: 7 }),
        // --- điều hướng ---
        (true, K::KeyL) => Some(Command::FocusUrl),
        (true, K::KeyR) => Some(Command::Reload { tab }),
        (true, K::KeyH) => Some(Command::Home { tab }),
        // --- zoom ---
        (true, K::Equal) => Some(Command::ZoomIn { tab }),
        (true, K::Minus) => Some(Command::ZoomOut { tab }),
        (true, K::Digit0) => Some(Command::ZoomReset { tab }),
        // --- công cụ ---
        // F9/F12/F5 bấm KHÔNG cần Ctrl (chuẩn browser)
        (true, K::F9) | (false, K::F9) => Some(Command::ToggleTurbo),
        (true, K::F12) | (false, K::F12) => Some(Command::Devtools { tab }),
        (false, K::F5) => Some(Command::Reload { tab }),
        _ => None,
    }
}

/// Chuỗi help cho --help + trang dial.
pub const HOTKEY_HELP: &str = "\
Phím tắt gaming:
  Ctrl+T        tab mới
  Ctrl+W        đóng tab
  Ctrl+Tab      tab kế tiếp
  Ctrl+1..8     nhảy tới tab 1..8
  Ctrl+L        focus thanh địa chỉ
  Ctrl+R / F5   reload (F5 xử lý ở main)
  Ctrl+H        về Speed Dial
  Ctrl+= / -/ 0 zoom in / out / reset
  F9            TURBO on/off (dọn cache, trả RAM về game)
  F12           DevTools
  F11           fullscreen";

// ================= TEST =================
#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::commands::Command;

    #[test]
    fn phim_tab_chuan() {
        assert_eq!(map(true, KeyCode::KeyT, 0, 1), Some(Command::NewTab { after: 0, url: None }));
        assert_eq!(map(true, KeyCode::KeyW, 2, 3), Some(Command::CloseTab { i: 2 }));
        assert_eq!(map(true, KeyCode::Tab, 2, 5), Some(Command::SwitchTab { i: 3 }));
        assert_eq!(map(true, KeyCode::Tab, 4, 5), Some(Command::SwitchTab { i: 0 }), "quay vòng");
    }

    #[test]
    fn chu_so_nhay_tab() {
        assert_eq!(map(true, KeyCode::Digit3, 0, 9), Some(Command::SwitchTab { i: 2 }));
        assert_eq!(map(true, KeyCode::Digit0, 0, 9), Some(Command::ZoomReset { tab: 0 }));
    }

    #[test]
    fn turbo_va_devtools_f9_f12() {
        assert_eq!(map(true, KeyCode::F9, 0, 1), Some(Command::ToggleTurbo));
        assert_eq!(map(false, KeyCode::F9, 0, 1), Some(Command::ToggleTurbo), "F9 không cần Ctrl");
        assert_eq!(map(true, KeyCode::F12, 1, 1), Some(Command::Devtools { tab: 1 }));
        assert_eq!(map(false, KeyCode::F12, 1, 1), Some(Command::Devtools { tab: 1 }));
        assert_eq!(map(false, KeyCode::F5, 2, 3), Some(Command::Reload { tab: 2 }));
    }

    #[test]
    fn khong_ctrl_khong_phai_hotkey() {
        assert_eq!(map(false, KeyCode::KeyT, 0, 1), None);
        assert_eq!(map(false, KeyCode::KeyW, 0, 1), None);
    }

    #[test]
    fn phim_la_khong_lam_gi() {
        assert_eq!(map(true, KeyCode::KeyQ, 0, 1), None);
        assert_eq!(map(false, KeyCode::Escape, 0, 1), None);
    }
}
