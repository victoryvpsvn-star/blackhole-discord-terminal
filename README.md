# BLACKHOLE v2.1 — Discord Terminal siêu nhẹ (100% Rust)

Giao diện full-screen kiểu **discordo** · **xem ảnh ngay trong terminal** · **đăng nhập email + password** · **TRÌNH DUYỆT ẨN tự bắt captcha** (trang xác minh phong cách Discord, bạn chỉ tự bấm — không dán tay) · **/voice mượn browser vào voice** · realtime gateway · reply / edit / delete.

> Nhẹ thật, nhẹ từ trong xương: binary **~2.4 MB**, RAM đỉnh **~ vài MB** — máy **1 GB RAM** vẫn chạy mượt. Không tokio, không ratatui, không openssl, không nhúng web engine nào cả.

---

## Tải nhanh

- Nhấn **★ Star** rồi vào tab **Actions** → chọn build mới nhất → tải `blackhole-<hệ>.zip` (CI tự gửi file về Discord qua webhook luôn).
- Build sẵn cho: **Linux x64 (musl static)** · Linux x86 · Windows x64 · Windows x86.

```bash
# Linux/macOS
chmod +x blackhole && ./blackhole

# Windows
blackhole.exe
```

## Chạy phát hiểu ngay (không cần tài khoản)

```bash
./blackhole --demo     # xem giao diện với dữ liệu giả
./blackhole --plain    # nếu thích chế độ dòng lệnh kiểu cũ
```

---

## Đăng nhập

Mở app lên sẽ có menu:

```
1) Email + mật khẩu  (gặp captcha: mở TRÌNH DUYỆT ẨN phong cách
    Discord — bạn tự bấm, terminal tự bắt kết quả tiếp tục)
2) Dán token trực tiếp (user token, hoặc 'Bot xxx' cho bot)
```

### Cách 1 — Email + mật khẩu
1. Nhập email → mật khẩu (ký tự hiện `*`, không hiện mật khẩu thật).
2. Có **2FA** thì nhập mã 6 số (hoặc mã dự phòng).
3. **Discord hỏi captcha?** Terminal bật **TRÌNH DUYỆT ẨN**:
   - Tự sinh 1 trang xác minh **mang giao diện Discord** (dark + blurple) chứa widget
     hCaptcha với **sitekey thật** Discord trả về, chạy tại `http://127.0.0.1:<port>` cục bộ,
   - **Tự mở trình duyệt** của máy tới trang đó (không thấy thì copy link in trên màn hình),
   - Bạn **tự bấm** giải captcha → trang **tự gửi kết quả về terminal** →
     terminal **tự đăng nhập tiếp — KHÔNG cần dán tay**.
   - Cách chắc chắn 100% vẫn luôn sẵn trong trang (mục thu gọn) và gõ `h` trong terminal:
     đăng nhập `discord.com/login` trên trình duyệt → F12 lấy token → dán vào terminal hoặc
     dán vào ô dự phòng trên trang — kết quả vẫn tự chảy về terminal.
4. Đăng nhập xong token được lưu vào `~/.blackhole/config` (chmod 600) — lần sau mở phát vào luôn. Muốn xoá: `/logout`.

> ⚠️ **Cảnh báo thẳng thắn:** dùng tài khoản cá nhân (user account) qua app bên thứ 3 vi phạm ToS Discord, có thể bị khóa tài khoản. Cân nhắc trước khi dùng — app không tự giải captcha, trang xác minh chỉ chạy cục bộ 127.0.0.1 để bạn tự bấm, không can thiệp gì ngoài đăng nhập chính chủ bằng chính mật khẩu của bạn.

### TRÌNH DUYỆT ẨN hoạt động thế nào?

```
Discord trả captcha_sitekey (+ rqdata)
      ▼
Terminal tự sinh trang "Discord • Xác minh bảo mật" (ngụy trang Discord thật)
      ▼
Local server 127.0.0.1 (std::net — 0 deps) + tự mở trình duyệt của máy
      ▼
Bạn tự bấm captcha → JS trang tự POST kết quả về 127.0.0.1
      ▼
Terminal TỰ BẮT token → gửi lại /auth/login → vào app
```

Server chỉ nghe **127.0.0.1**, sống tối đa **6 phút**, nhận xong là đóng, không ghi token ra đĩa, không log. Bridge lỗi/hết giờ thì tự rơi về cách dán tay v2.0 — không bao giờ kẹt.

### VOICE — vì sao cần mượn trình duyệt?

Voice thật cần WebRTC + UDP + Opus: nhúng vào binary thì nặng thêm vài MB, xài thêm RAM — ngược cả với mục tiêu "nhẹ". Nên v2.1 chọn cách khôn ngoan:

- Gõ **`/voice`** khi đang trong server (hoặc `/voice <channel_id>`), terminal đọc loại kênh + guild_id rồi **tự mở trình duyệt** vào đúng kênh voice/stage của Discord web.
- Voice chạy 100% trên browser (mic + âm thanh của máy bạn lo), terminal vẫn chat realtime song song — gateway không ngắt.
- Kênh không phải voice/stage thì terminal báo rõ, không mở lung tung.

### Cách 2 — Token
Dán thẳng token user, hoặc `Bot xxx` (nhớ bật **MESSAGE CONTENT INTENT** trong Developer Portal nếu dùng bot).

---

## Giao diện đầy đủ (mặc định)

```
┌─────────────────────────────────────────────────────────────┐
│ BLACKHOLE v2.1 • tên bạn • #kênh-đang-mở                    │
│ SERVER            │  [12] 09:45 Huy dev                     │
│  1 Blackhole Corp │  : anh em ơi v2 lên đồ rồi nè           │
│  2 Gaming VN      │  [11] 09:44 Trang                       │
│                   │  : giao diện nay đẹp ra đó               │
│ KÊNH              │  [10] 09:40 bot-dank                    │
│ ● #general        │  : [ảnh: meme.png 800x600]              │
│   #dev            │                                         │
│   #memes          │                                         │
│ ┌─ nhập tin nhắn ─┐│                                         │
│ │ > xin chào▌     ││                                         │
│ └─────────────────┘│                                         │
│ #general • ● online                    ← thông báo           │
└─────────────────────────────────────────────────────────────┘
```

| Phím | Tác dụng |
|------|----------|
| gõ chữ + Enter | gửi tin nhắn (ô nhập luôn sẵn sàng) |
| **Tab** | chuyển ô: nhập → SERVER → KÊNH → nhập |
| ↑/↓ + **Enter** (cột trái) | chọn server / chọn kênh |
| ↑/↓ (ô nhập trống) | cuộn tin nhắn cũ/mới · PageUp/PageDown cuộn nhanh |
| ↑/↓ (ô nhập có chữ) | gọi lại tin đã gửi trước đó |
| Backspace/←/→/Home/End/Ctrl+U | sửa dòng nhập |
| Esc | đóng overlay / xoá ô nhập |
| Ctrl+C | thoát (dọn terminal sạch sẽ) |

## Lệnh

| Lệnh | Tác dụng |
|------|----------|
| gõ text thường | gửi tin nhắn |
| `/guilds` `/channels [số]` `/dms` | liệt kê server / kênh / DM |
| `/go <số\|id\|dN>` | vào kênh (vd `/go 2`, `/go d1`) |
| `/voice [id]` | **MƯỢN TRÌNH DUYỆT vào voice/stage** (không id = kênh đang đứng) |
| `/m <nội dung>` | gửi tin nhắn |
| `/r <số> <nội dung>` | **REPLY** tin số `<số>` (tin mới nhất = 1) |
| `/e <số> <nội dung>` | **SỬA** tin nhắn của bạn |
| `/d <số>` | **XÓA** tin nhắn |
| `/img <số> [k]` | **XEM ẢNH NGAY TRONG TERMINAL** (k = ảnh thứ k nếu nhiều file) |
| `/save <số> [k]` | tải file gốc về `~/.blackhole/downloads/` |
| `/open <số> [k]` | tải + mở bằng app xem file của máy |
| `/more` `/history` | nạp 20 tin cũ hơn / nạp lại tin mới |
| `/typing` `/id <số>` `/me` `/clear` | tiện ích |
| `/logout` | xoá token đã lưu khỏi máy |
| `/help` | mở bảng lệnh + phím tắt (overlay) |
| `/quit` | thoát |

## Xem ảnh trong terminal

Tin nhắn có ảnh sẽ hiện `[ảnh: meme.png 800x600]`. Gõ `/img <số tin>`:

- App tải ảnh về → thu nhỏ vừa khung → vẽ bằng ký tự half-block `▀` với **màu truecolor 24-bit** — xem ngay trong terminal, không cần mở gì.
- GIF lấy frame đầu. Hỗ trợ **png / jpg / gif / webp**.
- Ảnh quá lớn (> 30MP) hoặc file > 50MB → chặn an toàn, dùng `/save` hoặc `/open` thay thế.
- Terminal không hỗ trợ truecolor cũ quá thì ảnh vẫn ra (màu có thể lệch nhẹ) — hoặc dùng `/save`.

## Tuỳ chọn chạy

| Tham số | Tác dụng |
|---------|----------|
| `--login` | ép đăng nhập lại bằng email + password |
| `--token <token>` | vào thẳng bằng token |
| `--bot` | nhận diện token là bot |
| `--save` | lưu token vào config |
| `--demo` | xem giao diện, dữ liệu giả, không cần tài khoản |
| `--plain` | chế độ dòng lệnh cũ (hợp khi dùng pipe/script) |
| `BLACKHOLE_TZ=7` | múi giờ hiển thị (mặc định +7 Việt Nam) |

## Tự build

```bash
cargo build --release          # bản cho máy bạn
cargo test                     # unit test (render ảnh, format size...)
```

Kích thước nhỏ nhờ: `opt-level="z"` + LTO + `codegen-units=1` + `panic="abort"` + strip; deps chỉ có `ureq`/`tungstenite` (rustls) + `serde_json` + `crossterm` (raw mode & phím) + `image` (chỉ 4 codec png/jpg/gif/webp). CI build thêm bản **Linux musl static** — mở chạy mọi distro không cần cài gì.

## CI/CD (tự động)

1 workflow duy nhất (`build.yml`): build đủ **5 target** → zip + sha256 → **tự gửi về Discord qua webhook** (kèm embed xanh/đỏ theo kết quả). Sửa webhook trong file workflow hoặc chuyển sang secret `DISCORD_WEBHOOK`.

## Kiến trúc (ai tò mò)

```
main.rs   — vòng lặp chính (mpsc) + auth flow + 2 chế độ UI
bridge.rs — TRÌNH DUYỆT ẨN: local server 0-dep + trang xác minh
            Discord-style + tự bắt kết quả captcha
voice     — /voice trong main.rs: mượn browser vào voice/stage
tui.rs    — giao diện full-screen (crossterm raw + ANSI tự vẽ, không ratatui)
gw.rs     — thread gateway WebSocket (heartbeat + tự nối lại khi rớt)
api.rs    — REST ureq+rustls (chống 429, parse tin nhắn + đính kèm)
login.rs  — POST /auth/login · /auth/mfa/totp · captcha qua bridge + fallback
img.rs    — tải/decode/vẽ ảnh half-block truecolor · /save · /open
```

Xem `plan.md` — kế hoạch dự án cấp công ty: đội hình 300 agent (10 squad coder), spec trình duyệt ẩn + voice bridge (mục 11), checklist bug-finder 34+12 mục, tiêu chí nghiệm thu.

## Known issues

- hCaptcha có thể từ chối sitekey khi chạy trên domain `127.0.0.1` (sitekey khóa theo domain) — khi đó trang xác minh hiện lỗi: dùng mục **cách chắc chắn 100%** ngay trong trang (F12 lấy token → dán vào ô dự phòng → terminal vẫn tự nhận), hoặc dán tay vào terminal như v2.0.
- `/voice` cần trình duyệt đã đăng nhập Discord web; mic/âm thanh do browser lo — terminal không truyền tiếng (v2.2 mới cân nhắc WebRTC).
- Ảnh truecolor cần terminal hiện đại (Windows Terminal, iTerm2, GNOME Terminal, Kitty...); cmd/PowerShell cũ có thể hiển thị lệch màu.
- Cuộn bằng chuột chưa hỗ trợ (dùng ↑↓/PageUp/PageDown).
- Dán chuỗi nhiều dòng vào ô nhập: chỉ lấy ký tự (bỏ xuống dòng).
- Nếu gateway rớt, tin nhắn trong lúc rớt sẽ thiếu → `/history` để nạp lại.

## License
MIT — dùng thoải mái. Đừng quên: user token = rủi ro ToS, tự chịu trách nhiệm nhé.
