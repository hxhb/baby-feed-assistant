# Time Handling — UTC+8 (Beijing)

All time operations go through `<SKILL_DIR>/scripts/time-helper.sh`. The script
encodes timezone rules so models don't need to remember them.

## Subcommands

### `now` — current Beijing time, POST-ready

```bash
bash time-helper.sh now
# → 2026-06-04T15:30:00+08:00
```

Use this for POST body time fields (`startTime`, `endTime`, `recordedAt`,
`sleepStartTime`, `sleepEndTime`, `scheduledAt`). Re-run for each record — never
cache the output.

### `today` — current Beijing date, GET-ready

```bash
bash time-helper.sh today
# → 2026-06-04
```

Use this for `?date=` query params. The parameter is a Beijing date; the server
handles the UTC window internally.

### `to-beijing` — UTC timestamp → display

```bash
bash time-helper.sh to-beijing "2026-05-15T07:00:00.000Z"
# → 2026-05-15 15:00

bash time-helper.sh to-beijing "2026-05-14T23:30:00Z"
# → 2026-05-15 07:30  (跨天)
```

API responses return timestamps ending in `Z` (UTC). Pipe them through
`to-beijing` before showing to the user. The script handles date rollover.

### `ensure-tz` — guarantee +08:00 suffix

```bash
bash time-helper.sh ensure-tz "2026-06-04T15:00"
# → 2026-06-04T15:00:00+08:00

bash time-helper.sh ensure-tz "2026-06-04T15:00:00"
# → 2026-06-04T15:00:00+08:00

bash time-helper.sh ensure-tz "2026-06-04T15:00:00+08:00"
# → 2026-06-04T15:00:00+08:00  (already correct, pass through)
```

Use this when the user provides a time string that might lack the timezone. Safe
to call even if the string already has `+08:00` — it's a no-op pass-through.

## Why script over prompt rules

Smaller models struggle with timezone arithmetic in prompts. The script removes
three failure modes:

| Old (prompt rule) | New (script) |
|---|---|
| Model forgets `+08:00` suffix on POST | `ensure-tz` guarantees it |
| Model reuses cached `now` across records | `now` is re-invoked each time |
| Model miscalculates UTC+8 display, misses date rollover | `to-beijing` handles it deterministically |
