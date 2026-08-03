#!/usr/bin/env bash

set -euo pipefail

export TH_COMMAND="${1:-}"
export TH_VALUE="${2:-}"
export TH_EXTRA="${3:-}"

python3 <<'PYEOF'
import calendar
import os
import sys
from datetime import date, datetime, timedelta, timezone

BEIJING = timezone(timedelta(hours=8))
command = os.environ.get("TH_COMMAND", "")
value = os.environ.get("TH_VALUE", "")
extra = os.environ.get("TH_EXTRA", "")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def parse_datetime(raw: str, field: str = "timestamp") -> datetime:
    text = raw.strip()
    if not text:
        fail(f"{field} is required")
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        fail(f"invalid ISO {field}: {raw}")
    return parsed


def as_beijing(parsed: datetime) -> datetime:
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=BEIJING)
    return parsed.astimezone(BEIJING)


def iso_seconds(parsed: datetime) -> str:
    return as_beijing(parsed).replace(microsecond=0).isoformat()


def parse_int(raw: str, field: str) -> int:
    try:
        return int(raw)
    except ValueError:
        fail(f"{field} must be an integer")


def add_months(source: date, months: int) -> date:
    absolute_month = source.year * 12 + source.month - 1 + months
    year, month_zero = divmod(absolute_month, 12)
    month = month_zero + 1
    day = min(source.day, calendar.monthrange(year, month)[1])
    return date(year, month, day)


if command == "now":
    print(datetime.now(BEIJING).replace(microsecond=0).isoformat())
elif command == "today":
    print(datetime.now(BEIJING).date().isoformat())
elif command == "ensure-tz":
    print(iso_seconds(parse_datetime(value)))
elif command == "to-beijing":
    parsed = parse_datetime(value)
    if parsed.tzinfo is None:
        fail("to-beijing requires a timezone-aware timestamp")
    print(parsed.astimezone(BEIJING).strftime("%Y-%m-%d %H:%M"))
elif command == "date-of":
    print(as_beijing(parse_datetime(value)).date().isoformat())
elif command == "shift":
    minutes = parse_int(extra, "shift minutes")
    shifted = as_beijing(parse_datetime(value)) + timedelta(minutes=minutes)
    print(shifted.replace(microsecond=0).isoformat())
elif command == "date-shift":
    try:
        source_date = date.fromisoformat(value.strip())
    except ValueError:
        fail(f"invalid ISO date: {value}")
    days = parse_int(extra, "shift days")
    print((source_date + timedelta(days=days)).isoformat())
elif command == "age":
    birth = as_beijing(parse_datetime(value, "birth timestamp")).date()
    reference = (
        as_beijing(parse_datetime(extra, "reference timestamp")).date()
        if extra.strip()
        else datetime.now(BEIJING).date()
    )
    if reference < birth:
        fail("reference date cannot precede birth date")

    months = (reference.year - birth.year) * 12 + reference.month - birth.month
    if add_months(birth, months) > reference:
        months -= 1
    anchor = add_months(birth, months)
    days = (reference - anchor).days
    years, remaining_months = divmod(months, 12)

    parts = []
    if years:
        parts.append(f"{years}岁")
    if remaining_months or not years:
        parts.append(f"{remaining_months}个月")
    if days or not parts:
        parts.append(f"{days}天")
    print("".join(parts))
else:
    fail(
        "usage: time-helper.sh "
        "<now|today|ensure-tz|to-beijing|date-of|shift|date-shift|age> "
        "[value] [amount/reference]"
    )
PYEOF
