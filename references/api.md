# Baby Feed API Reference

Use this file for exact request fields and response boundaries. Call every endpoint through `scripts/query-api.sh`.

## Contents

1. Common rules
2. Babies
3. Feeding
4. Health
5. Sleep summary
6. Statistics
7. Memos
8. Reminder rules
9. Timeline dates

## 1. Common rules

- Authentication: `Authorization: Bearer <API key>` is added by the wrapper.
- IDs are CUID strings.
- Write bodies are JSON. API responses serialize timestamps as UTC ISO strings.
- Date query parameters are Beijing dates in `YYYY-MM-DD` format.
- Use timezone-aware ISO timestamps for writes. Generate/normalize them with `time-helper.sh`.
- Baby, feeding, and health timestamps must be no more than one day in the future and no more than approximately 100 years in the past. Memos use the different range documented below.
- GET list endpoints return only records owned by the authenticated user.
- POST usually returns `201`; GET/PUT/DELETE return `200` on success.
- A write may emit a webhook asynchronously after the API response.

## 2. Babies

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/api/babies` | List babies, newest profile first |
| POST | `/api/babies` | Create a baby |
| GET | `/api/babies/:id` | Read one baby |
| PUT | `/api/babies/:id` | Partially update a baby |
| DELETE | `/api/babies/:id` | Delete a baby and cascading records |

Create fields:

| Field | Required | Value |
|---|---|---|
| `name` | yes | string, max 50 |
| `birthDate` | yes | ISO timestamp |
| `gender` | yes | `MALE` or `FEMALE` |

PUT accepts any subset of those fields. Always confirm DELETE because feeding, health, memo, and reminder records are related to the baby.

`birthDate` follows the common timestamp range. Do not create or update a profile with an unresolved or meaningfully future birth date even though the API allows a small clock-skew margin.

Baby response fields include `id`, `name`, `birthDate`, `gender`, `createdAt`, and `updatedAt`.

## 3. Feeding

### List

`GET /api/feeding?babyId=ID[&date=YYYY-MM-DD]`

Sorted by `startTime` descending. Omit `date` to find the latest record across all history. Responses include the related `baby` object.

### Create

`POST /api/feeding`

Common required fields: `babyId`, `type`, `startTime`.

| Type | Required type fields | Optional type fields |
|---|---|---|
| `BREAST_MILK` | at least one of `leftBreastDuration`, `rightBreastDuration` | the other duration, `endTime` |
| `BREAST_MILK_BOTTLE` | `breastMilkAmount` | `endTime` |
| `FORMULA` | `formulaAmount` | `endTime` |
| `SOLID_FOOD` | `solidFoodName` | `solidFoodAmount`, `endTime` |

`notes` is optional for every type.

Validation ranges:

- Breast durations: integer `0-120` minutes per side.
- Bottle/formula amount: number `0-1000` ml.
- Solid-food name/amount: strings up to 200 characters.
- Notes: string up to 1000 characters.
- When both `startTime` and `endTime` exist, end cannot precede start.

Example:

```json
{
  "babyId": "ID",
  "type": "SOLID_FOOD",
  "startTime": "2026-06-04T12:00:00+08:00",
  "solidFoodName": "米粉",
  "solidFoodAmount": "30g"
}
```

### Update/delete

| Method | Endpoint | Behavior |
|---|---|---|
| PUT | `/api/feeding/:id` | Partial update; changing `type` clears fields from the old type |
| DELETE | `/api/feeding/:id` | Returns `{ "success": true }` |

PUT accepts `type`, all type-specific fields, `startTime`, `endTime` (`null` clears it), and `notes`. The merged record must still satisfy the selected type's required fields.

## 4. Health

### List

`GET /api/health?babyId=ID[&type=TYPE][&date=YYYY-MM-DD]`

Sorted by `recordedAt` descending.

- `type` only: full history for that type.
- `type` plus `date`: that type on the selected day.
- `date` only: all health types on that day.
- For daily sleep totals and cross-midnight segments, use `/api/sleep-summary` instead.
- A `type`-only response is history, not a freshness guarantee. For current-day status use `date`; for event-window analysis compare `recordedAt` against the rule's `triggerConfig.anchorTime` before presenting a row as part of that event.

### Create

`POST /api/health`

Common required fields: `babyId`, `type`, `recordedAt`. `notes` is optional for all types.

| Type | Required type fields | Optional type fields |
|---|---|---|
| `WEIGHT` | `weight` | none |
| `HEIGHT` | `height` | none |
| `TEMPERATURE` | `temperature` | none |
| `MEDICATION` | `medicationName` | `medicationDose` |
| `VACCINE` | `vaccineName`, `vaccineDoseNumber`, `vaccineTotalDoses` | `vaccineManufacturer` |
| `DIAPER` | `diaperType` | `diaperStatus` |
| `AD_VITAMIN` | `adGiven` | none |
| `SLEEP` | `sleepStartTime` | `sleepEndTime`, `sleepQuality` |

Validation:

- `weight`: `0-100` kg; `height`: `0-200` cm; `temperature`: `30-45` °C.
- `diaperType`: `PEE`, `POOP`, or `BOTH`. `BOTH` contributes one pee and one poop in stats.
- Vaccine dose numbers are integers `1-20`, both are required, and current dose cannot exceed total doses.
- Health text fields are at most 200 characters; notes are at most 1000.
- If sleep end exists, it cannot precede sleep start. Ongoing sleep may omit `sleepEndTime`.

Example ongoing sleep:

```json
{
  "babyId": "ID",
  "type": "SLEEP",
  "recordedAt": "2026-06-04T13:00:00+08:00",
  "sleepStartTime": "2026-06-04T13:00:00+08:00"
}
```

### Update/delete

| Method | Endpoint | Behavior |
|---|---|---|
| PUT | `/api/health/:id` | Partial update; changing `type` clears fields from the old type |
| DELETE | `/api/health/:id` | Returns `{ "success": true }` |

PUT accepts `type`, all health fields, `recordedAt`, and `notes`. The merged record must satisfy the effective type's business rules.

## 5. Sleep summary

`GET /api/sleep-summary?babyId=ID&date=YYYY-MM-DD`

Response:

```json
{
  "date": "2026-06-04",
  "totalMinutes": 545,
  "count": 2,
  "segments": [
    {
      "id": "RECORD_ID",
      "sleepStart": "2026-06-03T14:00:00.000Z",
      "sleepEnd": "2026-06-03T19:30:00.000Z",
      "segmentStart": "2026-06-03T16:00:00.000Z",
      "segmentEnd": "2026-06-03T19:30:00.000Z",
      "segmentMinutes": 210,
      "quality": null,
      "note": null,
      "isFullRecord": false
    }
  ]
}
```

Only completed sleeps with both start and end contribute to the summary. A cross-midnight record is split at the Beijing day boundary.

## 6. Statistics

### Single-day milk summary

`GET /api/stats/day?babyId=ID&date=YYYY-MM-DD`

Returns `date`, breast feeding count/duration, breast-bottle count/amount, formula count/amount, `adGiven`, and optional measured `weight`/`temperature`.

It does not return solid food, height, diaper counts, sleep, vaccine, or medication. Query `/api/feeding` for solid-food records.

### Multi-day statistics

`GET /api/stats?babyId=ID[&days=N]`, where `days` defaults to 7 and is `1-365`.

Important fields:

- `todayStats` and `lastDays`: milk totals, left/right duration, diapers, night feeding, sleep totals/count, AD, and optional measurements.
- `totalStats`: totals over the selected range.
- `weightTrend`, `heightTrend`: full history, ascending.
- `vaccineRecords`: full history, descending.
- `medicationRecords`: only within the selected range.
- `memoRecords`: all memos.
- `feedingIntervals`, `feedingHeatmap`, `babyBirthDate`.

The HTTP `/api/stats` route currently does not expose solid-food names or amounts. `sleepDurationMinutes` is already cumulative and must not be augmented manually.

## 7. Memos

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/api/memo?babyId=ID&completed=false&date=DATE&rangeDays=N` | List memos, sorted by schedule ascending |
| POST | `/api/memo` | Create a one-time memo |
| PUT | `/api/memo/:id` | Partial update or complete a memo |
| DELETE | `/api/memo/:id` | Delete a memo |

GET rules:

- `completed` is `true` or `false`.
- `rangeDays` requires `date`, defaults to 7 when date is present, and supports `1-365`.
- The range is centered on `date` (`date - N` through `date + N`).

POST requires `babyId`, `title` (1-100 non-whitespace characters), and `scheduledAt`. `content` is optional up to 500 characters. `scheduledAt` may be up to five years in the future or approximately 100 years in the past.

PUT accepts `title`, `content`, `scheduledAt`, and `completed`. Setting `completed: true` sets `completedAt`; setting false clears it.

Memos are one-time scheduled tasks. They are not recurring reminder rules.

## 8. Reminder rules

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/api/reminders[?babyId=ID&enabled=true|false]` | List rules |
| POST | `/api/reminders` | Create a rule, maximum 50 per user |
| PUT | `/api/reminders/:id` | Partial update/toggle a rule |
| DELETE | `/api/reminders/:id` | Delete a rule |
| GET | `/api/reminders/config` | Read auto-vaccine settings |
| PUT | `/api/reminders/config` | Update auto-vaccine settings |
| GET | `/api/reminders/logs?ruleId=ID&limit=50&offset=0` | Read in-memory execution logs |
| DELETE | `/api/reminders/logs[?ruleId=ID]` | Clear logs; confirm first |

POST requires:

- `name` (max 100), `babyId`, `triggerType`, `triggerConfig`, `notifyTitle` (max 200).
- Optional `notifyBody` (max 500), `advanceMinutes` (`0-1440`), `enabled`, `activeSchedule`, `startsAt`, `expiresAt`.

Trigger configurations:

```json
{ "sourceType": "feeding", "intervalMinutes": 180, "filterCondition": { "type": ["FORMULA"] } }
```

```json
{ "cronExpr": "0 11 * * *" }
```

```json
{ "anchorTime": "2026-06-04T10:00:00+08:00", "windowHours": 72, "repeatIntervalMinutes": 300 }
```

- `triggerType` is `interval`, `cron`, or `event_window`.
- Interval `sourceType` is `feeding` or `health`; `intervalMinutes` is `1-129600`.
- Cron uses a five-field expression and cannot be `* * * * *`.
- Event window requires `anchorTime`, `windowHours` (`0.1-720`), and `repeatIntervalMinutes` (`1-14400`).
- `activeSchedule` is an object shaped as `{ "windows": [{ "start": "HH:mm", "end": "HH:mm" }] }` and can contain up to 10 windows.
- Supported template variables include `{{babyName}}`, `{{ruleName}}`, `{{now}}`, and `{{elapsed}}`.

Use cron for generic daily reminders; do not assume every cron reminder maps to a health record. Event-window rules created by the current UI are vaccine-monitoring rules, but API-created event windows may be generic.

## 9. Timeline dates

`GET /api/timeline-dates?babyId=ID`

Returns Beijing `YYYY-MM-DD` strings containing feeding, health, or memo records. Use it to discover dates, not to fetch record details.
