// theme.rs — token CSS dùng chung cho mọi UI của Blackhole (đồng bộ 1 nguồn).

pub const CSS: &str = "
:root{
  --bg:#0b0d12; --bg2:#12151d; --pill:#161a22;
  --border:#232936; --txt:#e5e7eb; --dim:#9ca3af;
  --acc:#7c3aed; --acc2:#22d3ee; --ok:#23a55a; --warn:#f59e0b;
}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{background:var(--bg);color:var(--txt);font:13px 'Segoe UI',system-ui,sans-serif}
a{color:var(--acc2)}
::selection{background:#7c3aed55}
";
