#!/usr/bin/env bash
set -euo pipefail
OUT_DIR="$(dirname "$0")/../helm-charts-v2"
OUT_FILE="$OUT_DIR/values.secret.yaml"
mkdir -p "$OUT_DIR"

cat > "$OUT_FILE" <<'EOF'
secret:
  name: sh-agent-secret-003
  data:
    AZP_URL: "${VAL_AZP_URL_B64:-}"
    AZP_TOKEN: "${VAL_AZP_TOKEN_B64:-}"
    AZP_POOL_LINUX: "${VAL_AZP_POOL_LINUX_B64:-}"
    AZP_POOL_WINDOWS: "${VAL_AZP_POOL_WINDOWS_B64:-}"

deploy:
  linux: true
  windows: true
EOF

echo "Wrote $OUT_FILE"
