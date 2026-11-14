# BLACKHOLE v2.1 — PLAN.md · DỰ ÁN CẤP CÔNG TY

> Tài liệu kế hoạch tổng thể do **300 agent mô phỏng** (100 Coder · 100 Manager · 100 Bug-team)
> cùng suy nghĩ siêu kỹ **trước khi viết 1 dòng code nào**.
> Phiên bản: v2.1.0 · Ngày cập nhật: 14/11/2026 · Ngôn ngữ dự án: Rust (không tokio, không ratatui, không openssl)
>
> **UPDATE v2.1** (yêu cầu chủ dự án): **TRÌNH DUYỆT ẨN** — terminal dùng "browser riêng siêu nhẹ
> dành cho Discord" để tự bắt captcha · **VOICE BRIDGE** — mượn trình duyệt vào được voice ·
> **GITHUB CI/CD** — push repo lên GitHub, Actions build 5 bản tự gửi Discord. Spec chi tiết ở **mục 11**.

---

## 0. TÓM TẮT ĐIỀU HÀNH

v1.1 đã chạy tốt (realtime WS + reply/edit/delete, binary 1.7MB, RAM ~3.6MB) nhưng bị chê:
**UI xấu**, **không xem được ảnh**, **đăng nhập phải dán token**. v2.0 giải quyết hết:

| # | Mục tiêu | Giải pháp đã chốt | KPI nghiệm thu |
|---|----------|-------------------|----------------|
| 1 | **Nhẹ hơn nữa** | build **musl static** (không cần glibc), giữ profile `opt-level=z + lto + strip + panic=abort`, cấm deps nặng | binary ≤ 3.5MB, RAM ≤ 8MB, mở < 0.5s |
| 2 | **Đăng nhập email + password** | module `login.rs` gọi `/auth/login` chính thức của Discord; hỗ trợ **2FA (TOTP/mã dự phòng)** | đăng nhập được không cần dán token |
| 3 | **Captcha: terminal báo → user TỰ BẤM** | KHÔNG tự giải captcha. Terminal in cảnh báo lớn + **tự mở trình duyệt** tới trang captcha Discord (hCaptcha sitekey do Discord trả về) → user tự bấm → dán `captcha_key` vào terminal → gửi lại login | có hướng dẫn fallback lấy token qua trình duyệt |
| 4 | **Xem ảnh trong terminal** | `img.rs`: tải đính kèm → decode (png/jpg/gif/webp) → thu nhỏ → vẽ **ANSI half-block ▀ truecolor**; lỗi thì `/save` tải file gốc; `/open` mở viewer hệ thống | ảnh hiển thị được trong terminal, không crash với ảnh khổng lồ |
| 5 | **UI đẹp kiểu discordo** | `tui.rs`: giao diện **full-screen panel** (cột server/kênh trái, khung tin nhắn phải, ô nhập có viền, status bar, overlay) bằng crossterm + ANSI tự vẽ — **không dùng ratatui** để giữ binary nhỏ | trông giống discordo, chạy mượt trên máy 1GB RAM |
| 6 | **Dễ dùng** | menu đăng nhập, `--demo` xem giao diện không cần tài khoản, `/help` dạng overlay, phím tắt (Tab/Enter/mũi tên/PageUp), giữ nguyên toàn bộ lệnh `/...` | người mới mở phát hiểu ngay |
| 7 | **v2.1 · TRÌNH DUYỆT ẨN** | terminal tự sinh trang xác minh **phong cách Discord** (dark + blurple) chứa widget hCaptcha sitekey THẬT Discord trả về, mở bằng trình duyệt sẵn có của máy, user TỰ BẤM → JS tự POST kết quả về local server `127.0.0.1` (std::net, **0 deps**) → terminal **TỰ BẮT** token, hết dán tay | captcha xong không cần chạm bàn phím; binary tăng < 20KB |
| 8 | **v2.1 · VOICE BRIDGE** | terminal không truyền tiếng (WebRTC quá nặng) → `/voice` đọc type/guild_id của kênh rồi **mượn trình duyệt** mở `discord.com/channels/<guild>/<voice>` — voice chạy 100% trên browser, terminal vẫn chat realtime song song | user "vô được voice" mà không cần mở app Discord riêng |
| 9 | **v2.1 · GITHUB CI/CD** | push repo lên GitHub (PAT của chủ dự án, **KHÔNG commit token vào repo**) → Actions build 5 target → tự gửi zip về Discord webhook như cũ | run Actions xanh đủ 5 artifact + webhook HTTP 200 |

**Nguyên tắc bất di bất dịch:** nhẹ là trên hết. Cấm: tokio, ratatui, openssl, serde derive,
bất kỳ crate nào kéo C library vào ngoài `ring` (TLS).

---

## 1. ĐỘI HÌNH 300 AGENT

### 1.1 — 100 CODER (10 squad — v2.1 mở thêm C9/C10 từ băng dự phòng)

| Squad | Nhân sự | Phạm vi |
|-------|---------|---------|
| C1 · Core | 13 | main.rs: vòng lặp mpsc, State, Auth flow, mode chọn (TUI/line), `--demo`, `--plain` |
| C2 · TUI | 13 | tui.rs: layout, wrap ANSI, sidebar, pane, input box, status bar, overlay |
| C3 · Auth | 13 | login.rs: /auth/login, mfa/totp, captcha manual flow, prompt password không echo |
| C4 · Image | 13 | img.rs: download cap 50MB, decode, thumbnail, half-block truecolor, /save /open |
| C5 · REST | 12 | api.rs: parse attachments (url/w/h/size/content_type), fmt_size, giữ chống 429 |
| C6 · Gateway | 12 | gw.rs: sửa `eprintln!` thành event `NetErr` (không phá màn hình TUI), reconnect |
| C7 · Perf/CI | 12 | profile release, musl static, workflow 5 target, sha256, webhook |
| C8 · Docs | 12 | README, plan.md, help overlay, usage, cảnh báo ToS |
| C9 · Bridge (v2.1) | 13 | bridge.rs: local server 0-dep, trang xác minh Discord-style, tự bắt token, fallback dán tay |
| C10 · Voice (v2.1) | 12 | /voice: đọc type/guild_id, mượn browser vào voice, guide in terminal |

### 1.2 — 100 MANAGER (4 phòng)

| Phòng | Nhân sự | Nhiệm vụ |
|-------|---------|----------|
| M1 · Planning | 25 | chốt spec từng module, dừng mọi code không đúng spec, duyệt milestone |
| M2 · Acceptance | 25 | nghiệm thu theo bảng tiêu chí mục 8 — không đạt thì từ chối bàn giao |
| M3 · Release | 25 | đóng gói zip + sha256, gửi Discord webhook, verify HTTP 200 |
| M4 · Risk/ToS | 25 | rà rủi ro: ToS user-token, không lưu password, không log token, chmod config |

### 1.3 — 100 BUG-TEAM (bug finder · bugfixer · feature)

| Nhóm | Nhân sự | Nhiệm vụ |
|------|---------|----------|
| BF1 · Bug finder tĩnh | 30 | đọc code tìm lỗi logic/edge-case (mục 7) trước khi build |
| BF2 · Bug finder động | 30 | chạy `--demo --smoke`, pty test, line-mode test, thử ảnh to/nhỏ, terminal hẹp |
| BFX · Bugfixer | 20 | sửa và re-test, không được patch "vừa chạy là được" |
| F · Feature suggestion | 20 | đề xuất v2.1 (danh sách cuối plan) |

**Chu trình:** Plan → Code → Review chéo squad → Bug hunt BF1 → Build → Bug hunt BF2 → Fix → Acceptance M2 → Release M3.

---

## 2. KIẾN TRÚC v2.0

```
┌────────────────────────────────────────────────────────────────┐
│                        blackhole (1 process)                   │
│                                                                │
│  main.rs ──── vòng lặp chính (mpsc)                            │
│    │  ├─ tui.rs   (màn hình full-screen, đọc phím crossterm)   │
│    │  └─ line.rs-mode (chế độ dòng lệnh cũ khi không phải tty) │
│    │                                                           │
│    ├─ gw.rs ─── thread "blackhole-gateway": WebSocket realtime │
│    │            MESSAGE_CREATE/UPDATE/DELETE → Ev              │
│    ├─ api.rs ── REST ureq+rustls, chống 429, parse msg+atts    │
│    ├─ login.rs  POST /auth/login · /auth/mfa/totp · captcha    │
│    └─ img.rs    tải/decode/vẽ ảnh ANSI · mở viewer hệ thống    │
└────────────────────────────────────────────────────────────────┘
```

**Event enum (mở rộng):**
```rust
pub enum Ev {
    Line(String),              // người dùng gõ (chế độ line)
    New(u64, DiscordMsg),      // tin mới
    Edited(u64, u64, String),  // tin sửa
    Deleted(u64, u64),         // tin xóa
    NetErr(String),            // MỚI: lỗi gateway → hiện notice, KHÔNG eprintln (phá TUI)
}
```

**Output của mọi lệnh (mới):**
```rust
pub enum Out {
    Text(String),                              // notice 1 dòng
    Overlay { title: String, lines: Vec<String> }, // /help, /img → overlay TUI
}
pub enum Act { Continue, Quit }                // /quit trả Quit → UI tự dọn dẹp terminal
```
Một `handle_line()` dùng chung cho 2 chế độ UI — hết trùng code, hết lệch hành vi.

---

## 3. SPEC ĐĂNG NHẬP EMAIL + PASSWORD (+ 2FA + CAPTCHA)

### 3.1 Luồng chính
```
Email + mật khẩu (nhập password KHÔNG echo, hiện '*')
        │
        ▼
POST https://discord.com/api/v9/auth/login
     {"email":..., "password":..., "undelete":false}
        │
        ├─ có "token" ──────────────► lưu config, vào app
        ├─ "mfa": true + "ticket" ──► hỏi mã 2FA (6 số / mã dự phòng)
        │                              POST /auth/mfa/totp {"code","ticket"} → token (sai thử lại ≤3)
        ├─ "captcha_key" (hCaptcha) ► CHUYỀN CAPTCHA (mục 3.2)
        └─ lỗi khác ───────────────► in "message" từ Discord, cho thử lại
```

### 3.2 CAPTCHA — triết lý: **không tự giải, user tự bấm** (đúng yêu cầu, đúng luật)
1. Terminal in khung cảnh báo lớn: `DISCORD YÊU CẦU XÁC MINH CAPTCHA (hcaptcha)`.
2. Lấy `captcha_sitekey` Discord trả về → tạo link
   `https://accounts.hcaptcha.com/demo?sitekey=<sitekey>` → **tự mở trình duyệt**
   (`xdg-open` / `start` / `open`) + in link ra màn hình để user tự bấm nếu muốn.
3. User giải puzzle → copy chuỗi token → **dán vào terminal** → gửi lại
   `POST /auth/login` kèm `"captcha_key": <đã dán>` (thử lại ≤4 lần).
4. Nếu user dán thứ trông giống **token Discord trực tiếp** (dài, có dấu chấm) → dùng token luôn, khỏi login lại.
5. Fallback (gõ `h`): hướng dẫn đăng nhập `discord.com/login` trên trình duyệt (giải captcha trong đó),
   rồi F12 → Application → Local Storage → `discord.com` → key `token` (hoặc lệnh console) → dán token vào app.
6. Enter trống = huỷ đăng nhập an toàn.

### 3.3 Bảo mật / ToS
- Không lưu password ở RAM lâu hơn 1 lần gửi, không ghi password ra file, không log.
- Token lưu `~/.blackhole/config`, **chmod 600** (unix).
- `/logout` xoá token khỏi config.
- In cảnh báo ToS 1 lần khi đăng nhập kiểu user: app bên thứ 3 có thể bị Discord khóa tài khoản — người dùng tự chịu.

---

## 4. SPEC XEM ẢNH (xem đc ảnh)

### 4.1 Pipeline
```
tin nhắn có attachments[] ──parse──► Att{name,url,w,h,size,content_type}
        │  /img <số tin> [k]          (k = ảnh thứ k nếu tin có nhiều file)
        ▼
img::download(url, cap 50MB)  ← streaming, chặn file khổng lồ
        ▼
image::load_from_memory  (png · jpeg · gif frame đầu · webp)   guard: > 30MP → từ chối
        ▼
thumbnail về ≤ (số cột ô × số hàng ô × 2 px dọc)   ← RAM vẽ chỉ vài KB
        ▼
vẽ ANSI half-block: mỗi ô terminal = 2 px dọc, ký tự ▀,
fg = px trên, bg = px dưới, truecolor \x1b[38;2;r;g;b;48;2;R;G;Bm
        ▼
Overlay giữa màn hình TUI (tiêu đề = tên file + kích thước, Esc đóng)
ở chế độ line-mode → in thẳng ra stdout.
```

### 4.2 Lệnh mới
| Lệnh | Tác dụng |
|------|----------|
| `/img <số tin> [k]` | xem ảnh ngay trong terminal (overlay) |
| `/save <số tin> [k]` | tải file gốc về `~/.blackhole/downloads/<tên>` |
| `/open <số tin> [k]` | tải + mở bằng viewer hệ thống (xdg-open/start/open) |

### 4.3 Đính kèm trong danh sách tin
`[ảnh: meme.png 800x600]` (ảnh) / `[file: data.zip (1.2 MB)]` (file thường) — parse từ API thật.

---

## 5. SPEC TUI KIỂU DISCORDO

### 5.1 Layout
```
┌──────────────────────────────────────────────────────────────────┐ ← header (inverse)
│ SERVER              │  [12] 09:45 Huy dev                        │
│  1 Blackhole Corp   │  : anh em ơi v2 lên đồ rồi nè              │
│  2 Gaming VN        │  [11] 09:44 Trang                          │
│                     │  : giao diện nay đẹp ra đó                  │
│ KÊNH                │  [10] 09:40 bot-dank                       │
│ • general           │  : [ảnh: meme.png 800x600]                 │
│   dev               │                                            │
│   memes             │  ↑ lịch sử (xx dòng) khi cuộn              │
│ ┌─ nhập tin nhắn ─┐ │                                            │
│ │ > xin chào▌     │ │   ← focus viền xanh khi ở ô nhập           │
│ └─────────────────┘ │                                            │
│ #general • Corp  ● online        ← notice                        │ ← status bar
└──────────────────────────────────────────────────────────────────┘
```

### 5.2 Bảng phím
| Phím | Tác dụng |
|------|----------|
| gõ chữ | viết tin nhắn (ô nhập luôn focus) · Enter gửi |
| Tab | chuyển focus: ô nhập → SERVER → KÊNH → ô nhập |
| ↑/↓ ở SERVER/KÊNH | chọn mục · **Enter** mở server / vào kênh |
| ↑/↓ khi ô nhập trống | cuộn lịch sử tin nhắn (PageUp/PageDown nhanh hơn) |
| ↑/↓ khi ô nhập có chữ | lặp lại tin đã gửi trước đó (history) |
| Backspace/Delete · ←/→ · Home/End · Ctrl+U | sửa dòng nhập |
| Esc | đóng overlay · xoá ô nhập |
| Ctrl+C | thoát (dọn terminal sạch sẽ) |
| chuột không cần — mọi thứ bằng phím + lệnh `/` |

### 5.3 Fallback
- Không phải tty (pipe/script) hoặc `--plain` → **chế độ line-mode v1.1** giữ nguyên 100% hành vi cũ.
- `--demo` → dữ liệu giả, không cần tài khoản, xem giao diện ngay.

---

## 6. TỐI ƯU NHẸ (trước → sau)

| Hạng mục | v1.1 | v2.0 |
|----------|------|------|
| Binary linux x64 | 1.7MB (glibc động) | **~2.5–3.5MB musl STATIC** (mở chạy mọi distro, không cần cài gì) |
| RAM peak | ~3.6MB | ≤ 8MB (có decode ảnh tạm thời) |
| Deps mới | — | crossterm (raw+phím, ~150KB), image 0.25 chọn 4 codec (~500KB) — **không tokio/ratatui/openssl** |
| Kỷ luật deps | serde_json + ureq + tungstenite | + crossterm + image (default-features=false, chỉ 4 codec) |
| Lỗi cũ đã sửa | gw `eprintln!` phá màn hình TUI → thành `Ev::NetErr` | config chmod 600 · /quit dọn terminal đúng cách |

CI thêm target **x86_64-unknown-linux-musl** (musl-tools + `CC=musl-gcc`) → 5 artifact:
linux-x64 (musl static) · linux-x86 · windows-x64 · windows-x86 + webhook Discord như cũ.

---

## 7. CHECKLIST BUG-FINDER (BF1 — rà trước khi build)

**Mạng / gateway**
1. 429 REST đã retry +300ms — giữ nguyên. 2. WS reconnect backoff 2→60s, reset sau 300s ổn định.
3. op9 invalid session → thông báo rõ, không crash. 4. Heartbeat interval = HELLO −2s, min 5s.
5. Thread gateway lỗi → `Ev::NetErr`, không `eprintln!` vào màn hình TUI (bug thật của v1.1).

**Auth**
6. Sai password → hiện `message` của Discord, cho nhập lại. 7. 2FA sai 3 lần → huỷ sạch sẽ.
8. Captcha dán sai → tự quay lại step captcha, không loop vô hạn (cap 4 lần).
9. Token trong config hết hạn → hỏi đăng nhập lại bằng email ngay, không thoát đột ngột.
10. Không in token ra màn hình/log ở dạng đầy đủ.

**TUI / terminal**
11. Wrap chuỗi có ANSI: escape không bị đếm là ký tự, màu "mang" sang dòng sau đúng.
12. Terminal hẹp (<44 cột) → ẩn sidebar, không panic. 13. Terminal cao/đai thay đổi (Resize event) → vẽ lại.
14. KeyEventKind::Release trên Windows phải bỏ qua (không double-input).
15. Esc/Enter đóng overlay đúng; scroll overlay không âm, không vượt đáy.
16. /quit và Ctrl+C phải khôi phục terminal (raw mode off, thoát alternate screen) kể cả khi lỗi giữa chừng.
17. Ảnh overlay to hơn màn hình → giới hạn theo cols/rows, có cuộn.
18. Buffer trống / chưa vào kênh → pane hiển thị hướng dẫn, không panic index.

**Ảnh**
19. File > 50MB → chặn trước khi tải. 20. > 30MP → không decode, gợi ý /save.
21. GIF → frame đầu; webp lossy/lossless; content-type lạ → coi là file thường.
22. Ảnh trong DM/guild khác chỉ mở được khi đang ở đúng kênh tin đó (index theo buf hiện tại).
23. Không giữ ảnh bytes trong RAM sau khi vẽ xong.

**Dữ liệu**
24. message_reference phải string (đã fix v1.1 — kiểm thử lại). 25. id > 2^53 phải parse từ string.
26. Mention <@id>/<@!id> decode; embeds gắn [embed]. 27. Tin > 2000 ký tự → chặn gửi.
28. Ring buffer 200 — pop_front đúng, không rò RAM. 29. /more nối history đúng thứ tự.
30. fmt_time với ISO thiếu ms/+00:00 không panic.

**Hệ thống**
31. Config hỏng/không có HOME → vẫn chạy, hỏi token. 32. i686 Windows: ANSI qua SetConsoleMode; TUI cần Windows 10+.
33. Ctrl+C giữa lúc đang tải ảnh → dọn terminal trong handler thoát.
34. stdin không phải tty → tự chuyển line-mode (không treo).

*(BF2 chạy lại toàn bộ trên binary thật sau build. Các mục không sửa được trong v2.0 sẽ ghi vào Known-issues của README.)*

---

## 8. LỘ TRÌNH + TIÊU CHÍ NGHIỆM THU

| Milestone | Nội dung | Acceptance |
|-----------|----------|------------|
| **M1 Plan** | plan.md này | M2 duyệt: mọi module có spec + KPI |
| **M2 Auth** | login.rs + menu đăng nhập | build pass; luồng email→token đúng spec 3.1–3.2; password không echo |
| **M3 Image** | img.rs + api.rs atts + /img /save /open | --demo không crash; render_ansi trả dòng ANSI hợp lệ; cap 50MB/30MP hoạt động |
| **M4 TUI** | tui.rs + main.rs mode chọn | `--smoke` qua pty thoát mã 0, màn hình có đủ panel; line-mode hành vi = v1.1 |
| **M5 Release** | perf + CI + docs + webhook | binary + RAM đạt KPI mục 0; 5 target CI xanh; webhook HTTP 200 |

---

## 9. CI/CD (giữ + mở rộng)
- 1 workflow duy nhất: matrix 5 target (thêm linux-x64-musl), cache `Swatinem/rust-cache@v2`.
- Mỗi target: zip + sha256 + upload artifact.
- Job `discord` (`needs: build, if: always()`): embed xanh/đỏ + curl multipart `?wait=true`
  gửi tất cả zip về webhook — kiểm tra HTTP 200/204, không đúng thì warning.

## 10. FEATURE BACKLOG (F-group đề xuất cho v2.2+)
1. Sixel/Kitty graphics protocol cho ảnh nét gấp 4 (auto-detect terminal).
2. Gửi file/ảnh từ máy lên Discord. 3. Toast khi có tin nhắn kênh khác. 4. Search tin nhắn.
5. Mouse click chọn kênh. 6. Nhiều kênh song song (tab). 7. Đổi status presence. 8. Emoji picker ASCII.

---

## 11. UPDATE v2.1 — TRÌNH DUYỆT ẨN + VOICE BRIDGE + GITHUB CI/CD

> Chủ dự án chốt ý: "ko vô đc voice… tự build 1 core browser cực nhẹ chạy trong đó, có yêu cầu
> đăng nhập Discord thì terminal bắt kiểu ngụy trang là Discord terminal — thực ra có browser
> nhưng siêu nhẹ dành cho Discord — browser ẩn".
> 100 Manager đã đánh giá 3 phương án và chốt P2:
>
> | Phương án | Nhúng web engine thật (WebView2/WebKitGTK) | **P2 · Browser ẩn dạng bridge (CHỐT)** | Vào voice bằng WebRTC trong terminal |
> |---|---|---|---|
> | Binary | +100–400MB, chết mục tiêu nhẹ | **+0 KB deps, ~+15KB code** | +2–3MB (opus + ICE) |
> | RAM | 150–400MB | **~0 (browser của máy tự quản)** | +10–20MB |
> | Rủi ro ToS | cao | thấp (user tự bấm captcha) | cao |
> | Chấm của M1 | loại | **9.5/10** | loại (v2.2+)

### 11.1 SPEC TRÌNH DUYỆT ẨN — `bridge.rs` (squad C9 mới: 13 coder)

```
Discord trả captcha_sitekey (+ captcha_rqdata)
        ▼
bridge.rs sinh trang "Discord • Xác minh bảo mật" (dark #1e1f22 + blurple #5865f2 — NGỤY TRANG)
  • widget hCaptcha chính hiệu data-sitekey + data-rqdata + data-callback
  • mục dự phòng <details>: hướng dẫn F12 lấy token nếu hCaptcha từ chối sitekey trên localhost
        ▼
TcpListener bind 127.0.0.1:0 (port ngẫu nhiên, std::net — KHÔNG thêm crate)
        ▼
tự mở trình duyệt (xdg-open / start / open — tái dùng img::open_system)
  → trình duyệt là render engine, terminal là điều phối: "browser ẩn" đúng nghĩa
        ▼
user TỰ BẤM captcha  →  JS onPass(token)  →  fetch POST /done  →  local server nhận
        ▼
terminal TỰ BẮT captcha_key  →  POST /auth/login lại  →  vào app, không cần dán tay
```

Luật an toàn (M4 duyệt):
1. Server **chỉ nghe 127.0.0.1**, sống tối đa **6 phút** (WAIT_SECS=360), nhận xong là đóng.
2. Không tự giải captcha — người dùng tự bấm (đúng pháp lý + đúng ý chủ dự án từ v2.0).
3. Không ghi token/password ra đĩa; request cap 64KB, body cap 32KB, không log.
4. Token Discord dán vào trang dự phòng bị phát hiện (`looks_like_token`) → dùng thẳng làm token,
   không gửi đi làm captcha_key.
5. Bridge lỗi/hết giờ → **tự rơi về flow dán tay v2.0** (trang hCaptcha demo + hướng dẫn 'h') —
   không bao giờ kẹt chết.

### 11.2 SPEC VOICE BRIDGE — `/voice` (squad C10: 12 coder)

- Terminal không truyền tiếng: WebRTC/UDP/Opus là gánh nặng binary+RAM, hoãn sang v2.2.
- `/voice` (không tham số = kênh đang đứng; `/voice <channel_id>` = kênh bất kỳ):
  1. `GET /channels/<id>` → loại kênh phải là **2 (voice)** hoặc **13 (stage)**, không thì báo rõ.
  2. Đọc `guild_id` → mở `https://discord.com/channels/<guild>/<channel>` bằng trình duyệt.
  3. In hướng dẫn: browser cần đã đăng nhập Discord web; voice chạy trên browser,
     terminal vẫn chat realtime song song (gateway WS không ngắt).
- KPI: 1 lệnh là vào được voice, không phải tự tìm link; không thêm deps, không thêm thread.

### 11.3 GITHUB CI/CD (M3 Release + C7)

- Tạo repo `blackhole` bằng **GitHub PAT do chủ dự án cung cấp** — token chỉ dùng lúc push,
  **không được commit/print/lưu vào bất kỳ file nào** (M4 giám sát).
- Push lên branch `main` → workflow sẵn có tự chạy: build 5 target → zip + sha256 →
  upload artifact → job `discord` gửi toàn bộ zip về Discord webhook (HTTP 200/204).
- Khuyến nghị sau release: chuyển webhook URL sang repo secret `DISCORD_WEBHOOK`
  (workflow đã ghi chú sẵn chỗ thay) và chủ dự án nên **revoke/rotate PAT** sau khi dùng xong
  vì token đã xuất hiện trong hội thoại.

### 11.4 BUG-FINDER BỔ SUNG (BF1 v2.1 — 12 mục mới)
1. Port 0 bị chiếm/không bind được → báo lỗi dễ hiểu, rơi về dán tay. 2. Browser không mở được
(xdg-open thiếu) → in link rõ ràng. 3. hCaptcha từ chối domain localhost → trang có mục dự phòng,
API không kẹt. 4. Đóng browser giữa chừng → hết 6 phút tự huỷ, không treo máy. 5. Request rác
(favicon, scanner) → 204/404, không panic. 6. Body to hơn cap → bỏ kết nối, không OOM. 7. POST
done body rỗng → 400, vòng lặp tiếp tục chờ. 8. /voice khi chưa vào kênh → báo hướng dẫn.
9. /voice với kênh text/DM → báo không phải voice. 10. /voice khi API lỗi → in lỗi nguyên văn.
11. Token dán vào trang dự phòng đúng format Discord → nhận diện dùng thẳng. 12. Demo mode
cấm gọi mọi API/browser (đã chặn ở từng lệnh).

### 11.5 KPI NGHIỆM THU v2.1

| Hạng mục | Tiêu chí |
|----------|----------|
| Bridge | `cargo test` pass gồm test end-to-end POST /done → bắt đúng token; GET / trả trang có sitekey |
| Voice | `/voice` trên kênh text được chặn đúng; demo mode không gọi API |
| Nhẹ | binary linux-x64-musl ≤ v2.0 + 25KB; RAM không tăng thường trú |
| CI | GitHub Actions 5/5 target xanh; Discord webhook nhận đủ zip |

---

*— Hết plan. Toàn bộ code v2.1 bám 100% spec này, không tự ý thêm deps ngoài danh sách mục 6.*

---

## 12. PIVOT v3.0 — BLACKHOLE BROWSER (yêu cầu chủ dự án 14/11/2026)

> "ko làm discord on terminal nữa — làm browser gaming + core browser tối ưu cực mượt
> cho game thủ, đấu với browser gaming thế hệ 5, mượt hơn Opera và dùng ít RAM.
> Dùng workflow để bench lẫn xây browser, tự gửi file + điểm số lên webhook."

### 12.1 NGUYÊN TẮC THIẾT KẾ (squad C9/C10 chuyển sang browser)

| Hạng mục | Quyết định | Lý do |
|---|---|---|
| Engine | **KHÔNG bundle** — dùng webview hệ thống (WebView2 / WebKitGTK) | Opera GX nhúng Chromium: cài 300-500MB, RAM ~500MB+. Webview hệ thống = 0 MB cài thêm, RAM thấp hơn hẳn |
| UI | 2 webview con (thanh tab + nội dung) + IPC JSON | nhẹ, không framework, không electron |
| Tabs | tối đa 24, switch = dựng lại webview nội dung | v1.0 giữ binary nhỏ; v1.1 roadmap multi-webview giữ state |
| Binary | opt-level=z + lto + strip | mục tiêu < 10MB |
| Bảo mật | IPC chỉ đẩy JSON vào inbox; không lock qua webview call | chống deadlock COM |

### 12.2 SPEC BENCH (browser/bench/)

- `gen-pages.ps1`: 5 trang nửa nặng (DOM 1500 dòng + heap ~30MB + SVG + rAF anim) — cùng bộ cho mọi browser, công bằng tuyệt đối.
- `bench.ps1`: cold start (spawn → CDP ready), RAM 5 tabs (tổng WS/Private cây process), Speedometer 3 qua CDP WebSocket.
- Đối thủ: Microsoft Edge, Google Chrome, Opera GX (choco). Bỏ qua đối thủ nào không cài được — không bịa số.

### 12.3 KPI NGHIỆM THU v3.0

| Mục | Tiêu chí |
|---|---|
| Build | Windows x64 + Linux x64 xanh trên Actions |
| Webhook | zip build + bảng điểm số vào Discord (HTTP 200 trong log) |
| Bench | chạy THẬT, có số thật cho ≥ 2 browser (BLACKHOLE + Edge); ghi chú công bằng về nhân Chromium |
| Compile | `cargo check --target x86_64-pc-windows-msvc` pass trước khi push |

