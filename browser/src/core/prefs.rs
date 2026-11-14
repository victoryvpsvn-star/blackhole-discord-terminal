// prefs.rs — tầng PREFS: cấu hình người dùng, lưu JSON thủ công
// (không thêm dependency serde-derive — giữ crate gọn).
//
// File: <home>/.blackhole-browser/prefs.json
//
// {
//   "search_engine": "google",      // google | bing | duckduckgo
//   "homepage":      "blackhole://start",
//   "zoom":          1.0,
//   "turbo":         false
// }
//
// Tìm kiếm bằng GOOGLE mặc định (yêu cầu chủ dự án — đừng duckduckgo).

use std::fs;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq)]
pub struct Prefs {
    pub search_engine: String,
    pub homepage: String,
    pub zoom: f64,
    pub turbo: bool,
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs {
            search_engine: "google".into(), // GOOGLE là mặc định
            homepage: "blackhole://start".into(),
            zoom: 1.0,
            turbo: false,
        }
    }
}

/// Thư mục profile RIÊNG của Blackhole (không đụng Edge/Chrome/Opera).
pub fn profile_dir() -> PathBuf {
    let home = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".blackhole-browser")
}

fn prefs_file() -> PathBuf {
    profile_dir().join("prefs.json")
}

/// URL tìm kiếm theo engine đang chọn.
pub fn search_url(engine: &str, query: &str) -> String {
    let q = urlencode(query);
    match engine {
        "bing" => format!("https://www.bing.com/search?q={}", q),
        "duckduckgo" => format!("https://duckduckgo.com/?q={}", q),
        // GOOGLE — mặc định
        _ => format!("https://www.google.com/search?q={}", q),
    }
}

/// Quyết định URL bar là link hay câu tìm kiếm:
/// có dấu chấm + không khoảng trắng + không scheme -> coi là domain.
pub fn url_or_search(input: &str, engine: &str) -> String {
    let v = input.trim();
    if v.is_empty() {
        return search_url(engine, v);
    }
    let looks_like_url = (v.starts_with("http://")
        || v.starts_with("https://")
        || v.starts_with("blackhole://")
        || v.starts_with("file://")
        || (v.contains('.') && !v.contains(' ') && !v.ends_with('.')))
        && !v.contains("..//");
    if looks_like_url {
        if v.starts_with("http://")
            || v.starts_with("https://")
            || v.starts_with("blackhole://")
            || v.starts_with("file://")
        {
            v.to_string()
        } else {
            format!("https://{}", v)
        }
    } else {
        search_url(engine, v)
    }
}

/// Encode query an toàn cho URL (đủ dùng cho tìm kiếm).
pub fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

impl Prefs {
    /// Parse từ chuỗi JSON (public để test được không phụ thuộc đĩa).
    pub fn load_from_str(text: &str) -> Self {
        let mut p = Prefs::default();
        let Ok(v) = serde_json::from_str::<serde_json::Value>(text) else {
            return p;
        };
        if let Some(x) = v.get("search_engine").and_then(|x| x.as_str()) {
            p.search_engine = x.to_string();
        }
        if let Some(x) = v.get("homepage").and_then(|x| x.as_str()) {
            p.homepage = x.to_string();
        }
        if let Some(x) = v.get("zoom").and_then(|x| x.as_f64()) {
            if (0.25..=5.0).contains(&x) {
                p.zoom = x;
            }
        }
        if let Some(x) = v.get("turbo").and_then(|x| x.as_bool()) {
            p.turbo = x;
        }
        p
    }

    /// Đọc prefs từ đĩa; hỏng/thiếu thì trả default (không panic).
    pub fn load() -> Self {
        match std::fs::read_to_string(prefs_file()) {
            Ok(text) => Prefs::load_from_str(&text),
            Err(_) => Prefs::default(),
        }
    }

    /// Ghi prefs — tạo thư mục nếu thiếu; lỗi thì bỏ qua im lặng.
    pub fn save(&self) {
        let dir = profile_dir();
        let _ = fs::create_dir_all(&dir);
        let v = serde_json::json!({
            "search_engine": self.search_engine,
            "homepage": self.homepage,
            "zoom": self.zoom,
            "turbo": self.turbo,
        });
        let _ = fs::write(prefs_file(), serde_json::to_string_pretty(&v).unwrap_or_default());
    }
}

// ================= TEST (cargo test — chạy trên CI Linux) =================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_la_google() {
        let p = Prefs::default();
        assert_eq!(p.search_engine, "google");
        assert!(search_url("google", "máy chủ rust").contains("google.com/search?q="));
        assert!(search_url("google", "a b").contains("+"));
    }

    #[test]
    fn url_or_search_phan_loai_dung() {
        assert_eq!(url_or_search("github.com", "google"), "https://github.com");
        assert_eq!(url_or_search("https://a.b/c", "google"), "https://a.b/c");
        assert_eq!(url_or_search("blackhole://start", "google"), "blackhole://start");
        assert!(url_or_search("phím tắt windows", "google").contains("google.com"));
        assert!(url_or_search("rust vs go 2026", "google").contains("google.com"));
    }

    #[test]
    fn urlencode_dung() {
        assert_eq!(urlencode("rust & go"), "rust+%26+go");
        assert_eq!(urlencode("ABC-abc_123.~"), "ABC-abc_123.~");
        assert_eq!(urlencode("ế"), "%E1%BA%BF");
    }

    #[test]
    fn prefs_roundtrip() {
        let dir = std::env::temp_dir().join(format!("bh-prefs-test-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let file = dir.join("prefs.json");
        let v = serde_json::json!({
            "search_engine": "bing", "homepage": "https://x.y", "zoom": 1.5, "turbo": true
        });
        fs::write(&file, v.to_string()).unwrap();
        // load bằng path thay thế: mô phỏng bằng đọc thủ công
        let text = fs::read_to_string(&file).unwrap();
        let p = Prefs::load_from_str(&text);
        assert_eq!(p.search_engine, "bing");
        assert_eq!(p.zoom, 1.5);
        assert!(p.turbo);
        let _ = fs::remove_dir_all(dir);
    }
}
