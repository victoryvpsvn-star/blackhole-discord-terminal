// bench.rs — BH-BENCH: benchmark JS tự định nghĩa của Blackhole.
//
// Cùng công thức cho MỌI browser (bench.ps1 dùng bản PowerShell, app
// dùng bản này) — median 3 lần, không phụ thuộc rAF/DOM:
//   P1 ALU hash 4M vòng · P2 sort 300k · P3 string 200k · P4 JSON 20k
//   score = 100000 / tổng ms (cao = nhanh = tốt)
//
// Chạy bằng lệnh: blackhole-browser --bench
// App mở trang bench, tự chạy 3 vòng, in "BH-BENCH-RESULT ..." rồi thoát.

pub fn bench_html() -> String {
    let tpl = r#"<!doctype html>
<html><head><meta charset="utf-8"><title>BH-Bench — BLACKHOLE</title></head>
<body><script>
function bhRun() {
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
  return { p1: Math.round(t1 - t0), p2: Math.round(t2 - t1), p3: Math.round(t3 - t2),
           p4: Math.round(t4 - t3), total: Math.round(total), score: score };
}
(async () => {
  const r1 = bhRun(); const r2 = bhRun(); const r3 = bhRun();
  const scores = [r1.score, r2.score, r3.score].sort((x, y) => x - y);
  const out = JSON.stringify({ median: scores[1], all: scores, detail: r3 });
  window.ipc.postMessage(JSON.stringify({ cmd: 'bench', v: out }));
})();
</script></body></html>"#;
    tpl.to_string()
}

#[cfg(test)]
mod tests {
    #[test]
    fn bench_html_co_du_cong_thuc() {
        let html = super::bench_html();
        assert!(html.contains("4000000"), "thiếu P1 ALU");
        assert!(html.contains("300000"), "thiếu P2 sort");
        assert!(html.contains("200000"), "thiếu P3 string");
        assert!(html.contains("20000"), "thiếu P4 JSON");
        assert!(html.contains("cmd: 'bench'"));
        assert!(html.contains("median"));
    }
}
