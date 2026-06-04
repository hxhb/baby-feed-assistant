#!/usr/bin/env bash
# Baby Feed webhook event analyzer.
# All deterministic computation (API calls, time conversion, math, thresholds)
# happens here. The model reads the JSON output and only handles NL formatting.
#
# Usage:
#   bash analyze-event.sh feeding  '<raw_json>'
#   bash analyze-event.sh reminder '<raw_json>'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Helpers ---

call_api() {
  local result
  result=$(bash "$SCRIPT_DIR/query-api.sh" "$@" 2>/dev/null) || true
  echo "$result"
}

call_time() {
  local result
  result=$(bash "$SCRIPT_DIR/time-helper.sh" "$@" 2>/dev/null) || true
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
    result = d if not isinstance(d, dict) or d else ''
except:
    result = ''
if result == '':
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
  eventId=$(parse_field "$raw_json" "data.id" "$(parse_field "$raw_json" "id" "")")

  if [[ -z "$babyId" || -z "$feedingType" ]]; then
    echo '{"status":"error","error":"Missing babyId or feeding type in raw JSON"}'
    return 1
  fi

  local beijing_time today
  beijing_time=$(call_time to-beijing "$startTime")
  today=$(call_time today)

  local feeding_data
  feeding_data=$(call_api GET "/api/feeding?babyId=$babyId&date=$today" "" "")

  local stats_data
  stats_data=$(call_api GET "/api/stats?babyId=$babyId&days=7" "" "")

  local yesterday
  yesterday=$(python3 << PYEOF 2>/dev/null
from datetime import date, timedelta
print((date.today() + timedelta(days=-1)).isoformat())
PYEOF
)
  local yesterday_feedings=""
  if [[ -n "$yesterday" ]]; then
    yesterday_feedings=$(call_api GET "/api/feeding?babyId=$babyId&date=$yesterday" "" "")
  fi

  export RAW_JSON="$raw_json"
  export BABY_ID="$babyId"
  export EVENT_ID="$eventId"
  export FEEDING_TYPE="$feedingType"
  export START_TIME="$startTime"
  export BEIJING_TIME="$beijing_time"
  export TODAY="$today"
  export FEEDING_DATA="$feeding_data"
  export STATS_DATA="$stats_data"
  export YESTERDAY_FEEDINGS="$yesterday_feedings"

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
        return f"{h}小时{mi}分钟"
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
today = os.environ["TODAY"]

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
yesterday_list = parse_feedings(os.environ.get("YESTERDAY_FEEDINGS", ""))

all_recent = [f for f in feedings if str(f.get("id")) != str(event_id)]
if not all_recent and yesterday_list:
    all_recent = yesterday_list

interval_section = None
if all_recent and start_time_str:
    prev = all_recent[0]
    prev_start = prev.get("startTime", "")
    if prev_start:
        try:
            prev_utc = parse_utc(prev_start)
            curr_utc = parse_utc(start_time_str)
            diff = abs(curr_utc - prev_utc)
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

today_sessions = [f for f in feedings if f.get("type") == feeding_type]
today_total = 0
today_unit = ""

if feeding_type == "BREAST_MILK":
    today_total = sum((f.get("leftBreastDuration", 0) or 0) + (f.get("rightBreastDuration", 0) or 0) for f in today_sessions)
    today_unit = "分钟"
elif feeding_type == "BREAST_MILK_BOTTLE":
    today_total = sum(f.get("breastMilkAmount", 0) or 0 for f in today_sessions)
    today_unit = "ml"
elif feeding_type == "FORMULA":
    today_total = sum(f.get("formulaAmount", 0) or 0 for f in today_sessions)
    today_unit = "ml"

sessions_count = len(today_sessions)
if feeding_type != "SOLID_FOOD":
    today_display = f"今天累计{feeder['label']}{sessions_count}次共{int(today_total)}{today_unit}"
else:
    today_display = f"今天累计{feeder['label']}{sessions_count}次"

today_section = {
    "same_type_sessions": sessions_count,
    "same_type_total": int(today_total),
    "unit": today_unit,
    "display": today_display,
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
        this_amount = today_total
        deviation = ((this_amount - avg_value) / avg_value * 100) if avg_value > 0 else 0

        avg_display = f"近7天单次平均约{round(avg_value, 1)}{today_unit}/次"
        if abs(deviation) > 2:
            direction = "多" if deviation > 0 else "少"
            avg_display += f"，这次{direction}{abs(round(deviation))}%"

        week_section = {
            "value": round(avg_value, 1),
            "unit": f"{today_unit}/次",
            "total_sessions": total_sessions,
            "total_value": round(total_value, 1),
            "deviation_percent": round(deviation, 1),
            "display": avg_display,
        }

thresholds = {
    "interval_short": False,
    "interval_long": False,
    "deviation_above": False,
    "deviation_below": False,
    "daily_low": False,
    "any_hit": False,
}
threshold_details = []

if interval_section:
    im = interval_section["minutes"]
    if im < 90:
        thresholds["interval_short"] = True
        threshold_details.append(f"距上次仅{minutes_display(im)}，间隔偏短（<1.5小时）")
    elif im > 300:
        thresholds["interval_long"] = True
        threshold_details.append(f"距上次{minutes_display(im)}，间隔偏长（>5小时）")

if week_section:
    dev = week_section["deviation_percent"]
    if dev > 30:
        thresholds["deviation_above"] = True
        threshold_details.append(f"本次比7日均值高{dev}%，明显偏多（>+30%）")
    elif dev < -30:
        thresholds["deviation_below"] = True
        threshold_details.append(f"本次比7日均值低{abs(dev)}%，明显偏少（<-30%）")

if last_days and len(last_days) >= 2 and feeding_type != "SOLID_FOOD" and today_total > 0:
    recent_days = last_days[1:4]
    recent_total = 0
    for day in recent_days:
        if feeding_type == "BREAST_MILK":
            recent_total += day.get("totalBreastDuration", 0) or 0
        elif feeding_type == "BREAST_MILK_BOTTLE":
            recent_total += day.get("totalBreastMilkAmount", 0) or 0
        elif feeding_type == "FORMULA":
            recent_total += day.get("totalFormulaAmount", 0) or 0
    if len(recent_days) > 0 and recent_total > 0:
        avg_3day = recent_total / len(recent_days)
        if today_total < avg_3day * 0.8:
            thresholds["daily_low"] = True
            pct = round((1 - today_total / avg_3day) * 100)
            threshold_details.append(f"今天总量较近{len(recent_days)}日均值低约{pct}%（24h总量偏低）")

thresholds["any_hit"] = any([
    thresholds["interval_short"], thresholds["interval_long"],
    thresholds["deviation_above"], thresholds["deviation_below"],
    thresholds["daily_low"],
])

status = "ok"
errors = []
if not os.environ.get("FEEDING_DATA", "").strip():
    status = "partial"
    errors.append("Today feeding data unavailable")
if not os.environ.get("STATS_DATA", "").strip():
    status = "partial"
    errors.append("7-day stats unavailable")

output = {
    "status": status,
    "babyId": baby_id,
    "event": event_section,
    "interval": interval_section,
    "today": today_section,
    "week_avg": week_section,
    "thresholds": thresholds,
    "threshold_details": threshold_details,
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

  local scenario="" extra_data="" extra_data2=""

  if [[ "$triggerType" == "interval" && "$ruleName" == *"喂养超时提醒"* ]]; then
    scenario="feeding_timeout"
    local today
    today=$(call_time today)
    extra_data=$(call_api GET "/api/feeding?babyId=$babyId&date=$today" "" "")
    export TODAY="$today"

  elif [[ "$triggerType" == "interval" && "$ruleName" == *"健康定期提醒"* ]]; then
    scenario="health_regular"
    local health_map="{}"

    if echo "$title" | grep -qE "体重"; then
      local w
      w=$(call_api GET "/api/health?babyId=$babyId&type=WEIGHT" "" "d[:2]" 2>/dev/null || echo "[]")
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
      h=$(call_api GET "/api/health?babyId=$babyId&type=HEIGHT" "" "d[:2]" 2>/dev/null || echo "[]")
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
      t=$(call_api GET "/api/health?babyId=$babyId&type=TEMPERATURE" "" "d[:2]" 2>/dev/null || echo "[]")
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
    extra_data="$health_map"

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
      extra_data=$(call_api GET "/api/health?babyId=$babyId&type=$dedup_type&date=$today" "" "" 2>/dev/null || echo "")
    fi

  elif [[ "$triggerType" == "event_window" ]]; then
    scenario="event_window"
    extra_data=$(call_api GET "/api/health?babyId=$babyId&type=TEMPERATURE" "" "d[:3]" 2>/dev/null || echo "[]")
    local now_ts
    now_ts=$(call_time now 2>/dev/null || echo "")
    export NOW_TS="$now_ts"

  else
    scenario="unknown"
  fi

  export RAW_JSON="$raw_json"
  export SCENARIO="$scenario"
  export EXTRA_DATA="$extra_data"
  export BABY_NAME="$babyName"
  export TRIGGER_TYPE="$triggerType"
  export RULE_NAME="$ruleName"

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
    "DIAPER":             {"emoji": "\U0001f4a7", "label": "尿布"},
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
    return ""

raw = json.loads(os.environ["RAW_JSON"])
event_data = raw.get("data", raw)
scenario = os.environ["SCENARIO"]
baby_name = os.environ.get("BABY_NAME", "")
title = event_data.get("title", "")
body = event_data.get("body", "")
context = event_data.get("context", {})

output = {"status": "ok", "scenario": scenario, "emoji": "⏰"}

elapsed_min = context.get("elapsedMinutes", 0) or 0
elapsed_display = ""
if elapsed_min:
    h = elapsed_min // 60
    m = elapsed_min % 60
    if h > 0:
        elapsed_display = f"{h}小时{m}分钟"
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
    for htype in ["WEIGHT", "HEIGHT", "TEMPERATURE"]:
        records = health_map.get(htype, [])
        if not records:
            continue
        info = TYPE_MAP.get(htype, {"emoji": "?", "label": htype})
        item = {"type": htype, "emoji": info["emoji"], "label": info["label"]}
        latest = records[0]
        item["latest_value_display"] = build_value_display(latest)

        latest_time = latest.get("recordedAt", latest.get("startTime", ""))
        if latest_time:
            try:
                dt = to_beijing(parse_utc(latest_time))
                item["latest_date_display"] = fmt_date_short(dt)
            except:
                item["latest_date_display"] = latest_time

        if len(records) >= 2:
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

# ── scenario: event_window ──
elif scenario == "event_window":
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
            temp_status = "发烧"
        elif temp_val >= 37.5:
            temp_status = "低烧"

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
            "低烧": "有点低烧，留意观察",
            "发烧": "已经发烧，建议尽快就医",
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
                            remaining_display = f"约{h}小时{m}分钟"
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

# ── fallback ──
else:
    output["status"] = "unknown_scenario"
    output["error"] = f"Unrecognized reminder scenario: triggerType={os.environ.get('TRIGGER_TYPE','')}, ruleName={os.environ.get('RULE_NAME','')}"
    output["title"] = title
    output["body"] = body

print(json.dumps(output, ensure_ascii=False, indent=2))
PYEOF
}

# ============================================================
# Main dispatch
# ============================================================
cmd="${1:-}"
RAW_JSON="${2:-}"

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
