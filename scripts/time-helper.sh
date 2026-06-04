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
  python3 << 'PYEOF'
from datetime import datetime, timezone, timedelta
dt = datetime.now(timezone.utc) + timedelta(hours=8)
print(dt.strftime('%Y-%m-%dT%H:%M:%S+08:00'))
PYEOF
}

beijing_today() {
  python3 << 'PYEOF'
from datetime import datetime, timezone, timedelta
dt = datetime.now(timezone.utc) + timedelta(hours=8)
print(dt.strftime('%Y-%m-%d'))
PYEOF
}

to_beijing() {
  local utc="$1"
  export TH_UTC="$utc"
  python3 << 'PYEOF' 2>&1
import sys, os
from datetime import datetime, timezone, timedelta
s = os.environ["TH_UTC"].replace("Z", "+00:00")
dt = datetime.fromisoformat(s)
bj = dt.astimezone(timezone(timedelta(hours=8)))
print(bj.strftime('%Y-%m-%d %H:%M'))
PYEOF
}

ensure_tz() {
  local t="$1"
  export TH_TIME="$t"
  python3 << 'PYEOF' 2>&1
import sys, os
s = os.environ["TH_TIME"].strip()
if s.endswith('+08:00') or s.endswith('+0800'):
    print(s)
    sys.exit(0)
if s.endswith('Z'):
    s = s[:-1]
if len(s) == 16:  # yyyy-MM-ddTHH:mm
    s += ':00'
elif len(s) == 19 and s.count(':') == 2:  # yyyy-MM-ddTHH:mm:ss
    pass
print(f'{s}+08:00')
PYEOF
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
