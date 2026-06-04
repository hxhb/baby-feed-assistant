---
name: baby-feed-assistant
version: 2.10.1
description: "Query and manage baby feeding, health, growth, sleep and reminder data through the Baby Feed HTTP API. Trigger on any English or Chinese mention of: feeding/nursing/formula/breast-milk/solid-food (喂奶/母乳/瓶喂/奶粉/辅食), diapers (尿布/大便/小便), sleep (睡眠/小睡/夜醒), weight/height/temperature (体重/身高/体温), vitamin AD or medication (AD/维生素/用药), vaccines (疫苗/打针), memos and reminders (备忘/待办/提醒), or daily/weekly summaries (今天/本周/情况/统计). Trigger on BOTH queries ('宝宝今天吃了多少', '上次体温', '下次疫苗什么时候') AND recording requests ('记录一下刚喂奶', '宝宝刚拉了'). Also use this skill when handling incoming webhook events: `feeding.created` / `health.created` / `memo.created` / `reminder.fired`, plus their `*.updated` and `*.deleted` variants."
---

# Baby Feed Assistant

通过 Baby Feed HTTP API 查询和管理喂养、健康、睡眠、生长、备忘数据，
并响应同一应用发出的 webhook 事件（`feeding.created` / `health.created` / `memo.created` / `reminder.fired` / `*.updated` / `*.deleted`）。

## Setup — wrapper 脚本

所有 API 调用都走 `<SKILL_DIR>/scripts/query-api.sh`，它会从 `config.local` 读取凭据并自动加上 `Authorization` 头。

```bash
bash <SKILL_DIR>/scripts/query-api.sh GET    "/api/endpoint?param=value"
bash <SKILL_DIR>/scripts/query-api.sh POST   "/api/endpoint" '{"key":"value"}'
bash <SKILL_DIR>/scripts/query-api.sh PUT    "/api/endpoint/id" '{"key":"value"}'
bash <SKILL_DIR>/scripts/query-api.sh DELETE "/api/endpoint/id"
```

**在 wrapper 内部过滤响应** —— 第 4 个参数传一个 Python 表达式（`d` 是已解析的 JSON）。GET 时第 3 个参数留空字符串：

```bash
bash <SKILL_DIR>/scripts/query-api.sh GET "/api/babies"                 "" "d[0]['id']"
bash <SKILL_DIR>/scripts/query-api.sh GET "/api/stats?babyId=X&days=7" "" "d['todayStats']"
```

⚠️ 不要在 wrapper **外部**把输出 pipe 给 `python3` / `jq`（会触发 host 的pipe-to-interpreter 检查）。要么用第 4 参数 FILTER，要么读原始 JSON。

---

## 时间处理 — CRITICAL：只走脚本，禁止手算

> **所有时间操作必须通过 `<SKILL_DIR>/scripts/time-helper.sh` 完成。**
> 本条高于其他所有规则。违反时间规则的记录会差 8 小时，是最常见的 bug。

**禁止行为：**
- ❌ 手动写 `+08:00` 后缀 —— 用 `time-helper.sh ensure-tz` 或 `now`
- ❌ 手动写 UTC 时间戳 —— 你不知道当前 UTC 时间
- ❌ 手动心算 `+8h` 转换 —— 用 `time-helper.sh to-beijing`
- ❌ 硬编码日期字符串（如 `date=2026-06-04`）—— 用 `time-helper.sh today`
- ❌ 在 `date` 命令里手动写 `-d '+8 hours'` 格式串 —— 那是旧方式，用 `time-helper.sh`

**正确做法 —— 四种场景，四个子命令：**

```bash
bash <SKILL_DIR>/scripts/time-helper.sh now                      # → 2026-06-04T15:30:00+08:00（POST body 直接用）
bash <SKILL_DIR>/scripts/time-helper.sh today                    # → 2026-06-04（GET ?date= 直接用）
bash <SKILL_DIR>/scripts/time-helper.sh to-beijing "2026-05-15T07:00:00.000Z"  # → 2026-05-15 15:00（展示用）
bash <SKILL_DIR>/scripts/time-helper.sh ensure-tz "2026-06-04T15:00"           # → 2026-06-04T15:00:00+08:00（补全+08:00）
```

- **POST 时**：用户给的时间字符串用 `ensure-tz` 补后缀；没有时间字段就用 `now` 取当前时间。
- **展示时**：API 响应里的 `Z` 结尾时间戳用 `to-beijing` 转换后再给用户看。
- **GET `?date=`**：用 `today` 取当前北京日期，不要手动算。

### analyze-event.sh — Webhook 事件分析

对于 webhook 事件（`feeding.created` / `reminder.fired`），用 `analyze-event.sh` 完成所有确定性计算：

```bash
bash <SKILL_DIR>/scripts/analyze-event.sh feeding  '<raw_json>'
bash <SKILL_DIR>/scripts/analyze-event.sh reminder '<raw_json>'
```

该脚本自动完成 API 查询、时间换算、数学计算、阈值检查，返回结构化 JSON。
模型只读取 JSON 字段拼接最终消息，**不做任何额外计算**。

⚠️ 不要绕过 `analyze-event.sh` 手动调 `query-api.sh` 然后自己算——那正是本脚本要消除的流程。

---

## API 端点速查

📖 详细签名、字段表、JSON 响应结构见 `<SKILL_DIR>/references/api.md`。
下表只用于路由判断。

| 分组     | GET | 写入 |
|---|---|---|
| Baby     | `/api/babies`, `/api/babies/:id`                                   | — |
| Feeding  | `/api/feeding?babyId=&date=`                                       | `POST /api/feeding` |
| Health   | `/api/health?babyId=&type=&date=`                                  | `POST /api/health` |
| Sleep    | `/api/sleep-summary?babyId=&date=` *(查询睡眠首选)*                  | — |
| Stats    | `/api/stats/day?babyId=&date=`, `/api/stats?babyId=&days=`         | — |
| Memo     | `/api/memo?babyId=&completed=&date=&rangeDays=`                    | `POST /api/memo`, `PUT/DELETE /api/memo/:id` |
| Timeline | `/api/timeline-dates?babyId=`                                      | — |

**三条必须记住的坑（不用每次都翻 references）：**

- POST/PUT 所有时间字段**必须通过 `time-helper.sh` 生成**。涉及字段：`startTime`、
  `endTime`、`recordedAt`、`sleepStartTime`、`sleepEndTime`、`scheduledAt`。
  缺失 `+08:00` 后缀会导致存储差 8 小时。（见上方"时间处理"）
- **查询**睡眠用 `/api/sleep-summary`，**不要**用 `/api/health?type=SLEEP`
  —— summary 接口已处理跨午夜拆分。
- `stats.sleepDurationMinutes` **已经是累计且实时**的值。绝不要做
  `stats_total + latest_nap` —— 会重复计数。

---

## 工作流 & 决策表

### Step 1 — 确认宝宝
还没有就先 `GET /api/babies`，记下 `id` 和 `name` 在整段对话里复用。

### Step 2 — 选择 API（决策表）

| 用户意图 / 语句 | 调用的 API |
|---|---|
| "今天吃了多少" / 当日喂养概览 | `stats/day?date=today` |
| "今天宝宝怎么样" / 当日完整情况 | `stats/day` + `sleep-summary?date=today` + `health?date=today&type=DIAPER`（必要时加 `type=VACCINE` / `type=MEDICATION`） |
| "最近一周" / 周概览 / 多日趋势 | `stats?days=7`（或 14 / 30） |
| "上次喂奶是什么时候" | `feeding?date=today` → `[0]` |
| 指定某天的喂养明细 | `feeding?date=YYYY-MM-DD` |
| "今天换了几次尿布" | `health?type=DIAPER&date=today` |
| "今天睡了多久" | `sleep-summary?date=today`（查询睡眠绝不用 `health?type=SLEEP`） |
| "现在多重" / "最新体重" | `health?type=WEIGHT` → `[0]` |
| "现在多高" / "最新身高" | `health?type=HEIGHT` → `[0]` |
| "上次体温多少" | `health?type=TEMPERATURE` → `[0]` |
| "今天量了几次体温" | `health?type=TEMPERATURE&date=today` |
| 体重 / 身高趋势 | `stats?days=30` → `weightTrend[]` / `heightTrend[]` |
| "打过哪些疫苗" | `health?type=VACCINE` 或 `stats` → `vaccineRecords[]` |
| "吃过什么药" | `health?type=MEDICATION` |
| "宝宝多大了" | `babies/:id` 取 `birthDate` 计算年龄 |
| "哪些日子有记录" | `timeline-dates` |
| "有什么备忘 / 提醒 / 待办" | `memo?completed=false&date=today&rangeDays=30` |
| 记录：喂养 | `POST /api/feeding`（设 `type` + 对应 amount/duration） |
| 记录：尿布 / 体温 / 体重 / 身高 / AD / 疫苗 / 用药 / 睡眠 | `POST /api/health`（设 `type` + 对应字段） |
| 记录：未来提醒 / 备忘 | `POST /api/memo` |
| 标记备忘完成 | `PUT /api/memo/:id` `{"completed":true}` |

宽泛问题（如"今天怎么样"）**并行**调用多个 API，不要串行。

> **表中所有 `date=today` 都是 `date=$(bash <SKILL_DIR>/scripts/time-helper.sh today)` 的简写。**
> 不要传字面字符串 `"today"`，也不要手动写日期。每次 GET 请求前重新获取 `today`，不缓存。

### Step 3 — 记录事件流程

1. 解析用户说的 type、量、时间。
2. 关键字段缺失就**只问一个**最关键的问题。
3. **所有时间字段通过 `time-helper.sh` 获取**：
   - 用户没提时间 → 各时间字段用 `bash <SKILL_DIR>/scripts/time-helper.sh now`
   - 用户提了时间 → `bash <SKILL_DIR>/scripts/time-helper.sh ensure-tz "用户给的时间"`
   - 每个字段**重新调一次**，不要一次 `now` 复用给多个字段
4. 复述要记的内容，请用户确认。
5. POST。
6. 用关键信息回执确认成功。

---

## 输出规范

**默认中文，简洁。** 爸妈很累，少废话。

### Emoji table — 唯一映射表，不要自创

`Type (raw)` 列对应 API 记录与 webhook payload 中的 `type` 字段，其他文档（如 `resources/webhook-analysis.md`）按 raw type 引用本表，不再重复列 emoji。

| Emoji | Type (raw)            | 中文（展示）   |
|-------|-----------------------|---------------|
| 🤱    | `BREAST_MILK`         | 亲喂母乳        |
| 🍼    | `BREAST_MILK_BOTTLE`  | 瓶喂母乳        |
| 🍼    | `FORMULA`             | 配方奶          |
| 🥣    | `SOLID_FOOD`          | 辅食            |
| 💧    | `DIAPER` (`PEE`)      | 小便            |
| 💩    | `DIAPER` (`POOP`)     | 大便            |
| 💩💧  | `DIAPER` (`BOTH`)     | 大小便同次       |
| 😴    | `SLEEP`               | 睡眠            |
| 🌡️    | `TEMPERATURE`         | 体温            |
| ⚖️    | `WEIGHT`              | 体重            |
| 📏    | `HEIGHT`              | 身高            |
| ☀️    | `AD_VITAMIN`          | 维生素 AD       |
| 💉    | `VACCINE`             | 疫苗            |
| 💊    | `MEDICATION`          | 用药            |
| ⏰    | （备忘，无 raw type）   | 备忘 / 提醒     |

结构分隔用 ASCII 字符（`-`、`·`、`*`），不要在表外加装饰性 emoji。

### 当日小结模板（仅展示有数据的分类）

```
今天 (MM月DD日) {宝宝名字}的情况：

🤱 亲喂母乳：X次，共Y分钟（左Z/右W分钟）
🍼 瓶喂母乳：X次，共Y ml
🍼 配方奶：X次，共Y ml
🥣 辅食：食物名 × 量
💩 大便：X次    💧 小便：X次
😴 睡眠：共X小时Y分钟（N段）
  · 昨晚22:00-今早06:00（今天部分6小时）
  · 今天13:00-14:30（1.5小时）
🌡️ 体温：36.8°C
☀️ 维生素AD：已补充 / 今天还未补充
💉 疫苗：（如有当天记录）
💊 用药：药名 x N次（如有当天记录）
```

### 生长趋势输出

先 2-3 句结论，再附紧凑表格。生长明显放缓或加速时主动指出。

### 主动提示的场景（红线阈值）

以下阈值命中时主动提示一句（webhook 输出与日常聊天回复均适用，是**唯一**
红线清单 —— webhook playbook 通过引用使用，不重复列出）：

- 🌡️ `temperature` ≥ 37.5°C → 低烧（建议留意观察）
- 🌡️ `temperature` ≥ 38.5°C → 发烧（建议尽快就医）
- ⚖️ 2 周内体重净下降 → 关注喂养与精神状态
- 📏 身高 / 体重百分位明显偏离 → 建议咨询儿保医生（**不自行计算百分位数值**）
- 喂养量明显少于昨天 → 提一句变化
- 💩 连续 2 天以上没有大便 → 提一下

### 数字格式

合理时四舍五入（`约120ml`，不是 `119.5ml`）。单位：`ml` / `分钟` / `kg` /
`cm` / `°C`。

---

## 常见坑（前面没覆盖的）

| 坑 | 修正 |
|---|---|
| 把最新一段睡眠加到 `stats.sleepDurationMinutes` 上 | 它已经是累计值，不要加 |
| 用 `stats/day` 取体重 / 身高趋势 | 趋势在 `stats`（不是 `stats/day`），看 `weightTrend[]` / `heightTrend[]` |
| 用 `health?type=SLEEP` 查睡眠 | 改用 `/api/sleep-summary`（已处理跨午夜拆分） |
| 想要全部历史却传了 `date` | 去掉 `date`，会返回该 type 的所有记录 |
| 假设 `lastDays[]` 一定有体重/身高 | 仅在测量当天才有 |
| 忘了 `stats.medicationRecords[]` 受 `days` 限制 | 疫苗是全历史，用药不是 |
| 在 wrapper 外部把输出 pipe 给 python3/jq | 用第 4 个 FILTER 参数，或读原始 JSON |
| 手动构造时间字符串（手写 `+08:00`、心算 UTC+8） | 一律走 `time-helper.sh`（`now` / `ensure-tz` / `to-beijing` / `today`） |
| POST 时一次 `now` 复用到多个 time 字段 | 每个字段**单独调一次** `now`，不缓存 |
| API 响应时间直接展示（UTC 时间） | 所有展示前的时间串都过 `to-beijing` |

---

## Webhook 事件 —— 加载 playbook

当 incoming 消息是本应用的 webhook 事件（`type` 为 `feeding.created` / `health.created` / `memo.created` / `reminder.fired`，或任意 `*.updated` / `*.deleted` 变体）时：

1. 读取 `<SKILL_DIR>/resources/webhook-analysis.md`。
2. 严格按照其中的规则输出 —— 该文件是 webhook 输出格式、数据精度、工具调用纪律、各事件类型分册、`reminder.fired` 四种场景的**唯一权威**。
3. 本文档的 wrapper 脚本（§Setup）、时间规则（§时间处理）和 emoji table（§输出规范）依然适用，playbook 通过交叉引用使用，不重复定义。

每次事件都重新读一遍 playbook，让规则更新立即生效，不要凭记忆分析。

---

## Skill 更新检查（每次会话仅一次）

会话内**首次**调用时检查远程版本，**后续不要重复**（避免噪音网络请求）。

```bash
curl -sf "https://raw.githubusercontent.com/hxhb/baby-feed-assistant/refs/heads/master/SKILL.md" | head -5 | grep '^version:'
```

与本文 frontmatter 的 `version` 比较：

- 远程**更高** → 提示用户：`"baby-feed-assistant skill 有新版本（远程 X.Y.Z, 本地 {本文件 frontmatter 的 version}），建议更新："`
  ```bash
  BASE="https://raw.githubusercontent.com/hxhb/baby-feed-assistant/refs/heads/master"
  mkdir -p "<SKILL_DIR>/scripts" "<SKILL_DIR>/references" "<SKILL_DIR>/resources"
  curl -sf "$BASE/SKILL.md"                       -o "<SKILL_DIR>/SKILL.md"
  curl -sf "$BASE/scripts/query-api.sh"           -o "<SKILL_DIR>/scripts/query-api.sh" && chmod +x "<SKILL_DIR>/scripts/query-api.sh"
  curl -sf "$BASE/scripts/time-helper.sh"         -o "<SKILL_DIR>/scripts/time-helper.sh" && chmod +x "<SKILL_DIR>/scripts/time-helper.sh"
  curl -sf "$BASE/scripts/analyze-event.sh"       -o "<SKILL_DIR>/scripts/analyze-event.sh" && chmod +x "<SKILL_DIR>/scripts/analyze-event.sh"
  curl -sf "$BASE/references/api.md"              -o "<SKILL_DIR>/references/api.md"
  curl -sf "$BASE/references/time-handling.md"    -o "<SKILL_DIR>/references/time-handling.md"
  curl -sf "$BASE/resources/webhook-analysis.md"  -o "<SKILL_DIR>/resources/webhook-analysis.md"
  curl -sf "$BASE/resources/agent-prompt.txt"      -o "<SKILL_DIR>/resources/agent-prompt.txt"
  ```
- 相等 / 更低 / 不可达 → 保持沉默。
