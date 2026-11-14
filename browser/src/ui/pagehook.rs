// pagehook.rs — init script bắn vào MỌI trang web trong webview nội dung.
//
// v2.0: title đã có native handler (with_document_title_changed_handler —
// event thật của WebView2, không polling). Script này chỉ còn nhiệm vụ
// báo URL (location.href) + tab id để TabManager cập nhật đúng tab.
//
// Nhẹ: interval 400ms, chỉ 1 so sánh chuỗi khi không đổi gì.
// Dùng .replace() thay format! — CSS/JS chứa dấu {} thoải mái.

pub fn pagehook(tab_id: usize) -> String {
    let tpl = r#"
var __bhTab = @@TAB@@;
var __bhU = null;
setInterval(function(){
  try{
    var u = location.href || '';
    if(u && u !== __bhU){
      __bhU = u;
      window.ipc.postMessage(JSON.stringify({cmd:'url', tab:__bhTab, v:u}));
    }
  }catch(e){}
}, 400);
"#;
    tpl.replace("@@TAB@", &tab_id.to_string())
}

#[cfg(test)]
mod tests {
    #[test]
    fn hook_chua_tab_id() {
        let js = super::pagehook(7);
        assert!(js.contains("__bhTab = 7"));
        assert!(js.contains("postMessage"));
        assert!(js.contains("cmd:'url'"));
        assert!(!js.contains("@@"), "còn placeholder chưa thay");
    }

    #[test]
    fn hook_tab_0_va_tab_99() {
        assert!(super::pagehook(0).contains("__bhTab = 0"));
        assert!(super::pagehook(99).contains("__bhTab = 99"));
    }
}
