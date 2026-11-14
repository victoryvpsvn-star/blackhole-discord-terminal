// ipc.rs — tầng IPC của BlackholeCore.
//
// Giao thức message JSON một đường duy nhất:
//   {"cmd": "...", "tab": <id>, "v" / "url": ...}
//
// Nguyên tắc chống-deadlock (mọc từ v1.0, giữ lại v2.0):
//   * webview KHÔNG nằm trong Mutex chung với state
//   * mọi IPC callback chỉ ĐẨY string vào Inbox rồi thoát ngay
//   * event loop rút Inbox ở MainEventsCleared + sau mỗi phím bấm
//   * không lock nào được giữ qua lần gọi evaluate_script/load_url

use std::sync::{Arc, Mutex};

/// Inbox toàn cục — chỉ chứa chuỗi JSON thô.
#[derive(Clone)]
pub struct Inbox {
    q: Arc<Mutex<Vec<String>>>,
}

impl Inbox {
    pub fn new() -> Self {
        Inbox { q: Arc::new(Mutex::new(Vec::new())) }
    }

    /// Đẩy 1 message (webview IPC callback gọi hàm này — KHÔNG lock gì khác).
    pub fn push_raw(&self, raw: String) {
        if let Ok(mut q) = self.q.lock() {
            q.push(raw);
        }
    }

    /// Đẩy 1 message dạng JSON đã dựng sẵn.
    pub fn push_json(&self, v: serde_json::Value) {
        self.push_raw(v.to_string());
    }

    /// Rút toàn bộ (event loop gọi).
    pub fn drain(&self) -> Vec<String> {
        match self.q.lock() {
            Ok(mut q) => q.drain(..).collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        match self.q.lock() {
            Ok(q) => q.is_empty(),
            Err(_) => true,
        }
    }
}

/// Cấu trúc message đã parse.
#[derive(Debug, Clone, PartialEq)]
pub struct Msg {
    pub cmd: String,
    pub tab: Option<usize>,
    pub value: String,
}

impl Msg {
    /// Parse 1 chuỗi JSON -> Msg. Sai format -> None (không panic).
    pub fn parse(raw: &str) -> Option<Msg> {
        let v: serde_json::Value = serde_json::from_str(raw).ok()?;
        let cmd = v.get("cmd").and_then(|x| x.as_str())?.to_string();
        let tab = v.get("tab").and_then(|x| x.as_u64()).map(|x| x as usize);
        let value = v
            .get("v")
            .or_else(|| v.get("url"))
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        Some(Msg { cmd, tab, value })
    }
}

// ================= TEST =================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inbox_push_drain() {
        let ib = Inbox::new();
        ib.push_raw("{\"cmd\":\"nav\",\"url\":\"https://a.b\"}".into());
        ib.push_json(serde_json::json!({"cmd": "new"}));
        assert!(!ib.is_empty());
        let got = ib.drain();
        assert_eq!(got.len(), 2);
        assert!(ib.is_empty());
        assert_eq!(ib.drain().len(), 0);
    }

    #[test]
    fn msg_parse_dung() {
        let m = Msg::parse(r#"{"cmd":"nav","url":"https://x.y/z"}"#).unwrap();
        assert_eq!(m.cmd, "nav");
        assert_eq!(m.value, "https://x.y/z");
        assert_eq!(m.tab, None);

        let m = Msg::parse(r#"{"cmd":"title","tab":3,"v":"Steam"}"#).unwrap();
        assert_eq!(m.tab, Some(3));
        assert_eq!(m.value, "Steam");
    }

    #[test]
    fn msg_parse_sai_khong_panic() {
        assert!(Msg::parse("rác không phải json").is_none());
        assert!(Msg::parse("{}").is_none());
        assert!(Msg::parse(r#"{"not":"cmd"}"#).is_none());
    }
}
