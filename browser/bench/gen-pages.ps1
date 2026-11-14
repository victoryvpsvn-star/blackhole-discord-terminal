# gen-pages.ps1 — sinh 5 trang bench NỶA NẶNG giống nhau cho mọi browser.
# Mỗi trang: DOM 1500 dòng bảng + heap JS ~30MB + SVG data-uri + anim rAF.
# Công bằng tuyệt đối: cùng 5 file này cho BLACKHOLE / Edge / Chrome / Opera.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $PSScriptRoot 'pages'
New-Item -ItemType Directory -Force $dir | Out-Null

# SVG nội suy 500 hình vuông ngẫu nhiên (~100KB) -> data-uri
$rects = (1..500 | ForEach-Object {
  $x = Get-Random -Maximum 780; $y = Get-Random -Maximum 420
  "<rect x='$x' y='$y' width='40' height='30' fill='hsl($($_ * 7 % 360),70%,50%)'/>"
}) -join ''
$svg = "<svg xmlns='http://www.w3.org/2000/svg' width='800' height='450'>$rects</svg>"
$img = "data:image/svg+xml;base64," + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($svg))

for ($i = 1; $i -le 5; $i++) {
  $rows = (1..1500 | ForEach-Object {
    "<tr><td>row $($_)</td><td>gpu $($_ * $i)</td><td>fps</td><td>ping</td><td>payload</td></tr>"
  }) -join ''
  # html dùng token thay thế — KHÔNG dùng here-string nội suy (tránh va $ của JS)
  $html = @'
<!doctype html><html><head><meta charset="utf-8">
<title>Bench Page __I__ — BLACKHOLE</title></head><body>
<h1>Bench Page __I__</h1>
<div id="anim" style="width:80px;height:80px;background:linear-gradient(90deg,#7c3aed,#22d3ee);border-radius:10px"></div>
<script>
const junk=[];for(let k=0;k<150000;k++){junk.push('payload-'+k+'-'+'x'.repeat(150))}
const __img='__IMG__';
const im=new Image();im.src=__img;document.body.appendChild(im);
(function loop(){const a=document.getElementById('anim');
a.style.transform='translateX('+(Math.sin(Date.now()/300)*200)+'px)';
requestAnimationFrame(loop)})();
</script>
<table>__ROWS__</table>
</body></html>
'@
  $html = $html.Replace('__I__', "$i").Replace('__IMG__', $img).Replace('__ROWS__', $rows)
  Set-Content -Path (Join-Path $dir "page$i.html") -Value $html -Encoding UTF8
}
Write-Host "OK: 5 trang bench trong $dir"
Get-ChildItem $dir | ForEach-Object { Write-Host ("  {0}  {1:N0} KB" -f $_.Name, ($_.Length / 1KB)) }
