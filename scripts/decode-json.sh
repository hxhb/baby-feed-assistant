#!/usr/bin/env bash

# Normalize JSON Unicode escapes to UTF-8 using an atomic, private rewrite.

set -euo pipefail

json_path="${1:-}"
if [[ -z "$json_path" ]]; then
  echo "Usage: decode-json.sh <json-file>" >&2
  exit 1
fi
if [[ -L "$json_path" ]]; then
  echo "ERROR: refusing to rewrite a symbolic link" >&2
  exit 1
fi
if [[ ! -f "$json_path" || ! -r "$json_path" ]]; then
  echo "ERROR: JSON file is missing or unreadable: $json_path" >&2
  exit 1
fi

python3 - "$json_path" <<'PYEOF'
import json
import os
import sys
import tempfile

source = os.path.abspath(sys.argv[1])
directory = os.path.dirname(source)
temporary = None

try:
    with open(source, "r", encoding="utf-8") as handle:
        data = json.load(handle)

    fd, temporary = tempfile.mkstemp(prefix=".bf-json-", dir=directory, text=True)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, source)
except Exception as error:
    if temporary:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    print(f"ERROR: failed to normalize JSON: {error}", file=sys.stderr)
    raise SystemExit(1)
PYEOF
