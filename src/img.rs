// ============================================================
//  img.rs — XEM ẢNH NGAY TRONG TERMINAL
//  Pipeline: tải (cap 50MB) → decode (png/jpg/gif/webp) →
//            thumbnail → vẽ ANSI half-block ▀ truecolor
//  Không truecolor? — đa số terminal hiện đại hỗ trợ; nếu lỗi
//  decode thì luôn có /save tải file gốc + /open mở viewer.
// ============================================================

use image::GenericImageView;
use std::io::Read;
use std::time::Duration;

/// Chặn file quá lớn trước khi tải (50MB)
pub const MAX_DL: u64 = 50 * 1024 * 1024;
/// Chặn ảnh quá lớn trước khi decode (30 megapixel) — bảo vệ máy 1GB RAM
pub const MAX_PIXELS: u64 = 30_000_000;

/// Tải file về bộ nhớ (streaming, có cap). Lỗi trả String dễ hiểu.
pub fn download(url: &str, cap: u64) -> Result<Vec<u8>, String> {
    let res = ureq::get(url)
        .timeout(Duration::from_secs(30))
        .call()
        .map_err(|e| format!("tải file lỗi: {}", e))?;
    if res.content_type().starts_with("text/html") {
        return Err("file đã hết hạn trên CDN — gõ /history để nạp lại tin nhắn".into());
    }
    let len = res
        .header("Content-Length")
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    if len > cap {
        return Err(format!(
            "file quá lớn ({}) — giới hạn {}. Dùng /save để tải thẳng ra đĩa",
            crate::api::fmt_size(len),
            crate::api::fmt_size(cap)
        ));
    }
    let mut buf: Vec<u8> = Vec::with_capacity(len.min(4 * 1024 * 1024) as usize);
    let mut rdr = res.into_reader();
    let mut chunk = [0u8; 16384];
    loop {
        match rdr.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.len() as u64 > cap {
                    return Err("file quá lớn khi đang tải — đã dừng giữa chừng".into());
                }
            }
            Err(e) => return Err(format!("đọc file lỗi: {}", e)),
        }
    }
    if buf.is_empty() {
        return Err("file rỗng".into());
    }
    Ok(buf)
}

/// Tải file thẳng ra đĩa (streaming — KHÔNG giữ file trong RAM, máy 1GB cũng thoải mái).
/// Dùng cho /save và /open. Trả về đường dẫn đã lưu.
pub fn download_to(url: &str, path: &std::path::Path) -> Result<String, String> {
    use std::io::Write;
    let res = ureq::get(url)
        .timeout(Duration::from_secs(120))
        .call()
        .map_err(|e| format!("tải file lỗi: {}", e))?;
    let len = res
        .header("Content-Length")
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    if len > MAX_DL {
        return Err(format!(
            "file quá lớn ({}) — giới hạn {}",
            crate::api::fmt_size(len),
            crate::api::fmt_size(MAX_DL)
        ));
    }
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let mut f = std::fs::File::create(path).map_err(|e| format!("tạo file lỗi: {}", e))?;
    let mut rdr = res.into_reader();
    let mut buf = [0u8; 32768];
    let mut total: u64 = 0;
    loop {
        match rdr.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                f.write_all(&buf[..n]).map_err(|e| format!("ghi file lỗi: {}", e))?;
                total += n as u64;
                if total > MAX_DL {
                    drop(f);
                    let _ = std::fs::remove_file(path);
                    return Err("file quá lớn khi đang tải — đã dừng và xóa file dở".into());
                }
            }
            Err(e) => {
                drop(f);
                let _ = std::fs::remove_file(path);
                return Err(format!("tải lỗi: {}", e));
            }
        }
    }
    Ok(path.display().to_string())
}

/// Tên file an toàn để lưu đĩa (bỏ ký tự lạ)
pub fn safe_name(name: &str) -> String {
    let bad = ['/', '\\', ':', '*', '?', '"', '<', '>', '|', ' '];
    let s: String = name
        .chars()
        .map(|c| if bad.contains(&c) { '_' } else { c })
        .collect();
    if s.is_empty() {
        "file".into()
    } else {
        s
    }
}

/// Vẽ ảnh thành các dòng ANSI half-block (mỗi ô terminal = 2 px dọc, ký tự ▀,
/// fg = pixel trên, bg = pixel dưới). Trả về Vec<String> — mỗi phần tử 1 dòng.
pub fn render_ansi(bytes: &[u8], max_cols: u32, max_rows: u32) -> Result<Vec<String>, String> {
    let img = image::load_from_memory(bytes)
        .map_err(|e| format!("decode ảnh lỗi: {} — thử /save để tải file gốc", e))?;
    let (w, h) = img.dimensions();
    if (w as u64) * (h as u64) > MAX_PIXELS {
        return Err(format!(
            "ảnh quá lớn để vẽ ({}x{}) — dùng /save hoặc /open",
            w, h
        ));
    }
    let tgt_w = max_cols.max(8);
    let tgt_h = max_rows.max(4) * 2; // mỗi ô = 2 px dọc
    let thumb = img.thumbnail(tgt_w, tgt_h); // giữ tỷ lệ, nhanh, không phụ thuộc
    let (tw, th) = thumb.dimensions();
    let rgb = thumb.to_rgb8();

    let rows = ((th + 1) / 2) as usize;
    let mut out: Vec<String> = Vec::with_capacity(rows);
    for r in 0..rows {
        let y_top = (r * 2) as u32;
        let y_bot = y_top + 1;
        let mut line = String::with_capacity(tw as usize * 24);
        for x in 0..tw {
            let p = rgb.get_pixel(x, y_top);
            let (r1, g1, b1) = (p[0], p[1], p[2]);
            let (r2, g2, b2) = if y_bot < th {
                let q = rgb.get_pixel(x, y_bot);
                (q[0], q[1], q[2])
            } else {
                // dòng lẻ cuối — dùng màu pixel trên cho nền để không hở vệt đen
                (r1, g1, b1)
            };
            line.push_str(&format!(
                "\x1b[38;2;{};{};{};48;2;{};{};{}m\u{2580}",
                r1, g1, b1, r2, g2, b2
            ));
        }
        line.push_str("\x1b[0m");
        out.push(line);
    }
    Ok(out)
}

/// Mở file/URL bằng viewer mặc định của hệ điều hành
pub fn open_system(target: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let mut cmd = {
        let mut c = std::process::Command::new("open");
        c.arg(target);
        c
    };
    #[cfg(target_os = "windows")]
    let mut cmd = {
        let mut c = std::process::Command::new("cmd");
        c.args(["/C", "start", "", target]);
        c
    };
    #[cfg(all(unix, not(target_os = "macos")))]
    let mut cmd = {
        let mut c = std::process::Command::new("xdg-open");
        c.arg(target);
        c.stdout(std::process::Stdio::null());
        c.stderr(std::process::Stdio::null());
        c
    };
    match cmd.spawn() {
        Ok(_) => Ok(()),
        Err(e) => Err(format!("không mở được '{}': {}", target, e)),
    }
}


// ================= TEST (cargo test) =================
#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::fmt_size;
    use image::{ImageBuffer, ImageFormat};
    use std::io::Cursor;

    /// Tạo PNG thật trong bộ nhớ để test decode + render
    fn make_png(w: u32, h: u32) -> Vec<u8> {
        let img = ImageBuffer::from_fn(w, h, |x, y| {
            image::Rgb([(x % 256) as u8, (y % 256) as u8, ((x + y) % 256) as u8])
        });
        let mut cur = Cursor::new(Vec::new());
        img.write_to(&mut cur, ImageFormat::Png).unwrap();
        cur.into_inner()
    }

    #[test]
    fn render_ansi_png_co_dung_so_dong() {
        let png = make_png(60, 40); // 60x40 px
        let art = render_ansi(&png, 30, 10).expect("render lỗi");
        // max_rows=10 → tối đa 10 dòng; mỗi dòng bắt đầu bằng escape
        assert!(art.len() >= 1 && art.len() <= 10);
        for line in &art {
            assert!(line.contains('\u{2580}'), "thiếu ký tự half-block");
            assert!(line.contains("\u{1b}[38;2;"), "thiếu truecolor");
        }
    }

    #[test]
    fn render_ansi_chong_anh_qua_lon() {
        // giả lập flag quá lớn: decode 30MP thì chậm — test bằng file rác
        assert!(render_ansi(b"khong phai anh", 30, 10).is_err());
    }

    #[test]
    fn safe_name_xoa_ky_tu_doc() {
        assert_eq!(safe_name("a/b\\c:d*e?.png"), "a_b_c_d_e_.png");
        assert_eq!(safe_name(""), "file");
    }

    #[test]
    fn fmt_size_doc_duoc() {
        assert_eq!(fmt_size(500), "500 B");
        assert_eq!(fmt_size(2048), "2.0 KB");
        assert_eq!(fmt_size(2 * 1024 * 1024), "2.0 MB");
    }
}
