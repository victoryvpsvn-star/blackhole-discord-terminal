// tabs.rs — tầng TABS của BlackholeCore: TAB MANAGER KEEP-ALIVE.
//
// Đây là FIX chính cho "delay web" của bản v1.0:
//   * v1.0: mỗi lần chuyển tab = DỰNG LẠI webview -> tải lại trang -> delay
//   * v2.0: MỖI TAB CÓ WEBVIEW RIÊNG SỐNG SÓT (keep-alive). Chuyển tab chỉ
//     là set_visible(false/true) + focus -> CHUYỂN NGAY TRONG 1 KHUNG HÌNH,
//     trang vẫn nằm nguyên trong RAM (giống Chrome/Edge thật).
//   * Giới hạn RAM: tối đa MAX_ALIVE webview sống cùng lúc. Mở tab thứ 9 ->
//     tab ít dùng nhất (LRU) bị "ngủ" (drop webview, GIỮ url) — kích lại thì
//     tải lại. Đúng cơ chế "Memory Saver" của browser gaming thế hệ 5.
//
// TabManager KHÔNG giữ window/inbox — main truyền factory dựng webview vào.

use wry::WebView;

pub const MAX_TABS: usize = 24;
pub const MAX_ALIVE: usize = 8;

pub struct TabMeta {
    pub url: Option<String>, // None = Speed Dial
    pub title: String,
}

pub struct TabManager {
    pub tabs: Vec<TabMeta>,
    entries: Vec<Option<WebView>>,
    pub active: usize,
    alive_order: Vec<usize>, // back = mới dùng nhất, front = cũ nhất
    pub turbo: bool,
}

impl TabManager {
    pub fn new(start_url: Option<String>) -> Self {
        TabManager {
            tabs: vec![TabMeta { url: start_url, title: String::new() }],
            entries: vec![None],
            active: 0,
            alive_order: vec![],
            turbo: false,
        }
    }

    /// Đếm webview đang sống.
    pub fn alive_count(&self) -> usize {
        self.entries.iter().filter(|e| e.is_some()).count()
    }

    /// Factory dựng webview cho tab i — do main.rs cung cấp (có window/inbox).
    /// Signature: FnMut(tab_id, url_or_none, zoom) -> Result<WebView, String>
    pub fn ensure_webview(
        &mut self,
        i: usize,
        zoom: f64,
        factory: &mut dyn FnMut(usize, Option<&str>, f64) -> Result<WebView, String>,
    ) -> bool {
        if i >= self.tabs.len() {
            return false;
        }
        if self.entries[i].is_some() {
            self.touch(i);
            return true;
        }
        let url = self.tabs[i].url.clone();
        match factory(i, url.as_deref(), zoom) {
            Ok(wv) => {
                self.entries[i] = Some(wv);
                self.touch(i);
                self.trim_lru();
                true
            }
            Err(e) => {
                eprintln!("[blackhole-core] tạo webview tab {} lỗi: {}", i, e);
                false
            }
        }
    }

    /// LRU: nếu số webview sống vượt MAX_ALIVE -> "ngủ" tab cũ nhất
    /// (không đụng tab đang active). Webview bị drop = RAM trả về OS.
    fn trim_lru(&mut self) {
        while self.alive_count() > MAX_ALIVE {
            let victim = self
                .alive_order
                .iter()
                .copied()
                .find(|j| self.entries[*j].is_some() && *j != self.active);
            let Some(v) = victim else { break };
            self.entries[v] = None;
            self.alive_order.retain(|x| *x != v);
        }
    }

    fn touch(&mut self, i: usize) {
        self.alive_order.retain(|x| *x != i);
        self.alive_order.push(i);
    }

    /// Chuyển tab: hide tab cũ -> ensure tab mới (lazy) -> show + focus.
    /// KHÔNG dựng lại nếu webview đã sống — đây chính là fix delay.
    pub fn activate(&mut self, i: usize, zoom: f64) -> bool {
        if i >= self.tabs.len() {
            return false;
        }
        if let Some(old) = self.entries[self.active].as_ref() {
            if i != self.active {
                let _ = old.set_visible(false);
            }
        }
        self.active = i;
        self.touch(i);
        if let Some(wv) = self.entries[i].as_ref() {
            let _ = wv.set_visible(true);
            let _ = wv.focus();
            let _ = wv.zoom(zoom);
            return true;
        }
        false // caller phải gọi ensure_webview qua factory rồi layout lại
    }

    /// Chèn tab mới sau `after`; trả về index tab mới.
    pub fn insert_after(&mut self, after: usize, url: Option<String>) -> usize {
        let i = (after + 1).min(self.tabs.len());
        self.tabs.insert(i, TabMeta { url, title: String::new() });
        self.entries.insert(i, None);
        if self.tabs.len() > MAX_TABS {
            // quá 24 tab: đóng tab cuối khác active
            let victim = self.tabs.len() - 1;
            if victim != self.active {
                self.close(victim);
            }
        }
        i
    }

    /// Đóng tab i; tự chọn tab kế cạnh và trả về active mới.
    pub fn close(&mut self, i: usize) -> usize {
        if i < self.tabs.len() {
            self.entries[i] = None; // drop webview -> RAM trả OS ngay
            self.alive_order.retain(|x| x != &i);
            self.tabs.remove(i);
            self.entries.remove(i);
        }
        if self.tabs.is_empty() {
            self.tabs.push(TabMeta { url: None, title: String::new() });
            self.entries.push(None);
        }
        if self.active >= self.tabs.len() {
            self.active = self.tabs.len() - 1;
        }
        self.active
    }

    /// load_url trên tab (tự ensure bằng factory nếu chưa sống).
    pub fn navigate(
        &mut self,
        i: usize,
        url: &str,
        zoom: f64,
        factory: &mut dyn FnMut(usize, Option<&str>, f64) -> Result<WebView, String>,
    ) {
        if i >= self.tabs.len() {
            return;
        }
        self.tabs[i].url = Some(url.to_string());
        if self.entries[i].is_none() {
            if !self.ensure_webview(i, zoom, factory) {
                return;
            }
            // webview mới sinh -> set visible theo active
            if i == self.active {
                if let Some(wv) = self.entries[i].as_ref() {
                    let _ = wv.set_visible(true);
                    let _ = wv.focus();
                }
            }
        }
        if let Some(wv) = self.entries[i].as_ref() {
            let _ = wv.load_url(url);
            let _ = wv.zoom(zoom);
            self.touch(i);
        }
    }

    pub fn with_entry(&mut self, i: usize, f: impl FnOnce(&WebView)) {
        if let Some(Some(wv)) = self.entries.get(i) {
            f(wv);
        }
    }

    /// Iterator mọi webview đang sống (cho layout + turbo).
    pub fn alive(&self) -> impl Iterator<Item = &WebView> {
        self.entries.iter().flatten()
    }

    /// Webview sống của tab i (nếu có).
    pub fn alive_webview(&self, i: usize) -> Option<&WebView> {
        self.entries.get(i).and_then(|e| e.as_ref())
    }

    /// Đảm bảo tab ACTIVE có webview sống + visible + focus.
    /// Dùng sau mọi thay đổi cấu trúc (nav/new/close/switch).
    pub fn ensure_active_ready(
        &mut self,
        zoom: f64,
        factory: &mut dyn FnMut(usize, Option<&str>, f64) -> Result<WebView, String>,
    ) -> bool {
        let i = self.active;
        if self.entries[i].is_some() {
            return true;
        }
        if !self.ensure_webview(i, zoom, factory) {
            return false;
        }
        if let Some(wv) = self.entries[i].as_ref() {
            let _ = wv.set_visible(true);
            let _ = wv.focus();
            let _ = wv.zoom(zoom);
        }
        true
    }

    pub fn apply_zoom(&mut self, i: usize, z: f64) {
        self.with_entry(i, |wv| {
            let _ = wv.zoom(z);
        });
    }

    pub fn set_title(&mut self, i: usize, t: &str) {
        if i < self.tabs.len() && !t.is_empty() {
            self.tabs[i].title = t.to_string();
        }
    }

    pub fn set_url(&mut self, i: usize, u: &str) {
        if i < self.tabs.len() {
            self.tabs[i].url = Some(u.to_string());
        }
    }

    /// TURBO: dọn browsing data mọi tab sống -> trả cache/RAM về OS.
    pub fn clear_browsing_data_all(&mut self) -> usize {
        let mut n = 0;
        for e in self.entries.iter_mut().flatten() {
            if e.clear_all_browsing_data().is_ok() {
                n += 1;
            }
        }
        n
    }

    #[cfg(any(debug_assertions, feature = "devtools"))]
    pub fn open_devtools(&mut self, i: usize) {
        self.with_entry(i, |wv| wv.open_devtools());
    }

    #[cfg(not(any(debug_assertions, feature = "devtools")))]
    pub fn open_devtools(&mut self, _i: usize) {}

    /// URL hiển thị của tab đang active (cho thanh địa chỉ).
    pub fn active_url(&self) -> Option<String> {
        self.tabs.get(self.active).and_then(|t| t.url.clone())
    }

    /// Dữ liệu cho render tab bar: [{title,url}...], active, url active.
    pub fn view_model(&self) -> serde_json::Value {
        serde_json::json!({
            "tabs": self.tabs.iter().map(|t| serde_json::json!({
                "title": if t.title.is_empty() {
                    t.url.as_deref()
                        .map(|u| u.split("//").nth(1).unwrap_or(u)
                            .split('/').next().unwrap_or(u).to_string())
                        .unwrap_or_else(|| "Speed Dial".into())
                } else { t.title.clone() },
                "url": t.url,
            })).collect::<Vec<_>>(),
            "active": self.active,
            "url": self.active_url(),
            "turbo": self.turbo,
        })
    }
}

// ================= TEST =================
#[cfg(test)]
mod tests {
    use super::*;

    // TabManager có WebView (!Send) — nhưng các hàm meta thuần vẫn test được
    // bằng cách không tạo webview (entries = None).
    #[test]
    fn insert_close_giu_invariant() {
        let mut tm = TabManager::new(None);
        assert_eq!(tm.tabs.len(), 1);
        assert_eq!(tm.entries.len(), 1);

        let i = tm.insert_after(0, Some("https://a.b".into()));
        assert_eq!(i, 1);
        assert_eq!(tm.tabs.len(), 2);
        assert_eq!(tm.entries.len(), 2, "entries phải cùng độ dài tabs");

        tm.close(0);
        assert_eq!(tm.tabs.len(), 1);
        assert_eq!(tm.entries.len(), 1);
        assert_eq!(tm.active, 0);
    }

    #[test]
    fn close_het_tab_tao_dial() {
        let mut tm = TabManager::new(Some("https://x.y".into()));
        tm.close(0);
        assert_eq!(tm.tabs.len(), 1);
        assert!(tm.tabs[0].url.is_none(), "phải rơi về Speed Dial");
    }

    #[test]
    fn close_ngoai_range_khong_panic() {
        let mut tm = TabManager::new(None);
        let _ = tm.close(99);
        assert_eq!(tm.tabs.len(), 1);
    }

    #[test]
    fn set_title_set_url_gioi_han_dung() {
        let mut tm = TabManager::new(None);
        tm.set_title(0, "Steam");
        assert_eq!(tm.tabs[0].title, "Steam");
        tm.set_url(0, "https://store.steampowered.com");
        assert_eq!(tm.active_url().as_deref(), Some("https://store.steampowered.com"));
        tm.set_title(42, "ngoài range"); // không panic
    }

    #[test]
    fn view_model_co_du_field() {
        let mut tm = TabManager::new(Some("https://github.com".into()));
        tm.set_title(0, "GitHub");
        let v = tm.view_model();
        assert_eq!(v["active"], 0);
        assert_eq!(v["url"], "https://github.com");
        assert_eq!(v["tabs"][0]["title"], "GitHub");
        assert_eq!(v["turbo"], false);
    }

    #[test]
    fn navigate_ngoai_range_khong_panic() {
        let mut tm = TabManager::new(None);
        let mut calls = 0usize;
        let mut factory = |_tab: usize, _u: Option<&str>, _z: f64| -> Result<WebView, String> {
            calls += 1;
            Err("không thể tạo trong test".into())
        };
        tm.navigate(9, "https://a.b", 1.0, &mut factory);
        assert_eq!(calls, 0, "tab ngoài range không được gọi factory");
    }

    #[test]
    fn max_tabs_la_24() {
        assert_eq!(MAX_TABS, 24);
        assert!(MAX_ALIVE <= MAX_TABS);
    }
}
