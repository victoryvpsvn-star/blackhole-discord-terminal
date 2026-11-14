# bench.ps1 — BENCH ĐỐI ĐẦU: BLACKHOLE Browser vs Edge vs Chrome vs Opera GX
# Đo 3 chỉ số trên CÙNG máy runner, cùng 5 trang bench:
#   1. Cold start  : từ khi spawn process -> CDP sẵn sàng (ms)
#   2. RAM 5 tabs  : tổng Working Set + Private của toàn cây process (MB)
#   3. Speedometer 3: điểm JS/render chuẩn (browserbench.org)
# Kết quả: bench/result/bench.json + bench.md (gửi thẳng Discord webhook).
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
  param($wsUrl, $expr, [int]$timeoutSec = 25)
  try {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait()
    $id = Get-Random -Maximum 999999
    $msg = @{ id = $id; method = 'Runtime.evaluate'; params = @{ expression = $expr; returnByValue = $true } } |
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
      if ($j.id -eq $id) { $ws.Dispose(); return $j.result.result.value }
    }
    $ws.Dispose()
  } catch { }
  return $null
}

function Cdp-Ready {
  param($port, [int]$waitSec = 30)
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
    # Chromium mới cần PUT; nếu vẫn lỗi -> window.open qua target đầu tiên
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

function Test-Speedometer {
  param($port)
  $sp = Cdp-NewTab $port 'https://browserbench.org/Speedometer3.0/'
  if (-not $sp -or -not $sp.webSocketDebuggerUrl) { return 'n/a (khong mo trang)' }
  $ws = $sp.webSocketDebuggerUrl
  # đợi trang tải xong (tối đa 45s)
  $deadline = (Get-Date).AddSeconds(45)
  $ready = $false
  while ((Get-Date) -lt $deadline) {
    $s = Cdp-Eval $ws 'document.readyState' 10
    if ($s -eq 'complete') { $ready = $true; break }
    Start-Sleep -Milliseconds 500
  }
  if (-not $ready) { return 'n/a (load timeout)' }
  Start-Sleep -Seconds 3
  $click = "(()=>{const b=document.querySelector('#startButton');if(b){b.click();return 'ok'}" +
           "const b2=[...document.querySelectorAll('button')].find(x=>/start/i.test((x.textContent||'')+(x.ariaLabel||'')));" +
           "if(b2){b2.click();return 'ok2'}return 'no'})()"
  $r = Cdp-Eval $ws $click 10
  Write-Host "  Speedometer click: $r"
  if ($r -eq 'no') { return 'n/a (khong nut start)' }
  $scoreExpr = "(()=>{const ids=['#result-score','#Score','.score','#resultScore','.score-value','.final-score'];" +
               "for(const s of ids){const e=document.querySelector(s);" +
               "if(e){const n=parseFloat((e.textContent||'').replace(/[^0-9.]/g,''));if(n>0)return n}}return null})()"
  $deadline = (Get-Date).AddSeconds(200)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 4
    $v = Cdp-Eval $ws $scoreExpr 10
    if ($null -ne $v -and "$v" -ne '') { return [math]::Round([double]$v, 0) }
  }
  return 'n/a (timeout)'
}

# ---------- đo từng browser ----------
$results = @()
$portBase = 9301

$targets = @()
$targets += @{ name = 'BLACKHOLE Browser'; exe = $exeBh; kind = 'bh' }
if ($edge)   { $targets += @{ name = 'Microsoft Edge';      exe = $edge;   kind = 'chromium' } }
if ($chrome) { $targets += @{ name = 'Google Chrome';       exe = $chrome; kind = 'chromium' } }
if ($opera)  { $targets += @{ name = 'Opera GX (gaming gen 5)'; exe = $opera; kind = 'chromium' } }

foreach ($t in $targets) {
  $port = $portBase; $portBase++
  Write-Host "`n=================== BENCH: $($t.name) ==================="
  Kill-All

  # 1) COLD START: spawn -> CDP sẵn sàng
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $t.exe
  $psi.UseShellExecute = $false
  if ($t.kind -eq 'bh') {
    $psi.Arguments = ''
    $psi.EnvironmentVariables['WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS'] = "--remote-debugging-port=$port"
    $psi.EnvironmentVariables['WEBVIEW2_USER_DATA_FOLDER'] = Join-Path $tmp 'wv2data'
  } else {
    $psi.Arguments = "--user-data-dir=""$(Join-Path $tmp ($t.name -replace '\W',''))"" --no-first-run --no-default-browser-check --disable-sync --remote-debugging-port=$port --window-size=1280,820 about:blank"
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $p = [System.Diagnostics.Process]::Start($psi)
  $ok = Cdp-Ready $port 40
  $sw.Stop()
  $startMs = if ($ok) { $sw.ElapsedMilliseconds } else { -1 }
  Write-Host ("  Cold start: {0} ms (CDP ready={1})" -f $startMs, $ok)
  if (-not $ok) {
    $results += @{ name = $t.name; startMs = 'FAIL'; ramWS = 'FAIL'; ramPriv = ''; speedo = 'FAIL'; note = 'CDP khong len' }
    continue
  }
  Start-Sleep -Seconds 2

  # 2) mở 5 trang bench -> đợi heap cấp phát -> đo RAM
  for ($i = 1; $i -le 5; $i++) {
    $url = 'file:///' + ((Join-Path $pages "page$i.html") -replace '\\', '/')
    Cdp-NewTab $port $url | Out-Null
    Start-Sleep -Milliseconds 600
  }
  Write-Host "  Đã mở 5 tabs — chờ 10s cho heap ổn định..."
  Start-Sleep -Seconds 10
  $patterns = switch ($t.kind) {
    'bh' { @('blackhole-browser*', 'msedgewebview2*') }
    default { @(($t.exe | Split-Path -Leaf) -replace '\.exe$', '*') }
  }
  $ram = Get-RamMB $patterns
  Write-Host ("  RAM: {0} MB working set | {1} MB private | {2} processes" -f $ram.ws, $ram.priv, $ram.procs)

  # 3) Speedometer 3
  Write-Host "  Speedometer 3 đang chạy (tối đa ~3 phút)..."
  $speedo = Test-Speedometer $port
  Write-Host "  Speedometer 3: $speedo"

  $results += @{ name = $t.name; startMs = $startMs; ramWS = $ram.ws; ramPriv = $ram.priv; procs = $ram.procs; speedo = $speedo; note = '' }
  Kill-All
}

# ---------- chấm điểm ----------
$okRows = @($results | Where-Object { $_.startMs -is [long] -and $_.startMs -ge 0 })
$winStart = ($okRows | Sort-Object startMs | Select-Object -First 1).name
$winRam   = ($okRows | Sort-Object ramWS   | Select-Object -First 1).name
$okSpeed  = @($results | Where-Object { $_.speedo -is [double] -or $_.speedo -is [long] })
$winSpeed = if ($okSpeed.Count) { ($okSpeed | Sort-Object { [double]$_.speedo } -Descending | Select-Object -First 1).name } else { 'n/a' }

$bh = $results | Where-Object { $_.name -like 'BLACKHOLE*' } | Select-Object -First 1
$gx = $results | Where-Object { $_.name -like 'Opera*' } | Select-Object -First 1
$verdict = ''
if ($bh -and $gx -and $bh.ramWS -is [double] -and $gx.ramWS -is [double]) {
  $diff = [math]::Round($gx.ramWS - $bh.ramWS, 1)
  $verdict = if ($diff -gt 0) {
    "BLACKHOLE ăn RAM: thieu hơn Opera GX $diff MB (WS)."
  } else {
    "Opera GX nhẹ RAM hơn $([math]::Abs($diff)) MB — nhưng BLACKHOLE không cài thêm engine nào vào máy."
  }
} elseif ($bh) {
  $verdict = "So với Chrome/Edge cùng nhân Chromium: BLACKHOLE dùng webview hệ thống, không cài thêm gì."
}

# ---------- xuất file ----------
$tableLines = @()
$tableLines += '| Browser | Cold start (ms) | RAM 5 tabs (MB WS) | RAM private | Speedometer 3 |'
$tableLines += '|---|---|---|---|---|'
foreach ($r in $results) {
  $s = if ($r.startMs -is [long] -and $r.startMs -ge 0) { $r.startMs } else { 'FAIL' }
  $w = if ($null -ne $r.ramWS) { $r.ramWS } else { '-' }
  $pv = if ($null -ne $r.ramPriv) { $r.ramPriv } else { '-' }
  $tableLines += "| $($r.name) | $s | $w | $pv | $($r.speedo) |"
}

$json = [pscustomobject]@{
  date       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  machine    = "cores=$env:NUMBER_OF_PROCESSORS ram=$([math]::Round($cs.TotalPhysicalMemory/1GB,1))GB"
  browsers   = $results
  winStart   = $winStart
  winRam     = $winRam
  winSpeed   = $winSpeed
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
$md += ('**Thắng Speedometer 3:** ' + $winSpeed)
$md += ''
$md += ('**Kết luận:** ' + $verdict)
$md += ''
$md += '> Ghi chú công bằng: Edge/Chrome/Opera GX đều nhân Chromium; BLACKHOLE Browser dùng WebView2'
$md += '> (cùng nhân Chromium của máy) — điểm JS gần nhau là đúng lý thuyết. Lợi thế thật nằm ở RAM +'
$md += '> cold start + dung lượng cài đặt: không bundle engine, không service nền, không telemetry.'
$md | Set-Content (Join-Path $outDir 'bench.md') -Encoding UTF8

Write-Host "`n=================== KẾT QUẢ ==================="
$tableLines | ForEach-Object { Write-Host $_ }
Write-Host ("WIN START=$winStart | WIN RAM=$winRam | WIN SPEEDO=$winSpeed")
Write-Host $verdict

if ($env:GITHUB_STEP_SUMMARY) {
  Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($md -join "`r`n") -Encoding UTF8
}
exit 0
