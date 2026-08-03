# Time Handling

Use `scripts/time-helper.sh` for every date/time conversion. The application groups records by Beijing calendar day (`UTC+08:00`).

## Commands

| Command | Input | Output/use |
|---|---|---|
| `now` | none | Current Beijing timestamp, POST-ready |
| `today` | none | Current Beijing date for `?date=` |
| `ensure-tz` | ISO timestamp | Assign Beijing to a naive timestamp, or convert an aware timestamp to Beijing |
| `to-beijing` | timezone-aware ISO timestamp | `YYYY-MM-DD HH:mm` for display |
| `date-of` | ISO timestamp | Beijing `YYYY-MM-DD` for date-specific queries |
| `shift` | ISO timestamp, signed minutes | Shift an instant and return a Beijing timestamp |
| `date-shift` | `YYYY-MM-DD`, signed days | Date arithmetic such as yesterday/tomorrow |
| `age` | birth timestamp, optional reference timestamp | Calendar age in Chinese |

Examples:

```bash
bash <SKILL_DIR>/scripts/time-helper.sh ensure-tz "2026-06-04T15:00"
# 2026-06-04T15:00:00+08:00

bash <SKILL_DIR>/scripts/time-helper.sh ensure-tz "2026-06-04T07:00:00Z"
# 2026-06-04T15:00:00+08:00

bash <SKILL_DIR>/scripts/time-helper.sh shift "2026-06-04T15:00:00+08:00" -120
# 2026-06-04T13:00:00+08:00

bash <SKILL_DIR>/scripts/time-helper.sh date-shift "2026-06-04" -1
# 2026-06-03
```

## Recording rules

- Capture one `now` for one record. Reuse that base instant when `recordedAt` and another field intentionally represent the same moment.
- Derive related times with `shift`; do not call `now` repeatedly and assume the outputs are identical.
- Get a fresh `now` for a separate record.
- Preserve an explicit offset supplied by the user semantically: `ensure-tz` converts it to Beijing without changing the instant.
- Treat a naive ISO timestamp as Beijing wall time.
- Reject non-ISO or impossible dates. Do not append `+08:00` to arbitrary text.

## Relative language

Resolve relative expressions against a freshly captured Beijing `now`:

- `刚刚` / no explicit time: use the captured `now`.
- `X 分钟前` / `X 小时前`: call `shift BASE -MINUTES`.
- `昨天` / `明天`: call `date-shift TODAY -1|1`, then combine with the stated clock time and call `ensure-tz`.
- `昨晚八点` and similar phrases need both a derived date and an explicit clock time.
- If a phrase can map to more than one instant, ask one short clarification question.

For sleep, `sleepStartTime` is required and `sleepEndTime` is optional. When both exist, set `recordedAt` to the wake/logging instant unless the user specified otherwise. Never invent an end time for an ongoing sleep.

## Display rules

API timestamps normally serialize as UTC `Z`. Convert each timestamp through `to-beijing` before display. Keep date information when the converted date differs from today or when a range crosses midnight.
