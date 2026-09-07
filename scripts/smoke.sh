#!/usr/bin/env bash
# Minimal post-deployment check. Extend tests/corpus/ with your own documents and
# freeze the expected output -- that is what catches a regression after a version
# bump, and it is the only thing that will tell you whether an "improvement"
# upstream silently changed extraction results.
#
#   scripts/smoke.sh            # ultralight, default port 8083
#   scripts/smoke.sh 8084       # ocrlight
set -euo pipefail

PORT="${1:-8083}"
BASE="http://127.0.0.1:${PORT}"
CORPUS="$(dirname "$0")/../tests/corpus"

echo "==> ${BASE}"

# The exact route names come from the OpenAPI document the server exposes; read
# it once and adjust the calls below if they differ on your build.
echo "-- openapi"
curl -fsS "${BASE}/openapi.json" -o /tmp/xberg-openapi.json \
  && python3 -c 'import json;d=json.load(open("/tmp/xberg-openapi.json"));print("\n".join(sorted(d["paths"])))' \
  || echo "   (no /openapi.json -- check: docker run --rm IMAGE serve --help)"

shopt -s nullglob
files=("${CORPUS}"/*)
if [ ${#files[@]} -eq 0 ]; then
  echo "-- no corpus files in tests/corpus/, skipping extraction checks"
  exit 0
fi

for f in "${files[@]}"; do
  case "$f" in *README.md) continue ;; esac
  printf -- "-- %-40s " "$(basename "$f")"
  code=$(curl -sS -o /tmp/xberg-out.json -w '%{http_code}' \
          -X POST "${BASE}/extract" -F "file=@${f}" || echo 000)
  chars=$(python3 - <<'PY' 2>/dev/null || echo '?'
import json
d = json.load(open("/tmp/xberg-out.json"))
c = d.get("content") or d.get("text") or ""
print(len(c))
PY
)
  echo "HTTP ${code}, ${chars} chars"
done
