#!/usr/bin/env bash
# Baby Feed webhook event analyzer.
# All deterministic computation (API calls, time conversion, math, thresholds)
# happens here. The model reads the JSON output and only handles NL formatting.
#
# Usage:
#   bash analyze-event.sh feeding  '<raw_json>'        # literal JSON (ASCII only)
#   bash analyze-event.sh reminder '@/path/raw.json'   # JSON from file (use this for non-ASCII)
#   bash analyze-event.sh reminder < /path/raw.json    # JSON from stdin
#
# Webhook payloads contain user-supplied non-ASCII content; pass via @<path>
# or stdin to avoid Claude Code's confusable-Unicode bash scanner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERY_API_SCRIPT="${BABY_FEED_QUERY_SCRIPT:-$SCRIPT_DIR/query-api.sh}"

# --- Helpers ---

call_api() {
  local result
  result=$(bash "$QUERY_API_SCRIPT" "$@" 2>/dev/null) || return 1
  echo "$result"
}

call_time() {
  local result
  result=$(bash "$SCRIPT_DIR/time-helper.sh" "$@" 2>/dev/null) || return 1
  echo "$result"
}

parse_field() {
  local json="$1" field_path="$2" default="$3"
  export PARSE_JSON="$json"
  export PARSE_PATH="$field_path"
  export PARSE_DEFAULT="$default"
  python3 << 'PYEOF' 2>/dev/null
import sys, json, os
try:
    d = json.loads(os.environ["PARSE_JSON"])
    for k in os.environ["PARSE_PATH"].split('.'):
        d = d.get(k, {})
    # Treat None (JSON null), empty dict, and empty string as "no value"
    if d is None or d == {} or d == '':
        result = ''
    elif not isinstance(d, dict):
        result = d
    else:
        result = d
except:
    result = ''
if result is None or result == '':
    result = os.environ["PARSE_DEFAULT"]
if isinstance(result, str):
    print(result)
else:
    print(json.dumps(result, ensure_ascii=False))
PYEOF
}

# ============================================================
# analyze_feeding
# ============================================================
analyze_feeding() {
  local raw_json="$1"

  if [[ -z "$raw_json" ]]; then
    echo '{"status":"error","error":"No raw JSON provided"}'
    return 1
  fi

  local babyId feedingType startTime eventId
  babyId=$(parse_field "$raw_json" "data.babyId" "")
  feedingType=$(parse_field "$raw_json" "data.type" "")
  startTime=$(parse_field "$raw_json" "data.startTime" "")
  eventId=$(parse_field "$raw_json" "data.recordId" "")
  if [[ -z "$eventId" ]]; then
    # Compatibility with payloads emitted before recordId was standardized.
    eventId=$(parse_field "$raw_json" "data.id" "")
  fi

  if [[ -z "$babyId" || -z "$feedingType" || -z "$startTime" ]]; then
    echo '{"status":"error","error":"Missing babyId, feeding type, or startTime in raw JSON"}'
    return 1
  fi

  local beijing_time record_date current_date
  beijing_time=$(call_time to-beijing "$startTime")
  record_date=$(call_time date-of "$startTime")
  current_date=$(call_time today)

  local feeding_data feeding_available="true"
  if ! feeding_data=$(call_api GET "/api/feeding?babyId=$babyId&date=$record_date" "" ""); then
    feeding_data=""
    feeding_available="false"
  fi

  local stats_data="" stats_available="not_applicable"
  if [[ "$record_date" == "$current_date" ]]; then
    stats_available="true"
    if ! stats_data=$(call_api GET "/api/stats?babyId=$babyId&days=7" "" ""); then
      stats_data=""
      stats_available="false"
    fi
  fi

  local previous_date
  previous_date=$(call_time date-shift "$record_date" -1)
  local previous_date_feedings=""
  if [[ -n "$previous_date" ]]; then
    previous_date_feedings=$(call_api GET "/api/feeding?babyId=$babyId&date=$previous_date" "" "" || true)
  fi

  export RAW_JSON="$raw_json"
  export BABY_ID="$babyId"
  export EVENT_ID="$eventId"
  export FEEDING_TYPE="$feedingType"
  export START_TIME="$startTime"
  export BEIJING_TIME="$beijing_time"
  export RECORD_DATE="$record_date"
  export CURRENT_DATE="$current_date"
  export FEEDING_DATA="$feeding_data"
  export STATS_DATA="$stats_data"
  export PREVIOUS_DATE_FEEDINGS="$previous_date_feedings"
  export FEEDING_AVAILABLE="$feeding_available"
  export STATS_AVAILABLE="$stats_available"

  python3 << 'PYEOF' 2>&1
import os, sys, json
from datetime import datetime, timezone, timedelta

FEEDING_MAP = {
    "BREAST_MILK":        {"emoji": "\U0001f931", "label": "亲喂母乳"},
    "BREAST_MILK_BOTTLE": {"emoji": "\U0001f37c", "label": "瓶喂母乳"},
    "FORMULA":            {"emoji": "\U0001f37c", "label": "配方奶"},
    "SOLID_FOOD":         {"emoji": "\U0001f963", "label": "辅食"},
}

def parse_utc(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))

def to_beijing(dt):
    return dt.astimezone(timezone(timedelta(hours=8)))

def fmt_short(dt):
    return dt.strftime("%H:%M")

def fmt_date_short(dt):
    return dt.strftime("%m-%d %H:%M")

def minutes_display(m):
    h = m // 60
    mi = m % 60
    if h > 0:
        if mi > 0:
            return f"{h}小时{mi}分钟"
        return f"{h}小时"
    return f"{mi}分钟"

def build_value_display(rec):
    t = rec.get("type", "")
    if t == "BREAST_MILK":
        left = rec.get("leftBreastDuration", 0) or 0
        right = rec.get("rightBreastDuration", 0) or 0
        total = left + right
        if left > 0 and right > 0:
            return f"{total}分钟（左{left}/右{right}）"
        elif left > 0:
            return f"{total}分钟（仅左{left}）"
        elif right > 0:
            return f"{total}分钟（仅右{right}）"
        return f"{total}分钟"
    elif t == "BREAST_MILK_BOTTLE":
        return f"{rec.get('breastMilkAmount', 0)} ml"
    elif t == "FORMULA":
        return f"{rec.get('formulaAmount', 0)} ml"
    elif t == "SOLID_FOOD":
        return f"{rec.get('solidFoodName', '')} {rec.get('solidFoodAmount', '')}".strip()
    return ""

raw = json.loads(os.environ["RAW_JSON"])
event_data = raw.get("data", raw)
baby_id = os.environ["BABY_ID"]
event_id = os.environ["EVENT_ID"]
feeding_type = os.environ["FEEDING_TYPE"]
start_time_str = os.environ["START_TIME"]
beijing_time_str = os.environ["BEIJING_TIME"]
record_date = os.environ["RECORD_DATE"]
current_date = os.environ["CURRENT_DATE"]
is_today = record_date == current_date

feeder = FEEDING_MAP.get(feeding_type, {"emoji": "\U0001f37c", "label": feeding_type})

beijing_dt = None
time_short = ""
time_display = ""
if beijing_time_str and beijing_time_str.strip():
    try:
        beijing_dt = datetime.strptime(beijing_time_str.strip(), "%Y-%m-%d %H:%M")
        beijing_dt = beijing_dt.replace(tzinfo=timezone(timedelta(hours=8)))
        time_short = beijing_dt.strftime("%H:%M")
        time_display = beijing_dt.strftime("%m-%d %H:%M")
    except:
        time_short = beijing_time_str.strip()
        time_display = beijing_time_str.strip()

event_section = {
    "type": feeding_type,
    "emoji": feeder["emoji"],
    "label": feeder["label"],
    "time_display": time_display,
    "time_short": time_short,
    "value_display": build_value_display(event_data),
}

def parse_feedings(raw_str):
    if not raw_str or not raw_str.strip():
        return []
    try:
        data = json.loads(raw_str)
        return data if isinstance(data, list) else []
    except:
        return []

feedings = parse_feedings(os.environ["FEEDING_DATA"])
previous_date_list = parse_feedings(os.environ.get("PREVIOUS_DATE_FEEDINGS", ""))

all_recent = []
if start_time_str:
    try:
        curr_dt = parse_utc(start_time_str)
        for record in feedings + previous_date_list:
            if event_id and str(record.get("id")) == str(event_id):
                continue
            previous_start = record.get("startTime", "")
            if not previous_start:
                continue
            previous_dt = parse_utc(previous_start)
            if previous_dt < curr_dt:
                all_recent.append((previous_dt, record))
        all_recent.sort(key=lambda item: item[0], reverse=True)
        all_recent = [item[1] for item in all_recent]
    except Exception:
        all_recent = []

interval_section = None
if all_recent and start_time_str:
    prev = all_recent[0]
    prev_start = prev.get("startTime", "")
    if prev_start:
        try:
            prev_utc = parse_utc(prev_start)
            curr_utc = parse_utc(start_time_str)
            diff = curr_utc - prev_utc
            interval_min = int(diff.total_seconds() / 60)
            prev_bj = to_beijing(prev_utc)
            prev_feeder = FEEDING_MAP.get(prev.get("type", ""), {"emoji": "\U0001f37c", "label": prev.get("type", "")})
            interval_section = {
                "minutes": interval_min,
                "display": minutes_display(interval_min),
                "previous_time_short": fmt_short(prev_bj),
                "previous_emoji": prev_feeder["emoji"],
                "previous_label": prev_feeder["label"],
                "previous_value_display": build_value_display(prev),
            }
        except:
            pass

day_sessions = [f for f in feedings if f.get("type") == feeding_type]
day_total = 0
day_unit = ""

if feeding_type == "BREAST_MILK":
    day_total = sum((f.get("leftBreastDuration", 0) or 0) + (f.get("rightBreastDuration", 0) or 0) for f in day_sessions)
    day_unit = "分钟"
elif feeding_type == "BREAST_MILK_BOTTLE":
    day_total = sum(f.get("breastMilkAmount", 0) or 0 for f in day_sessions)
    day_unit = "ml"
elif feeding_type == "FORMULA":
    day_total = sum(f.get("formulaAmount", 0) or 0 for f in day_sessions)
    day_unit = "ml"

sessions_count = len(day_sessions)
day_label = "今天" if is_today else record_date
if feeding_type != "SOLID_FOOD":
    day_display = f"{day_label}累计{feeder['label']}{sessions_count}次共{int(day_total)}{day_unit}"
else:
    day_display = f"{day_label}累计{feeder['label']}{sessions_count}次"

day_section = {
    "date": record_date,
    "is_today": is_today,
    "same_type_sessions": sessions_count,
    "same_type_total": int(day_total),
    "unit": day_unit,
    "display": day_display,
}

week_section = None
stats = None
stats_data_str = os.environ.get("STATS_DATA", "")
if stats_data_str and stats_data_str.strip():
    try:
        stats = json.loads(stats_data_str)
    except:
        stats = None

last_days = []
if stats:
    last_days = stats.get("lastDays", [])

if last_days and feeding_type != "SOLID_FOOD":
    total_sessions = 0
    total_value = 0

    for day in last_days:
        if feeding_type == "BREAST_MILK":
            total_sessions += day.get("breastFeedingCount", 0) or 0
            total_value += day.get("totalBreastDuration", 0) or 0
        elif feeding_type == "BREAST_MILK_BOTTLE":
            total_sessions += day.get("breastBottleCount", 0) or 0
            total_value += day.get("totalBreastMilkAmount", 0) or 0
        elif feeding_type == "FORMULA":
            total_sessions += day.get("formulaCount", 0) or 0
            total_value += day.get("totalFormulaAmount", 0) or 0

    if total_sessions > 0:
        avg_value = total_value / total_sessions
        # This feed's own amount (not today's total) — compare single-feed to single-feed average
        if feeding_type == "BREAST_MILK":
            this_amount = (event_data.get("leftBreastDuration", 0) or 0) + (event_data.get("rightBreastDuration", 0) or 0)
        elif feeding_type == "BREAST_MILK_BOTTLE":
            this_amount = event_data.get("breastMilkAmount", 0) or 0
        elif feeding_type == "FORMULA":
            this_amount = event_data.get("formulaAmount", 0) or 0
        else:
            this_amount = 0
        deviation = ((this_amount - avg_value) / avg_value * 100) if avg_value > 0 else 0

        avg_display = f"近7天单次平均约{round(avg_value, 1)}{day_unit}/次"
        if abs(deviation) > 2:
            direction = "多" if deviation > 0 else "少"
            avg_display += f"，这次{direction}{abs(round(deviation))}%"

        week_section = {
            "value": round(avg_value, 1),
            "unit": f"{day_unit}/次",
            "total_sessions": total_sessions,
            "total_value": round(total_value, 1),
            "deviation_percent": round(deviation, 1),
            "display": avg_display,
        }

attention = {
    "interval_short": False,
    "interval_long": False,
    "deviation_above": False,
    "deviation_below": False,
    "any_hit": False,
}
attention_details = []

if interval_section:
    im = interval_section["minutes"]
    if im < 90:
        attention["interval_short"] = True
        attention_details.append(f"距上次仅{minutes_display(im)}，可结合平时喂养节奏观察")
    elif im > 300:
        attention["interval_long"] = True
        attention_details.append(f"距上次{minutes_display(im)}，已超过5小时")

if week_section:
    dev = week_section["deviation_percent"]
    if dev > 30:
        attention["deviation_above"] = True
        attention_details.append(f"本次比近7日单次均值高约{dev}%")
    elif dev < -30:
        attention["deviation_below"] = True
        attention_details.append(f"本次比近7日单次均值低约{abs(dev)}%")

attention["any_hit"] = any([
    attention["interval_short"], attention["interval_long"],
    attention["deviation_above"], attention["deviation_below"],
])

status = "ok"
errors = []
if os.environ.get("FEEDING_AVAILABLE") != "true":
    status = "partial"
    errors.append("Event-date feeding data unavailable")
if os.environ.get("STATS_AVAILABLE") == "false":
    status = "partial"
    errors.append("7-day stats unavailable")

output = {
    "status": status,
    "babyId": baby_id,
    "event": event_section,
    "interval": interval_section,
    "day": day_section,
    "week_avg": week_section,
    "attention": {**attention, "details": attention_details},
}
if errors:
    output["errors"] = errors

print(json.dumps(output, ensure_ascii=False, indent=2))
PYEOF
}

# ============================================================
# analyze_reminder
# ============================================================
analyze_reminder() {
  local raw_json="$1"

  if [[ -z "$raw_json" ]]; then
    echo '{"status":"error","error":"No raw JSON provided"}'
    return 1
  fi

  local triggerType ruleName babyId babyName title body
  triggerType=$(parse_field "$raw_json" "data.triggerType" "")
  ruleName=$(parse_field "$raw_json" "data.ruleName" "")
  babyId=$(parse_field "$raw_json" "data.babyId" "")
  babyName=$(parse_field "$raw_json" "data.babyName" "")
  title=$(parse_field "$raw_json" "data.title" "")
  body=$(parse_field "$raw_json" "data.body" "")

  if [[ -z "$triggerType" ]]; then
    echo '{"status":"error","error":"Missing triggerType in raw JSON"}'
    return 1
  fi

  local scenario="" extra_data="" history_available="true"

  if [[ "$triggerType" == "interval" && "$ruleName" == *"喂养超时提醒"* ]]; then
    scenario="feeding_timeout"
    local today
    today=$(call_time today)
    if ! extra_data=$(call_api GET "/api/feeding?babyId=$babyId&date=$today" "" ""); then
      extra_data=""
      history_available="false"
    fi
    export TODAY="$today"

  elif [[ "$triggerType" == "interval" && ( "$ruleName" == *"睡眠超时"* || "$ruleName" == *"睡眠提醒"* || "$ruleName" == *"小睡"* || "$ruleName" == *"该睡"* ) ]]; then
    scenario="sleep_timeout"
    local today
    today=$(call_time today)
    if ! extra_data=$(call_api GET "/api/sleep-summary?babyId=$babyId&date=$today" "" ""); then
      extra_data=""
      history_available="false"
    fi
    export TODAY="$today"

  elif [[ "$triggerType" == "interval" && "$ruleName" == *"健康定期提醒"* ]]; then
    scenario="health_regular"
    local health_map="{}"

    if echo "$title" | grep -qE "体重"; then
      local w
      if ! w=$(call_api GET "/api/health?babyId=$babyId&type=WEIGHT" "" "[:2]" 2>/dev/null); then
        w="[]"
        history_available="false"
      fi
      [[ -z "$w" ]] && w="[]"
      export CURRENT_HM="$health_map"
      export W_DATA="$w"
      health_map=$(python3 << 'PYEOF' 2>/dev/null
import sys, json, os
d = json.loads(os.environ["CURRENT_HM"])
try:
    w_data = json.loads(os.environ["W_DATA"])
except:
    w_data = []
d["WEIGHT"] = w_data
print(json.dumps(d, ensure_ascii=False))
PYEOF
)
    fi

    if echo "$title" | grep -qE "身高"; then
      local h
      if ! h=$(call_api GET "/api/health?babyId=$babyId&type=HEIGHT" "" "[:2]" 2>/dev/null); then
        h="[]"
        history_available="false"
      fi
      [[ -z "$h" ]] && h="[]"
      export CURRENT_HM="$health_map"
      export H_DATA="$h"
      health_map=$(python3 << 'PYEOF' 2>/dev/null
import sys, json, os
d = json.loads(os.environ["CURRENT_HM"])
try:
    h_data = json.loads(os.environ["H_DATA"])
except:
    h_data = []
d["HEIGHT"] = h_data
print(json.dumps(d, ensure_ascii=False))
PYEOF
)
    fi

    if echo "$title" | grep -qE "体温"; then
      local t
      if ! t=$(call_api GET "/api/health?babyId=$babyId&type=TEMPERATURE" "" "[:2]" 2>/dev/null); then
        t="[]"
        history_available="false"
      fi
      [[ -z "$t" ]] && t="[]"
      export CURRENT_HM="$health_map"
      export T_DATA="$t"
      health_map=$(python3 << 'PYEOF' 2>/dev/null
import sys, json, os
d = json.loads(os.environ["CURRENT_HM"])
try:
    t_data = json.loads(os.environ["T_DATA"])
except:
    t_data = []
d["TEMPERATURE"] = t_data
print(json.dumps(d, ensure_ascii=False))
PYEOF
      )
    fi

    if echo "$title $body" | grep -qE "尿布|大小便|小便|大便"; then
      local d
      if ! d=$(call_api GET "/api/health?babyId=$babyId&type=DIAPER" "" "[:2]" 2>/dev/null); then
        d="[]"
        history_available="false"
      fi
      export CURRENT_HM="$health_map"
      export D_DATA="$d"
      health_map=$(python3 << 'PYEOF' 2>/dev/null
import json, os
d = json.loads(os.environ["CURRENT_HM"])
try:
    records = json.loads(os.environ["D_DATA"])
except Exception:
    records = []
d["DIAPER"] = records
print(json.dumps(d, ensure_ascii=False))
PYEOF
)
    fi

    if echo "$title $body" | grep -qE "睡眠|小睡|睡觉"; then
      local s
      if ! s=$(call_api GET "/api/health?babyId=$babyId&type=SLEEP" "" "[:2]" 2>/dev/null); then
        s="[]"
        history_available="false"
      fi
      export CURRENT_HM="$health_map"
      export S_DATA="$s"
      health_map=$(python3 << 'PYEOF' 2>/dev/null
import json, os
d = json.loads(os.environ["CURRENT_HM"])
try:
    records = json.loads(os.environ["S_DATA"])
except Exception:
    records = []
d["SLEEP"] = records
print(json.dumps(d, ensure_ascii=False))
PYEOF
)
    fi
    extra_data="$health_map"

  elif [[ "$triggerType" == "interval" ]]; then
    scenario="generic_interval"

  elif [[ "$triggerType" == "cron" ]]; then
    scenario="cron"
    local dedup_type=""
    if echo "$ruleName" | grep -qiE "AD|维生素"; then
      dedup_type="AD_VITAMIN"
    elif echo "$ruleName" | grep -qE "疫苗"; then
      dedup_type="VACCINE"
    elif echo "$ruleName" | grep -qE "药"; then
      dedup_type="MEDICATION"
    elif echo "$ruleName" | grep -qE "体温"; then
      dedup_type="TEMPERATURE"
    elif echo "$ruleName" | grep -qE "体重"; then
      dedup_type="WEIGHT"
    elif echo "$ruleName" | grep -qE "身高"; then
      dedup_type="HEIGHT"
    fi
    export DEDUP_TYPE="$dedup_type"

    local today
    today=$(call_time today)
    export TODAY="$today"

    if [[ -n "$dedup_type" ]]; then
      if ! extra_data=$(call_api GET "/api/health?babyId=$babyId&type=$dedup_type&date=$today" "" "" 2>/dev/null); then
        extra_data=""
        history_available="false"
      fi
    fi

  elif [[ "$triggerType" == "event_window" ]]; then
    if [[ "$ruleName" == *"疫苗"* || "$title" == *"疫苗"* || "$body" == *"疫苗"* || "$title" == *"测体温"* ]]; then
      scenario="vaccine_event_window"
      if ! extra_data=$(call_api GET "/api/health?babyId=$babyId&type=TEMPERATURE" "" "[:3]" 2>/dev/null); then
        extra_data="[]"
        history_available="false"
      fi
      local now_ts
      now_ts=$(call_time now 2>/dev/null || echo "")
      export NOW_TS="$now_ts"
    else
      scenario="generic_event_window"
    fi

  else
    scenario="unknown"
  fi

  export RAW_JSON="$raw_json"
  export SCENARIO="$scenario"
  export EXTRA_DATA="$extra_data"
  export BABY_NAME="$babyName"
  export TRIGGER_TYPE="$triggerType"
  export RULE_NAME="$ruleName"
  export HISTORY_AVAILABLE="$history_available"

  python3 << 'PYEOF' 2>&1
import os, sys, json
from datetime import datetime, timezone, timedelta

TYPE_MAP = {
    "BREAST_MILK":        {"emoji": "\U0001f931", "label": "亲喂母乳"},
    "BREAST_MILK_BOTTLE": {"emoji": "\U0001f37c", "label": "瓶喂母乳"},
    "FORMULA":            {"emoji": "\U0001f37c", "label": "配方奶"},
    "SOLID_FOOD":         {"emoji": "\U0001f963", "label": "辅食"},
    "TEMPERATURE":        {"emoji": "\U0001f321️", "label": "体温"},
    "WEIGHT":             {"emoji": "⚖️", "label": "体重"},
    "HEIGHT":             {"emoji": "\U0001f4cf", "label": "身高"},
    "DIAPER":             {"emoji": "\U0001f4a7", "label": "大小便"},
    "SLEEP":              {"emoji": "\U0001f634", "label": "睡眠"},
    "VACCINE":            {"emoji": "\U0001f489", "label": "疫苗"},
    "MEDICATION":         {"emoji": "\U0001f48a", "label": "用药"},
    "AD_VITAMIN":         {"emoji": "☀️", "label": "维生素 AD"},
}

def parse_utc(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))

def to_beijing(dt):
    return dt.astimezone(timezone(timedelta(hours=8)))

def fmt_short(dt):
    return dt.strftime("%H:%M")

def fmt_date_short(dt):
    return dt.strftime("%m-%d %H:%M")

def minutes_display(m):
    m = int(m); h = m // 60; mi = m % 60
    if h > 0 and mi > 0: return f"{h}小时{mi}分钟"
    if h > 0: return f"{h}小时"
    return f"{mi}分钟"

def build_value_display(rec):
    t = rec.get("type", "")
    if t == "BREAST_MILK":
        left = rec.get("leftBreastDuration", 0) or 0
        right = rec.get("rightBreastDuration", 0) or 0
        total = left + right
        if left > 0 and right > 0:
            return f"{total}分钟（左{left}/右{right}）"
        elif left > 0:
            return f"{total}分钟（仅左{left}）"
        elif right > 0:
            return f"{total}分钟（仅右{right}）"
        return f"{total}分钟"
    elif t == "BREAST_MILK_BOTTLE":
        return f"{rec.get('breastMilkAmount', 0)} ml"
    elif t == "FORMULA":
        return f"{rec.get('formulaAmount', 0)} ml"
    elif t == "TEMPERATURE":
        return f"{rec.get('temperature', rec.get('value', '?'))}°C"
    elif t == "WEIGHT":
        return f"{rec.get('weight', rec.get('value', '?'))} kg"
    elif t == "HEIGHT":
        return f"{rec.get('height', rec.get('value', '?'))} cm"
    elif t == "SOLID_FOOD":
        return f"{rec.get('solidFoodName', '')} {rec.get('solidFoodAmount', '')}".strip()
    elif t == "DIAPER":
        labels = {"PEE": "小便", "POOP": "大便", "BOTH": "大小便"}
        label = labels.get(rec.get("diaperType", ""), "大小便")
        status = rec.get("diaperStatus", "") or ""
        return f"{label} {status}".strip()
    elif t == "SLEEP":
        start = rec.get("sleepStartTime", "")
        end = rec.get("sleepEndTime", "")
        try:
            if start and end:
                start_dt = parse_utc(start)
                end_dt = parse_utc(end)
                duration = max(0, int((end_dt - start_dt).total_seconds() / 60))
                return f"{fmt_short(to_beijing(start_dt))} → {fmt_short(to_beijing(end_dt))}，{minutes_display(duration)}"
            if start:
                return f"{fmt_short(to_beijing(parse_utc(start)))}开始（进行中）"
        except Exception:
            pass
        return "睡眠记录"
    return ""

raw = json.loads(os.environ["RAW_JSON"])
event_data = raw.get("data", raw)
scenario = os.environ["SCENARIO"]
baby_name = os.environ.get("BABY_NAME", "")
title = event_data.get("title", "")
body = event_data.get("body", "")
context = event_data.get("context", {})

history_available = os.environ.get("HISTORY_AVAILABLE") == "true"
output = {
    "status": "ok" if history_available else "partial",
    "scenario": scenario,
    "emoji": "⏰",
    "babyName": baby_name,
    "title": title,
    "body": body,
    "history_available": history_available,
}

elapsed_min = context.get("elapsedMinutes", 0) or 0
elapsed_display = ""
if elapsed_min:
    h = elapsed_min // 60
    m = elapsed_min % 60
    if h > 0:
        if m > 0:
            elapsed_display = f"{h}小时{m}分钟"
        else:
            elapsed_display = f"{h}小时"
    else:
        elapsed_display = f"{m}分钟"
output["elapsed_display"] = elapsed_display

# ── scenario: feeding_timeout ──
if scenario == "feeding_timeout":
    extra_raw = os.environ.get("EXTRA_DATA", "")
    feedings = []
    if extra_raw and extra_raw.strip():
        try:
            feedings = json.loads(extra_raw)
            if not isinstance(feedings, list):
                feedings = []
        except:
            feedings = []

    if feedings:
        last = feedings[0]
        last_type = last.get("type", "")
        last_feeder = TYPE_MAP.get(last_type, {"emoji": "\U0001f37c", "label": last_type})
        last_start = last.get("startTime", "")
        last_time_short = ""
        if last_start:
            try:
                last_dt = to_beijing(parse_utc(last_start))
                last_time_short = fmt_short(last_dt)
            except:
                last_time_short = last_start

        output["last_feeding"] = {
            "emoji": last_feeder["emoji"],
            "label": last_feeder["label"],
            "time_short": last_time_short,
            "value_display": build_value_display(last),
        }

    type_counts = {}
    for f in feedings:
        t = f.get("type", "")
        if t not in type_counts:
            type_counts[t] = {"count": 0, "total": 0, "unit": ""}
        type_counts[t]["count"] += 1
        if t == "BREAST_MILK":
            type_counts[t]["total"] += (f.get("leftBreastDuration", 0) or 0) + (f.get("rightBreastDuration", 0) or 0)
            type_counts[t]["unit"] = "分钟"
        elif t == "BREAST_MILK_BOTTLE":
            type_counts[t]["total"] += f.get("breastMilkAmount", 0) or 0
            type_counts[t]["unit"] = "ml"
        elif t == "FORMULA":
            type_counts[t]["total"] += f.get("formulaAmount", 0) or 0
            type_counts[t]["unit"] = "ml"

    all_parts = []
    for t, info in type_counts.items():
        feeder = TYPE_MAP.get(t, {"emoji": "", "label": t})
        if info["unit"] == "分钟":
            all_parts.append(f"{feeder['label']}{info['count']}次共{int(info['total'])}分钟")
        elif info["unit"] == "ml":
            all_parts.append(f"{feeder['label']}{info['count']}次共{int(info['total'])}ml")
        else:
            all_parts.append(f"{feeder['label']}{info['count']}次")
    output["today"] = {"display": "今天累计" + "，".join(all_parts) if all_parts else f"今天共{len(feedings)}次喂养"}

# ── scenario: sleep_timeout ──
elif scenario == "sleep_timeout":
    extra_raw = os.environ.get("EXTRA_DATA", "")
    summary = {}
    if extra_raw and extra_raw.strip():
        try:
            summary = json.loads(extra_raw)
            if not isinstance(summary, dict):
                summary = {}
        except:
            summary = {}

    segments = summary.get("segments", []) or []
    total_minutes = int(summary.get("totalMinutes", 0) or 0)
    count = int(summary.get("count", len(segments)) or 0)

    output["today"] = {
        "display": f"今天累计睡{count}段，共{minutes_display(total_minutes)}" if count else "今天还没有睡眠记录"
    }

    # Last segment = the one ending latest. sleep-summary returns segments
    # chronologically, so segments[-1] is sufficient.
    if segments:
        last_seg = segments[-1]
        try:
            seg_start_bj = to_beijing(parse_utc(last_seg.get("segmentStart", "")))
            seg_end_bj = to_beijing(parse_utc(last_seg.get("segmentEnd", "")))
            seg_minutes = int(last_seg.get("segmentMinutes", 0) or 0)
            output["last_sleep"] = {
                "range_display": f"{fmt_short(seg_start_bj)} → {fmt_short(seg_end_bj)}",
                "duration_display": minutes_display(seg_minutes),
            }
            if elapsed_min:
                output["awake"] = {"display": minutes_display(elapsed_min)}
        except:
            pass

# ── scenario: health_regular ──
elif scenario == "health_regular":
    extra_raw = os.environ.get("EXTRA_DATA", "")
    health_map = {}
    if extra_raw and extra_raw.strip():
        try:
            health_map = json.loads(extra_raw)
        except:
            health_map = {}

    output["elapsed_days"] = elapsed_min // 1440 if elapsed_min else 0

    items = []
    for htype in ["WEIGHT", "HEIGHT", "TEMPERATURE", "DIAPER", "SLEEP"]:
        records = health_map.get(htype, [])
        if not records:
            continue
        info = TYPE_MAP.get(htype, {"emoji": "?", "label": htype})
        item = {"type": htype, "emoji": info["emoji"], "label": info["label"]}
        latest = records[0]
        item["latest_value_display"] = build_value_display(latest)

        latest_time = latest.get("recordedAt", latest.get("startTime", ""))
        if htype == "SLEEP":
            latest_time = latest.get("sleepEndTime") or latest.get("sleepStartTime") or latest_time
        if latest_time:
            try:
                dt = to_beijing(parse_utc(latest_time))
                item["latest_date_display"] = fmt_date_short(dt)
            except:
                item["latest_date_display"] = latest_time

        if len(records) >= 2 and htype in ("WEIGHT", "HEIGHT", "TEMPERATURE"):
            prev_rec = records[1]
            def get_val(r, t):
                if t == "WEIGHT": return r.get("weight", 0) or 0
                if t == "HEIGHT": return r.get("height", 0) or 0
                if t == "TEMPERATURE": return r.get("temperature", 0) or 0
                return 0
            curr_val = get_val(latest, htype)
            prev_val = get_val(prev_rec, htype)
            if curr_val > prev_val:
                item["trend_emoji"] = "↗️ 上升"
            elif curr_val < prev_val:
                item["trend_emoji"] = "↘️ 下降"
            else:
                item["trend_emoji"] = "→ 持平"
            item["previous_value_display"] = build_value_display(prev_rec)
        items.append(item)

    output["items"] = items

# ── scenario: cron ──
elif scenario == "cron":
    dedup_type = os.environ.get("DEDUP_TYPE", "")
    extra_raw = os.environ.get("EXTRA_DATA", "")

    type_info = TYPE_MAP.get(dedup_type, {"emoji": "?", "label": dedup_type})
    output["dedup_emoji"] = type_info["emoji"]
    output["dedup_label"] = type_info["label"]
    output["dedup_type"] = dedup_type

    records = []
    if extra_raw and extra_raw.strip():
        try:
            records = json.loads(extra_raw)
            if not isinstance(records, list):
                records = []
        except:
            records = []

    output["already_done"] = len(records) > 0
    output["generic"] = not bool(dedup_type)

    if records:
        latest = records[0]
        rec_time = latest.get("recordedAt", latest.get("startTime", ""))
        if rec_time:
            try:
                dt = to_beijing(parse_utc(rec_time))
                output["already_done_time_short"] = fmt_short(dt)
            except:
                output["already_done_time_short"] = rec_time
        output["already_done_display"] = f"今天 {output.get('already_done_time_short', '')} 已经{type_info['label']}过啦"

# ── scenario: vaccine_event_window ──
elif scenario == "vaccine_event_window":
    temp_raw = os.environ.get("EXTRA_DATA", "[]")
    temps = []
    if temp_raw and temp_raw.strip():
        try:
            temps = json.loads(temp_raw)
            if not isinstance(temps, list):
                temps = []
        except:
            temps = []

    vaccine_info = os.environ.get("RULE_NAME", "").replace("疫苗后测体温", "").strip().lstrip("· ")
    slot = context.get("slot", "?")
    window_end_str = context.get("windowEnd", "")

    output["vaccine_info"] = vaccine_info
    output["slot"] = slot

    if temps:
        latest_temp = temps[0]
        temp_val = latest_temp.get("temperature", 0) or 0
        temp_status = "正常"
        if temp_val >= 38.5:
            temp_status = "明显偏高"
        elif temp_val >= 37.5:
            temp_status = "偏高"

        temp_time = latest_temp.get("recordedAt", "")
        temp_time_short = ""
        if temp_time:
            try:
                dt = to_beijing(parse_utc(temp_time))
                temp_time_short = fmt_short(dt)
            except:
                temp_time_short = temp_time

        status_labels = {
            "正常": "正常",
            "偏高": "读数偏高，建议复测并留意状态",
            "明显偏高": "读数明显偏高，建议及时咨询医生",
        }
        output["latest_temperature"] = {
            "value_display": f"{temp_val}°C",
            "time_short": temp_time_short,
            "status": temp_status,
            "status_label": status_labels.get(temp_status, temp_status),
        }

    if window_end_str:
        try:
            window_end = parse_utc(window_end_str)
            now_str = os.environ.get("NOW_TS", "")
            remaining_display = "?"
            remaining_min = 0
            if now_str:
                try:
                    now = datetime.fromisoformat(now_str)
                    remaining = window_end - now
                    remaining_min = max(0, int(remaining.total_seconds() / 60))
                    if remaining_min > 0:
                        h = remaining_min // 60
                        m = remaining_min % 60
                        if h > 0:
                            if m > 0:
                                remaining_display = f"约{h}小时{m}分钟"
                            else:
                                remaining_display = f"约{h}小时"
                        else:
                            remaining_display = f"约{m}分钟"
                    else:
                        remaining_display = "已结束"
                except:
                    remaining_display = "?"

            window_end_bj = to_beijing(window_end)
            output["window"] = {
                "remaining_minutes": remaining_min,
                "remaining_display": remaining_display,
                "end_display": fmt_date_short(window_end_bj),
            }
        except:
            output["window"] = {"remaining_display": "?", "end_display": window_end_str}

# ── generic reminders ──
elif scenario in ("generic_interval", "generic_event_window"):
    pass

# ── fallback ──
else:
    output["status"] = "unknown_scenario"
    output["error"] = f"Unrecognized reminder scenario: triggerType={os.environ.get('TRIGGER_TYPE','')}, ruleName={os.environ.get('RULE_NAME','')}"

print(json.dumps(output, ensure_ascii=False, indent=2))
PYEOF
}

# ============================================================
# Main dispatch
# ============================================================
cmd="${1:-}"
RAW_JSON="${2:-}"

# Resolve @<path> indirection (see header).
if [[ "$RAW_JSON" == @* ]]; then
  json_path="${RAW_JSON#@}"
  if [[ ! -r "$json_path" ]]; then
    echo "{\"status\":\"error\",\"error\":\"Cannot read JSON file: $json_path\"}" >&2
    exit 1
  fi
  RAW_JSON=$(cat "$json_path")
fi

# Stdin fallback when no positional argument provided.
if [[ -z "$RAW_JSON" ]]; then
  RAW_JSON=$(cat 2>/dev/null || echo "")
fi

case "$cmd" in
  feeding)
    analyze_feeding "$RAW_JSON"
    ;;
  reminder)
    analyze_reminder "$RAW_JSON"
    ;;
  *)
    echo '{"status":"error","error":"Unknown subcommand. Use: feeding, reminder"}' >&2
    exit 1
    ;;
esac
