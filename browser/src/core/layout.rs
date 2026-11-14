// layout.rs — tầng LAYOUT: xếp bounds cho thanh tab + webview nội dung.

use tao::dpi::{PhysicalPosition, PhysicalSize, Position, Size};
use wry::Rect;

pub const TABBAR_H: i32 = 52;

/// Rect thanh tab (trên cùng, full width).
pub fn tabbar_rect(w: i32, h: i32) -> Rect {
    let bar = TABBAR_H.min((h - 1).max(1));
    Rect {
        position: Position::Physical(PhysicalPosition::new(0, 0)),
        size: Size::Physical(PhysicalSize::new(w.max(1) as u32, bar as u32)),
    }
}

/// Rect nội dung (phần còn lại dưới thanh tab).
pub fn content_rect(w: i32, h: i32) -> Rect {
    let bar = TABBAR_H.min((h - 1).max(1));
    Rect {
        position: Position::Physical(PhysicalPosition::new(0, bar)),
        size: Size::Physical(PhysicalSize::new(w.max(1) as u32, (h - bar).max(1) as u32)),
    }
}

/// Áp layout: thanh tab + mọi webview SỐNG (chỉ tab active cần visible,
/// nhưng bounds của tab ẩn vẫn cập nhật để khi show lên là đúng vị trí).
pub fn apply(
    tabbar: &wry::WebView,
    size: tao::dpi::PhysicalSize<u32>,
    entries: &mut dyn Iterator<Item = &wry::WebView>,
) {
    let w = size.width as i32;
    let h = size.height as i32;
    let _ = tabbar.set_bounds(tabbar_rect(w, h));
    let rect = content_rect(w, h);
    for wv in entries {
        let _ = wv.set_bounds(rect);
    }
}

// ================= TEST =================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rect_hop_ly() {
        let bar = tabbar_rect(1280, 820);
        let content = content_rect(1280, 820);
        match (bar.size, content.size) {
            (Size::Physical(bs), Size::Physical(cs)) => {
                assert_eq!(bs.width, 1280);
                assert_eq!(bs.height, TABBAR_H as u32);
                assert_eq!(cs.width, 1280);
                assert_eq!(cs.height, (820 - TABBAR_H) as u32);
            }
            _ => panic!("phải là Size::Physical"),
        }
        match content.position {
            Position::Physical(p) => assert_eq!(p.y, TABBAR_H),
            _ => panic!("phải là Position::Physical"),
        }
    }

    #[test]
    fn window_qua_nho_khong_panic() {
        let bar = tabbar_rect(1, 1);
        let content = content_rect(1, 1);
        match (bar.size, content.size) {
            (Size::Physical(bs), Size::Physical(cs)) => {
                assert!(bs.width >= 1 && bs.height >= 1);
                assert!(cs.width >= 1 && cs.height >= 1);
            }
            _ => panic!(),
        }
    }
}
