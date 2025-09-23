#!/usr/bin/env bash
# Usage: echo -n 'value' | ./encode-secret.sh
# or: ./encode-secret.sh 'value'
set -euo pipefail
if [ $# -gt 0 ]; then
  printf '%s' "$1" | base64 | tr -d '\n'
else
  # read from stdin
  base64 | tr -d '\n'
fi
