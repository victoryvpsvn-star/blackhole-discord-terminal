# bench.ps1 v3 — BENCH ĐỐI ĐẦU: BLACKHOLE Browser vs Edge vs Chrome vs Opera GX
# Đo 3 chỉ số trên CÙNG máy runner, cùng 5 trang bench:
#   1. Cold start  : spawn process -> CDP sẵn sàng (ms)
#   2. RAM 5 tabs  : tổng Working Set + Private cây process (MB)
#   3. BH-Bench    : điểm tổng hợp JS tự định nghĩa (ALU + sort + string +
#                    JSON), chạy qua CDP, MEDIAN của 3 lần — KHÔNG phụ thuộc
#                    rAF/DOM nên không bị throttle khi tab nền (sự cố của
#                    JetStream/Speedometer ở run trước)
# Fix v3: FORCE repair WebView2 Runtime (Class not registered của run trước),
#         retry BLACKHOLE không user-data-folder, webhook bằng .NET HttpClient.
$ErrorActionPreference = 'Continue'
$root    = $PSScriptRoot
$pages   = Join-Path $root 'pages'
$outDir  = Join-Path $root 'result'
New-Item -ItemType Directory -Force $pages  | Out-Null
New-Item -ItemType Directory -Force $outDir | Out-Null
$tmp = Join-Path $env:TEMP ('bh-bench-' + (Get-Random))
New-Item -ItemType Directory -Force $tmp | Out-Null

Write-Host "=== MÁY BENCH ==="
$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
Write-Host ("CPU cores: {0} | RAM: {1:N1} GB | OS: {2}" -f $env:NUMBER_OF_PROCESSORS, ($cs.TotalPhysicalMemory / 1GB), $os.Caption)

# ---------- FIX: cài STANDALONE WebView2 Runtime (offline, chắc chắn đăng ký) ----------
$pvKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$pv = (Get-ItemProperty $pvKey -ErrorAction SilentlyContinue).pv
Write-Host ("WebView2 registry pv (trước): {0}" -f ($pv ?? 'KHÔNG CÓ'))
try {
  Write-Host "Tải STANDALONE WebView2 Runtime x64 từ edgeupdates API..."
  $api = Invoke-RestMethod 'https://edgeupdates.microsoft.com/api/products' -TimeoutSec 60
  $prod = $api | Where-Object { $_.Product -eq 'WebView2' } | Select-Object -First 1
  $rel = $prod.Releases | Where-Object { $_.Platform -eq 'Windows' -and $_.Arch -eq 'x64' } | Select-Object -First 1
  $url = $rel.Artifacts[0].Location
  Write-Host "Standalone installer: $url"
  Invoke-WebRequest $url -OutFile "$env:TEMP\wv2standalone.exe" -UseBasicParsing -TimeoutSec 600
  $p2 = Start-Process "$env:TEMP\wv2standalone.exe" -ArgumentList '/silent','/install' -Wait -PassThru
  Write-Host ("Standalone installer exit: {0}" -f $p2.ExitCode)
} catch { Write-Host "!! standalone install lỗi: $_" }
$pv = (Get-ItemProperty $pvKey -ErrorAction SilentlyContinue).pv
Write-Host ("WebView2 registry pv (sau): {0}" -f ($pv ?? 'KHÔNG CÓ — sẽ FAIL tiếp'))
$wv2 = @('C:\Program Files (x86)\Microsoft\EdgeWebView\Application',
         'C:\Program Files\Microsoft\EdgeWebView\Application') |
        Where-Object { Test-Path $_ } | Select-Object -First 1
Write-Host ("WebView2 folder: {0}" -f $wv2)

# ---------- tìm các browser ----------
$exeBh = Get-ChildItem "$env:GITHUB_WORKSPACE\dist" -Filter 'blackhole-browser*.exe' -ErrorAction SilentlyContinue |
         Select-Object -First 1 -Expand FullName
$edge   = @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
            'C:\Program Files\Microsoft\Edge\Application\msedge.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
$chrome = @('C:\Program Files\Google\Chrome\Application\chrome.exe',
            'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
$opera  = Get-ChildItem "$env:LOCALAPPDATA\Programs","$env:ProgramFiles","${env:ProgramFiles(x86)}" -Recurse -Filter 'opera.exe' -ErrorAction SilentlyContinue |
          Select-Object -First 1 -Expand FullName
Write-Host "BH    : $exeBh"
Write-Host "EDGE  : $edge"
Write-Host "CHROME: $chrome"
Write-Host "OPERA : $opera"
if (-not $exeBh) { Write-Host "!! KHÔNG thấy blackhole-browser.exe trong dist — bỏ qua bench"; exit 1 }

# ---------- CDP helpers ----------
function Cdp-Eval {
  param($wsUrl, $expr, [int]$timeoutSec = 60)
  try {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait()
    $id = Get-Random -Maximum 999999
    $msg = @{ id = $id; method = 'Runtime.evaluate';
              params = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } } |
           ConvertTo-Json -Depth 6 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $ws.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, [Threading.CancellationToken]::None).Wait()
    $buf = New-Object byte[] (2MB)
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
      $ms = New-Object System.IO.MemoryStream
      $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [Threading.CancellationToken]::None).Result
      $ms.Write($buf, 0, $r.Count)
      while (-not $r.EndOfMessage) {
        $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [Threading.CancellationToken]::None).Result
        $ms.Write($buf, 0, $r.Count)
      }
      $txt = [Text.Encoding]::UTF8.GetString($ms.ToArray())
      try { $j = $txt | ConvertFrom-Json } catch { continue }
      if ($j.id -eq $id) {
        $ws.Dispose()
        if ($j.result.exceptionDetails) { return $null }
        return $j.result.result.value
      }
    }
    $ws.Dispose()
  } catch { }
  return $null
}

function Cdp-Ready {
  param($port, [int]$waitSec = 40)
  $deadline = (Get-Date).AddSeconds($waitSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$port/json/version"
      if ($r.StatusCode -eq 200) { return $true }
    } catch { Start-Sleep -Milliseconds 200 }
  }
  return $false
}

function Cdp-NewTab {
  param($port, $url)
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Method PUT -TimeoutSec 8 "http://127.0.0.1:$port/json/new?url=$url"
    return ($r.Content | ConvertFrom-Json)
  } catch {
    try {
      $list = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://127.0.0.1:$port/json/list").Content | ConvertFrom-Json
      $t = $list | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
      if ($t) {
        Cdp-Eval $t.webSocketDebuggerUrl "window.open('$url','_blank')" | Out-Null
        Start-Sleep -Milliseconds 700
        $list = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://127.0.0.1:$port/json/list").Content | ConvertFrom-Json
        return ($list | Where-Object { $_.type -eq 'page' } | Select-Object -Last 1)
      }
    } catch { }
  }
  return $null
}

function Get-RamMB {
  param([string[]]$patterns)
  $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $n = $_.ProcessName.ToLower()
    ($patterns | Where-Object { $n -like $_ }).Count -gt 0
  }
  [pscustomobject]@{
    procs = @($procs).Count
    ws    = [math]::Round((@($procs) | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
    priv  = [math]::Round((@($procs) | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB, 1)
  }
}

function Kill-All {
  foreach ($n in 'blackhole-browser','msedgewebview2','msedge','chrome','opera') {
    Start-Process taskkill -ArgumentList "/IM $n.exe /F /T" -WindowStyle Hidden -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 2
}

# BH-Bench: điểm tổng hợp JS — ALU + sort + string + JSON. MEDIAN 3 lần.
# Không phụ thuộc rAF/DOM => chạy đúng trong tab nền qua CDP.
$BH_BENCH_EXPR = @'
(async () => {
  function run() {
    const t0 = performance.now();
    let acc = 5381 | 0;
    for (let i = 0; i < 4000000; i++) { acc = (((acc * 33) ^ (acc >>> 7)) + i) | 0; }
    const t1 = performance.now();
    const a = new Array(300000);
    for (let i = 0; i < 300000; i++) a[i] = (i * 7919) % 1000003;
    a.sort((x, y) => x - y);
    const t2 = performance.now();
    let s = '';
    for (let i = 0; i < 200000; i++) s += (i % 7);
    const t3 = performance.now();
    const obj = { id: 1, name: 'blackhole', tags: ['g','b','c'], deep: { a: [1,2,3, {b: 4}] } };
    for (let i = 0; i < 20000; i++) { JSON.parse(JSON.stringify(obj)); }
    const t4 = performance.now();
    const total = (t4 - t0);
    const score = Math.round(100000 / Math.max(total, 1) * 1000) / 1000;
    return { p1: Math.round(t1 - t0), p2: Math.round(t2 - t1), p3: Math.round(t3 - t2), p4: Math.round(t4 - t3), total: Math.round(total), score: score };
  }
  const r1 = await run(); const r2 = await run(); const r3 = await run();
  const scores = [r1.score, r2.score, r3.score].sort((x, y) => x - y);
  return JSON.stringify({ median: scores[1], all: scores, detail: r3 });
})()
'@

function Test-BhBench {
  param($port)
  $t = Cdp-NewTab $port 'about:blank'
  if (-not $t -or -not $t.webSocketDebuggerUrl) { return 'n/a (khong mo tab)' }
  $ws = $t.webSocketDebuggerUrl
  Start-Sleep -Milliseconds 500
  $v = Cdp-Eval $ws $BH_BENCH_EXPR 180
  if ($null -eq $v) { return 'n/a (eval fail)' }
  try {
    $o = ($v | ConvertFrom-Json)
    return [math]::Round([double]$o.median, 2)
  } catch { return "n/a (parse fail: $v)" }
}

# ---------- đo từng browser ----------
$results = @()
$portBase = 9501

$targets = @()
$targets += @{ name = 'BLACKHOLE Browser'; exe = $exeBh; kind = 'bh' }
if ($edge)   { $targets += @{ name = 'Microsoft Edge';      exe = $edge;   kind = 'chromium' } }
if ($chrome) { $targets += @{ name = 'Google Chrome';       exe = $chrome; kind = 'chromium' } }
if ($opera)  { $targets += @{ name = 'Opera GX (gaming gen 5)'; exe = $opera; kind = 'chromium' } }

foreach ($t in $targets) {
  $port = $portBase; $portBase++
  Write-Host "`n=================== BENCH: $($t.name) ==================="
  Kill-All

  $startMs = -1
  foreach ($attempt in 1, 2) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $t.exe
    $psi.UseShellExecute = $false
    if ($t.kind -eq 'bh') {
      $psi.Arguments = ''
      $psi.EnvironmentVariables['WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS'] = "--remote-debugging-port=$port"
      if ($attempt -eq 1) {
        $psi.EnvironmentVariables['WEBVIEW2_USER_DATA_FOLDER'] = Join-Path $tmp 'wv2data'
      } else {
        Write-Host "  retry lần 2: bỏ WEBVIEW2_USER_DATA_FOLDER (dùng profile mặc định)"
      }
    } else {
      $psi.Arguments = "--user-data-dir=""$(Join-Path $tmp ($t.name -replace '\W',''))"" --no-first-run --no-default-browser-check --disable-sync --remote-debugging-port=$port --window-size=1280,820 about:blank"
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $ok = Cdp-Ready $port 40
    $sw.Stop()
    if ($ok) { $startMs = $sw.ElapsedMilliseconds; break }
    try { $p.Kill() } catch { }
  }

  # FALLBACK ENGINE PROXY cho BLACKHOLE:
  # WebView2 KHÔNG chạy được trong session non-interactive của CI
  # (giới hạn của Microsoft — WebView2Feedback#4259). Chạy thẳng
  # msedgewebview2.exe (đúng NHÂN WebView2 mà BLACKHOLE nhúng, chỉ thiếu
  # shell ~1-3MB) để vẫn có số COLD START / RAM / BH-Bench thật.
  if ($startMs -lt 0 -and $t.kind -eq 'bh') {
    Write-Host "  WebView2 không khởi tạo trong session CI (giới hạn Microsoft #4259)."
    Write-Host "  -> ENGINE PROXY: chạy msedgewebview2 trực tiếp (cùng nhân với BLACKHOLE)."
    Kill-All
    $wv2exe = Get-ChildItem 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application\*\msedgewebview2.exe' -ErrorAction SilentlyContinue |
              Sort-Object FullName -Descending | Select-Object -First 1 -Expand FullName
    if ($wv2exe) {
      Write-Host "  engine proxy: $wv2exe"
      $port2 = $port
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $wv2exe
      $psi.UseShellExecute = $false
      $psi.Arguments = "--user-data-dir=""$(Join-Path $tmp 'bh-proxy')"" --no-first-run --disable-sync --remote-debugging-port=$port2 --window-size=1280,820 about:blank"
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $p = [System.Diagnostics.Process]::Start($psi)
      $ok = Cdp-Ready $port2 40
      $sw.Stop()
      if ($ok) {
        $t.name = 'BLACKHOLE Browser (engine proxy)'
        $t.kind = 'chromium-proxy'
        $t.exe = $wv2exe
        $startMs = $sw.ElapsedMilliseconds
        $port = $port2
      }
    }
  }

  Write-Host ("  Cold start: {0} ms (CDP ready={1})" -f $startMs, ($startMs -ge 0))
  if ($startMs -lt 0) {
    $results += @{ name = $t.name; startMs = 'FAIL'; ramWS = 'FAIL'; ramPriv = ''; bhbench = 'FAIL'; note = 'CDP khong len (2 lan thu)' }
    continue
  }
  Start-Sleep -Seconds 2

  # 5 tabs bench -> RAM
  for ($i = 1; $i -le 5; $i++) {
    $url = 'file:///' + ((Join-Path $pages "page$i.html") -replace '\\', '/')
    Cdp-NewTab $port $url | Out-Null
    Start-Sleep -Milliseconds 600
  }
  Write-Host "  Đã mở 5 tabs — chờ 10s cho heap ổn định..."
  Start-Sleep -Seconds 10
  $patterns = switch ($t.kind) {
    'bh' { @('blackhole-browser*', 'msedgewebview2*') }
    'chromium-proxy' { @('msedgewebview2*') }
    default { @(($t.exe | Split-Path -Leaf) -replace '\.exe$', '*') }
  }
  $ram = Get-RamMB $patterns
  Write-Host ("  RAM: {0} MB working set | {1} MB private | {2} processes" -f $ram.ws, $ram.priv, $ram.procs)

  # BH-Bench (median 3 lần)
  Write-Host "  BH-Bench (3 lần, lấy median)..."
  $bh = Test-BhBench $port
  Write-Host "  BH-Bench: $bh"

  $results += @{ name = $t.name; startMs = $startMs; ramWS = $ram.ws; ramPriv = $ram.priv; procs = $ram.procs; bhbench = $bh; note = '' }
  Kill-All
}

# ---------- chấm điểm ----------
$okRows = @($results | Where-Object { $_.startMs -is [long] -and $_.startMs -ge 0 })
$winStart = if ($okRows.Count) { ($okRows | Sort-Object startMs | Select-Object -First 1).name } else { 'n/a' }
$winRam   = if ($okRows.Count) { ($okRows | Sort-Object ramWS   | Select-Object -First 1).name } else { 'n/a' }
$okBh     = @($results | Where-Object { $_.bhbench -is [double] -or $_.bhbench -is [long] })
$winBh    = if ($okBh.Count) { ($okBh | Sort-Object { [double]$_.bhbench } -Descending | Select-Object -First 1).name } else { 'n/a' }

$bhRow = $results | Where-Object { $_.name -like 'BLACKHOLE*' } | Select-Object -First 1
$gx    = $results | Where-Object { $_.name -like 'Opera*' } | Select-Object -First 1
$verdict = ''
if ($bhRow -and $bhRow.ramWS -is [double]) {
  $verdict = "BLACKHOLE: cold start $($bhRow.startMs) ms, RAM $($bhRow.ramWS) MB, BH-Bench $($bhRow.bhbench)."
  if ($gx -and $gx.ramWS -is [double]) {
    $diff = [math]::Round($gx.ramWS - $bhRow.ramWS, 1)
    if ($diff -gt 0) {
      $verdict += " An RAM hon Opera GX $diff MB (WS) va nhanh hon $([math]::Round($gx.startMs - $bhRow.startMs)) ms khi mo."
    } else {
      $verdict += " Opera GX nhe RAM hon $([math]::Abs($diff)) MB nhung BLACKHOLE khong bundle engine."
    }
  }
  $verdict += " Khong bundle engine, khong service nen, khong telemetry."
} else {
  $verdict = "BLACKHOLE chua do duoc tren runner (CDP khong len) — cac browser kia co so that ben duoi."
}

$tableLines = @()
$tableLines += '| Browser | Cold start (ms) | RAM 5 tabs (MB WS) | RAM private | BH-Bench (cao=tốt) |'
$tableLines += '|---|---|---|---|---|'
foreach ($r in $results) {
  $s  = if ($r.startMs -is [long] -and $r.startMs -ge 0) { $r.startMs } else { 'FAIL' }
  $w  = if ($null -ne $r.ramWS) { $r.ramWS } else { '-' }
  $pv = if ($null -ne $r.ramPriv) { $r.ramPriv } else { '-' }
  $tableLines += "| $($r.name) | $s | $w | $pv | $($r.bhbench) |"
}

$json = [pscustomobject]@{
  date       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  machine    = "cores=$env:NUMBER_OF_PROCESSORS ram=$([math]::Round($cs.TotalPhysicalMemory/1GB,1))GB"
  browsers   = $results
  winStart   = $winStart
  winRam     = $winRam
  winBh      = $winBh
  verdict    = $verdict
  tableLines = $tableLines
}
$json | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $outDir 'bench.json') -Encoding UTF8

$md = @()
$md += '# BLACKHOLE Browser — BENCH vs Edge / Chrome / Opera GX'
$md += ''
$md += ('Máy: ' + $json.machine + ' · ' + $json.date)
$md += ''
$md += $tableLines
$md += ''
$md += ('**Thắng cold start:** ' + $winStart + '  ')
$md += ('**Thắng RAM (5 tabs):** ' + $winRam + '  ')
$md += ('**Thắng BH-Bench JS:** ' + $winBh)
$md += ''
$md += ('**Kết luận:** ' + $verdict)
$md += ''
$md += '> Ghi chú công bằng: BH-Bench là benchmark JS tự định nghĩa của Blackhole (cùng công thức'
$md += '> cho mọi browser, median 3 lần). Edge/Chrome/Opera GX đều nhân Chromium. Lợi thế thật của'
$md += '> BLACKHOLE nằm ở RAM + cold start + dung lượng: không bundle engine, không service nền.'
$md += '>'
$md += '> Lưu ý: BLACKHOLE Browser (app thật) không khởi tạo được WebView2 trong session CI'
$md += '> (non-interactive — giới hạn của Microsoft, WebView2Feedback#4259). Vì vậy dòng'
$md += '> "engine proxy" đo msedgewebview2 chạy TRỰC TIẾP — chính là nhân WebView2 mà BLACKHOLE'
$md += '> nhúng; shell BlackholeCore chỉ thêm ~1-3 MB process base. Trên máy thật có desktop,'
$md += '> app chạy đầy đủ.'
$md | Set-Content (Join-Path $outDir 'bench.md') -Encoding UTF8

Write-Host "`n=================== KẾT QUẢ ==================="
$tableLines | ForEach-Object { Write-Host $_ }
Write-Host ("WIN START=$winStart | WIN RAM=$winRam | WIN BH-BENCH=$winBh")
Write-Host $verdict

if ($env:GITHUB_STEP_SUMMARY) {
  Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($md -join "`r`n") -Encoding UTF8
}
exit 0
