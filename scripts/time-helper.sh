#!/usr/bin/env bash
# Time helper for baby-feed-assistant skill.
# All output is in UTC+8 (Beijing time). Models call these subcommands instead
# of remembering timezone rules or format strings.
#
# Usage:
#   bash time-helper.sh now                        # → 2026-06-04T15:30:00+08:00
#   bash time-helper.sh today                      # → 2026-06-04
#   bash time-helper.sh to-beijing <utc-timestamp> # → 2026-06-04 15:00
#   bash time-helper.sh ensure-tz <time-string>    # → 2026-06-04T15:00:00+08:00

set -euo pipefail

CMD="${1:-}"
ARG="${2:-}"

beijing_now() {
  date -u -v+8H '+%Y-%m-%dT%H:%M:%S+08:00'
}

beijing_today() {
  date -u -v+8H '+%Y-%m-%d'
}

to_beijing() {
  local utc="$1"
  python3 -c "
import sys
from datetime import datetime, timezone, timedelta
# Parse ISO 8601, stripping 'Z' → '+00:00' so fromisoformat handles it
s = '$utc'.replace('Z', '+00:00')
dt = datetime.fromisoformat(s)
# Convert to Beijing
bj = dt.astimezone(timezone(timedelta(hours=8)))
print(bj.strftime('%Y-%m-%d %H:%M'))
" 2>&1
}

ensure_tz() {
  local t="$1"
  python3 -c "
import sys
s = '$t'.strip()
# Already has timezone offset → pass through
if s.endswith('+08:00') or s.endswith('+0800'):
    print(s)
    sys.exit(0)
# Remove trailing Z (UTC marker) → replace with +08:00
if s.endswith('Z'):
    s = s[:-1]
# Pad missing seconds
if len(s) == 16:  # yyyy-MM-ddTHH:mm
    s += ':00'
elif len(s) == 19 and s.count(':') == 2:  # yyyy-MM-ddTHH:mm:ss
    pass
# Append timezone
print(f'{s}+08:00')
" 2>&1
}

case "$CMD" in
  now)
    beijing_now
    ;;
  today)
    beijing_today
    ;;
  to-beijing)
    if [[ -z "$ARG" ]]; then
      echo "ERROR: to-beijing requires a UTC timestamp argument" >&2
      exit 1
    fi
    to_beijing "$ARG"
    ;;
  ensure-tz)
    if [[ -z "$ARG" ]]; then
      echo "ERROR: ensure-tz requires a time string argument" >&2
      exit 1
    fi
    ensure_tz "$ARG"
    ;;
  *)
    echo "Usage: bash time-helper.sh <now|today|to-beijing|ensure-tz> [value]" >&2
    exit 1
    ;;
esac
