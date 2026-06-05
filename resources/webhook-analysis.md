# Webhook Event 分析手册

> **CRITICAL01 — 输出铁律**：你的输出**必须且仅包含**最终的三段式消息。严禁输出推理过程、计算步骤、事件数据罗列、时间换算、阈值检查、playbook 引用、"Now I have all the data"等中英文铺垫，确保只输出最终的规范内容。
> 
> ```
> ❌ 错误（禁止）:  "现在让我按照 playbook 的规则输出最终的三段式消息：\n🍼 刚刚喂了配方奶 60 ml（22:30）…"
> ✅ 正确:          "🍼 刚刚喂了配方奶 60 ml（22:30）\n今天第一次喂配方奶，累计1次共60ml · 近7天单次平均约60.0ml/次"
> ```
>
> **CRITICAL02 — 时间处理**：所有时间换算、+08:00后缀、UTC→北京转换必须通过 skill 内的 `time-helper.sh` 或 `analyze-event.sh` 脚本完成，禁止手动构造时间字符串、禁止心算时区偏移、禁止使用 bash `date` 命令自行换算。
>
> **CRITICAL03 — JSON 走文件**：调 `analyze-event.sh` 前，先用 **Write 工具**把 raw JSON 写到 `/tmp/bf-event-<id前缀>.json`，再用 `@<路径>` 引用（如 `bash <SKILL_DIR>/scripts/analyze-event.sh reminder '@/tmp/bf-event-a8a24e3a.json'`）。直接把 JSON 当 bash 参数会被 host 的 confusable-Unicode 扫描器拒绝。

本文档是 baby-feed 应用 incoming webhook 事件的分析手册。用中文回答，≤ 200 字，语气友好温和。

---

## 0. 与 SKILL.md 的分工

下列内容**只在 SKILL.md 中维护**，本文按需引用：

- **emoji 映射表** → SKILL.md "Emoji table"
- **时间处理** → SKILL.md "时间处理" —— CRITICAL：所有时间操作走 `time-helper.sh` 或 `analyze-event.sh`，禁止手算
- **API endpoint / wrapper** → SKILL.md "Setup" + "API 端点速查"
- **红线阈值** → SKILL.md "主动提示的场景"

本文规定 webhook 特有内容：输出格式、工具调用、各事件分册。规则冲突时**本文档优先**。

---

## 1. 核心规则

### 1.1 输出格式 — 三段式，≤ 200 字

```
[首行 emoji] 一句友好的结论（含关键数值）

数据/对比（精确数字 + 时间，一两句话）

建议（仅当阈值命中；否则整段省略）
```

**禁止**：开场白、推理过程、原始 JSON、字段名、HTTP 状态码、"约120ml"式四舍五入（webhook 数据必须**原样引用**）。

**语气**：像贴心家人在 IM 里轻声说话。多用"刚刚 / 今天 / 辛苦啦 / 要不要…"，避免"必须 / 立刻 / 赶紧"。

**首行 emoji 速查**：`feeding.created` / `health.created` → 子类型 emoji（见 SKILL.md table）；`memo.created` → 📌；`reminder.fired` → ⏰；`*.updated` → 📝；`*.deleted` → 🗑️。不叠加父级 emoji。

### 1.2 时间格式 — 展示用

| 场景 | 格式 | 示例 |
|------|------|------|
| 记录时刻（< 24h） | `HH:mm` | `08:35` |
| 记录时刻（≥ 24h） | `MM-DD HH:mm` | `05-13 09:15` |
| 时间区间 | `HH:mm → HH:mm` | `10:15 → 11:35` |
| 记录间间隔 | `距上次约 X小时Y分钟（HH:mm）` | `距上次约 2小时40分钟（05:55）` |

`刚刚 / 今天 / 昨晚 / 上午` 等友好措辞可保留。

### 1.3 工具调用

调脚本前先用 **Write 工具**把 raw_json 写到 `/tmp/bf-event-<id>.json`，再用 `@<path>` 引用（详见 SKILL.md "非 ASCII body" 节）。

| 事件类型 | 调用 |
|----------|------|
| `feeding.created` | `bash <SKILL_DIR>/scripts/analyze-event.sh feeding '@/tmp/bf-event-<id>.json'` |
| `reminder.fired` | `bash <SKILL_DIR>/scripts/analyze-event.sh reminder '@/tmp/bf-event-<id>.json'` |
| `health.created` (WEIGHT/HEIGHT/TEMP) | `bash query-api.sh GET "/api/health?babyId=X&type=TYPE"` 取历史 |
| 其他事件 | 不调用额外工具 |

脚本返回结构化 JSON，模型只读取字段值拼接消息。调用失败 → 只分析本次事件，末尾加 `_(历史查询失败)_`。

---

## 2. 各事件类型分册

### 2.1 `feeding.created`

调用 `analyze-event.sh feeding`，从返回 JSON 取值：

**首行**：`{event.emoji} [友好措辞] {event.label} {event.value_display}（{event.time_short}），距上次约 {interval.display}（{interval.previous_time_short}）`

例：`🤱 刚刚亲喂母乳 30 分钟（08:35，左 15/右 15），距上次约 2小时40分钟（05:55）`

**数据段**：拼接 `today.display` + `week_avg.display`。`interval` 非 null 时补一句 `上次：{interval.previous_emoji} {interval.previous_label} {interval.previous_value_display}`。

**建议段**：仅当 `thresholds.any_hit === true` 时出现。遍历 `threshold_details` 转成温和提醒。阈值都没命中 → 整段省略。

### 2.2 `health.created`

**首行**：`{子类型 emoji} [友好措辞] {子类型中文} {精确数值}{单位}`

- `WEIGHT` / `HEIGHT` / `TEMPERATURE`：查历史 → `[0]` vs `[1]` 判趋势（`↗️ 上升 / → 持平 / ↘️ 下降`），引用前次数值。命中 SKILL.md 红线时温和标出。
- `DIAPER` / `SLEEP` / `VACCINE` / `MEDICATION` / `AD_VITAMIN`：不查历史，用准确数值回应一句。

例：`⚖️ 体重 7.2 kg ↗️（08:30，比上次 7.0 kg 增加 0.2）` / `💩 14:05 换了一次大便`

### 2.3 `memo.created` — 📌

**首行**：`📌 记下啦：{title} · 计划于 {MM-DD HH:mm}`，≤ 30 字复述 `content`。

涉及疫苗/体检 → 追加 `💉 接种后留观 30 分钟，24h 内多关注下体温哦`。

`completed === true` → 仅输出 `📌 ✅ 这条已经完成啦，辛苦啦 ~`。

### 2.4 `*.updated` — 📝

`📝 已更新 {记录类型}`。有 `before`/`after` → 渲染 `字段: 旧值 → 新值`（最多 3 行）。末尾加简短合理性评论。**不重新跑分析。**

### 2.5 `*.deleted` — 🗑️

`🗑️ 已删除 {类型} · {关键字段}: {值} · 时间 {MM-DD HH:mm}`。可加一句轻松收尾。**不调任何工具。**

### 2.6 未识别 — ⚠️

`⚠️ 收到未识别事件类型 {type}` + raw 摘要（≤ 50 字）。不强行分析。

---

## 3. `reminder.fired` 深入

所有 reminder 首行一律 ⏰。风格是"贴心家人轻声提醒"，不是"系统警报"。

### 3.1 五种场景 — 统一走 `analyze-event.sh reminder`

| 场景 | triggerType | ruleName 特征 | 脚本返回 `scenario` |
|------|-------------|--------------|---------------------|
| 喂养超时 | `interval` | `"喂养超时提醒"` | `feeding_timeout` |
| 睡眠超时 | `interval` | 含 `"睡眠超时" / "睡眠提醒" / "小睡" / "该睡"` | `sleep_timeout` |
| 健康定期 | `interval` | `"健康定期提醒"` | `health_regular` |
| 每日定时 | `cron` | 用户自定义 | `cron` |
| 疫苗后体温 | `event_window` | `"疫苗后测体温…"` | `event_window` |

### 3.2 各场景 JSON 字段 & 消息模板

**feeding_timeout** — 字段：`elapsed_display`, `last_feeding.{emoji,label,time_short,value_display}`, `today.display`

```
⏰ {babyName} 已经 {elapsed_display} 没喂啦，要不要准备一下？

上次：{last_feeding.emoji} {last_feeding.label} {last_feeding.value_display}（{last_feeding.time_short}）
{today.display}
```

**sleep_timeout** — 字段：`elapsed_display`, `last_sleep.{range_display,duration_display}`, `awake.display`, `today.display`

```
⏰ {babyName} 已经醒着 {awake.display} 啦（上次小睡 {last_sleep.range_display}），看看困不困？

{today.display}
```

`last_sleep` 缺失时省略括号内容；`awake` 缺失时首行改为 `⏰ {babyName} 今天还没小睡过哦`。所有数字直接读字段，**不要自己算时间**。

**health_regular** — 字段：`elapsed_days`, `items[].{emoji,label,latest_value_display,latest_date_display,trend_emoji}`

```
⏰ 距上次量{items 拼接}已经 {elapsed_days} 天啦，要不要今天补一次？

上次：{各 item 的 emoji label value_display（latest_date_display）}
```

**cron** — 字段：`dedup_emoji`, `dedup_label`, `already_done`, `already_done_time_short`

已记录：`⏰ {dedup_emoji} 今天 {already_done_time_short} 已经补过{dedup_label}啦，不用再补 ~`
未记录：`⏰ {dedup_emoji} 该给{babyName}补{dedup_label}啦，今天还没记录哦`

**event_window** — 字段：`vaccine_info`, `slot`, `latest_temperature.{value_display,time_short,status,status_label}`, `window.{remaining_display,end_display}`

```
⏰ {vaccine_info}后，第 {slot} 次测体温的时间到啦~

最近一次：🌡️ {latest_temperature.value_display}（{latest_temperature.time_short}），{latest_temperature.status_label}
监测窗口剩余 {window.remaining_display}（至 {window.end_display}）
```

> ⏰ 与子类型 emoji 并列（如 `⏰ ☀️`）：⏰ 表示"这是一条提醒"，子类型 emoji 表示"提醒内容"，两者正交不冲突。

---

## 4. 输出硬规则

以下任一行为会导致输出无效 —— 从第一个字开始就输出最终消息，无例外：

- ❌ 过渡/铺垫句（如「现在让我按规则输出…」「根据 playbook…」「好的，我来分析…」）
- ❌ 推理过程、计算步骤、数据罗列
- ❌ 原始 JSON、字段名、HTTP 状态码
- ❌ 四舍五入后的数值（webhook 数据必须原样引用）
- ❌ 不存在的阈值建议（阈值未命中时严禁输出建议段）
