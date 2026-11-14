#!/usr/bin/env bash
# build.sh — bundle lib/*.sh + entry into a single-file dist binary
set -euo pipefail
cd "$(dirname "$0")"

out="dist/blackhole-vps-bench"
mkdir -p dist

{
  printf '%s\n' '#!/usr/bin/env bash' 'BH_EMBEDDED=1' '# bundled build — regenerate with build.sh'
  tail -n +2 bin/blackhole-vps-bench
  for f in lib/*.sh; do
    printf '\n# ============ %s ============\n' "$f"
    cat "$f"
  done
  printf '\nmain "$@"\n'
} > "$out"

chmod +x "$out"
bash -n "$out"
bytes=$(wc -c < "$out")
echo "built $out ($bytes bytes, syntax OK)"
