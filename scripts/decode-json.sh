#!/usr/bin/env bash
# Resolve JSON Unicode escape sequences (\uXXXX) to actual UTF-8 characters.
# LLMs are unreliable at decoding Unicode code points from raw text; this
# script uses Python's json parser which is always correct.
#
# Usage:
#   bash decode-json.sh /tmp/bf-event-abc123.json
#
# Reads the file, parses JSON (resolving all \u escapes), writes back clean UTF-8.

set -euo pipefail

json_path="${1:-}"

if [[ -z "$json_path" ]]; then
  echo "Usage: bash decode-json.sh <path-to-json-file>" >&2
  exit 1
fi

if [[ ! -f "$json_path" ]]; then
  echo "Error: file not found: $json_path" >&2
  exit 1
fi

python3 -c "
import json, sys
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print('OK')
" "$json_path"
