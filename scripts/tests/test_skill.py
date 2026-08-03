#!/usr/bin/env python3

import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parents[2]
SCRIPTS = SKILL_DIR / "scripts"


def run(*args: str, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    result = subprocess.run(args, text=True, capture_output=True, env=merged_env)
    if check and result.returncode != 0:
        raise AssertionError(
            f"command failed ({result.returncode}): {' '.join(args)}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result


def time_helper(*args: str) -> str:
    return run("bash", str(SCRIPTS / "time-helper.sh"), *args).stdout.strip()


def test_time_helper() -> None:
    assert time_helper("ensure-tz", "2026-06-04T07:00:00Z") == "2026-06-04T15:00:00+08:00"
    assert time_helper("ensure-tz", "2026-06-04T07:00:00+00:00") == "2026-06-04T15:00:00+08:00"
    assert time_helper("ensure-tz", "2026-06-04T15:00") == "2026-06-04T15:00:00+08:00"
    assert time_helper("date-of", "2026-05-14T23:30:00Z") == "2026-05-15"
    assert time_helper("shift", "2026-06-04T15:00:00+08:00", "-120") == "2026-06-04T13:00:00+08:00"
    assert time_helper("date-shift", "2026-06-04", "-1") == "2026-06-03"
    assert time_helper("age", "2025-12-20T00:00:00+08:00", "2026-08-03T12:00:00+08:00") == "7个月14天"

    invalid = run("bash", str(SCRIPTS / "time-helper.sh"), "ensure-tz", "not-a-date", check=False)
    assert invalid.returncode != 0
    naive = run("bash", str(SCRIPTS / "time-helper.sh"), "to-beijing", "2026-06-04T07:00:00", check=False)
    assert naive.returncode != 0


def test_decode_json() -> None:
    with tempfile.TemporaryDirectory() as directory:
        payload = Path(directory) / "payload.json"
        payload.write_text(r'{"name":"\u70c1\u70c1"}', encoding="utf-8")
        os.chmod(payload, 0o644)
        run("bash", str(SCRIPTS / "decode-json.sh"), str(payload))
        assert json.loads(payload.read_text(encoding="utf-8"))["name"] == "烁烁"
        assert stat.S_IMODE(payload.stat().st_mode) == 0o600

        link = Path(directory) / "payload-link.json"
        link.symlink_to(payload)
        rejected = run("bash", str(SCRIPTS / "decode-json.sh"), str(link), check=False)
        assert rejected.returncode != 0


def test_query_api() -> None:
    with tempfile.TemporaryDirectory() as directory:
        temp_dir = Path(directory)
        config = temp_dir / "config.local"
        config.write_text(
            "BABY_FEED_BASE_URL=https://baby-feed.test\n"
            "BABY_FEED_API_KEY=test-key\n",
            encoding="utf-8",
        )

        fake_curl = temp_dir / "curl"
        fake_curl.write_text(
            r'''#!/usr/bin/env bash
set -euo pipefail
authorized="false"
response='[{"id":"first","meta":{"value":1}},{"id":"second"}]'
while (($#)); do
  case "$1" in
    --header)
      [[ "${2:-}" == "Authorization: Bearer test-key" ]] && authorized="true"
      shift 2
      ;;
    --data-binary)
      response="${2:-}"
      shift 2
      ;;
    *) shift ;;
  esac
done
if [[ "$authorized" != "true" ]]; then
  printf '%s\n%s' '{"error":"unauthorized"}' '401'
else
  printf '%s\n%s' "$response" '200'
fi
''',
            encoding="utf-8",
        )
        fake_curl.chmod(0o700)

        env = {
            "BABY_FEED_CONFIG_PATH": str(config),
            "PATH": f"{temp_dir}{os.pathsep}{os.environ['PATH']}",
        }
        query = str(SCRIPTS / "query-api.sh")

        first_id = run("bash", query, "GET", "/api/test", "", "0.id", env=env)
        assert first_id.stdout.strip() == "first"
        sliced = run("bash", query, "GET", "/api/test", "", "[:1]", env=env)
        assert json.loads(sliced.stdout) == [{"id": "first", "meta": {"value": 1}}]

        body_file = temp_dir / "body.json"
        body_file.write_text('{"title":"中文备忘"}', encoding="utf-8")
        posted = run("bash", query, "POST", "/api/test", f"@{body_file}", env=env)
        assert json.loads(posted.stdout) == {"title": "中文备忘"}

        injection = run(
            "bash", query, "GET", "/api/test", "", "__import__('os')", env=env, check=False
        )
        assert injection.returncode != 0
        bad_path = run("bash", query, "GET", "/not-api", env=env, check=False)
        assert bad_path.returncode != 0


def test_check_update() -> None:
    with tempfile.TemporaryDirectory() as directory:
        temp_dir = Path(directory)
        fake_git = temp_dir / "git"
        fake_git.write_text(
            r'''#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "$args" in
  *"rev-parse --git-dir"*) printf '%s\n' '.git' ;;
  *"remote get-url origin"*) printf '%s\n' "${FAKE_REMOTE_URL:-git@github.com:hxhb/baby-feed-assistant.git}" ;;
  *"status --porcelain"*) ;;
  *"fetch --quiet --no-tags"*) ;;
  *"rev-parse --verify HEAD"*) printf '%s\n' '1111111111111111111111111111111111111111' ;;
  *"rev-parse --verify refs/remotes/origin/master"*) printf '%s\n' '2222222222222222222222222222222222222222' ;;
  *"rev-list --left-right --count"*) printf '%s\n' '0 3' ;;
  *"show refs/remotes/origin/master:SKILL.md"*)
    printf '%s\n' '---' 'name: baby-feed-assistant' 'metadata:' '  version: "2.13.0"' 'description: test' '---'
    ;;
  *) printf 'unexpected git call: %s\n' "$args" >&2; exit 1 ;;
esac
''',
            encoding="utf-8",
        )
        fake_git.chmod(0o700)
        env = {"PATH": f"{temp_dir}{os.pathsep}{os.environ['PATH']}"}

        result = run("bash", str(SCRIPTS / "check-update.sh"), env=env)
        update = json.loads(result.stdout)
        assert update["status"] == "update_available"
        assert update["updateAvailable"] is True
        assert update["localVersion"] == "2.12.0"
        assert update["remoteVersion"] == "2.13.0"
        assert update["behind"] == 3

        untrusted = run(
            "bash",
            str(SCRIPTS / "check-update.sh"),
            env={**env, "FAKE_REMOTE_URL": "https://example.com/untrusted.git"},
        )
        rejected = json.loads(untrusted.stdout)
        assert rejected["status"] == "unavailable"
        assert rejected["reason"] == "untrusted_origin"


MOCK_QUERY = r'''#!/usr/bin/env bash
set -euo pipefail
endpoint="${2:-}"
if [[ "$endpoint" == *"/api/stats?"* ]]; then
  printf '%s\n' '{"lastDays":[{"formulaCount":2,"totalFormulaAmount":200}],"todayStats":{}}'
elif [[ "$endpoint" == *"/api/feeding?"* ]]; then
  printf '%s\n' '[{"id":"feed-current","type":"FORMULA","startTime":"2026-06-04T06:00:00Z","formulaAmount":120},{"id":"feed-previous","type":"FORMULA","startTime":"2026-06-04T03:00:00Z","formulaAmount":80}]'
elif [[ "$endpoint" == *"/api/sleep-summary?"* ]]; then
  printf '%s\n' '{"totalMinutes":90,"count":1,"segments":[{"segmentStart":"2026-06-04T05:00:00Z","segmentEnd":"2026-06-04T06:30:00Z","segmentMinutes":90}]}'
elif [[ "$endpoint" == *"type=DIAPER"* ]]; then
  printf '%s\n' '[{"id":"health-1","type":"DIAPER","diaperType":"POOP","diaperStatus":"正常","recordedAt":"2026-06-04T06:00:00Z"}]'
elif [[ "$endpoint" == *"type=TEMPERATURE"* ]]; then
  printf '%s\n' '[{"id":"temp-1","type":"TEMPERATURE","temperature":37.2,"recordedAt":"2026-06-04T06:00:00Z"}]'
else
  printf '%s\n' '[]'
fi
'''


def analyze(mock_query: Path, command: str, payload: dict[str, object]) -> dict[str, object]:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".json", delete=False) as handle:
        json.dump(payload, handle, ensure_ascii=False)
        path = handle.name
    try:
        result = run(
            "bash",
            str(SCRIPTS / "analyze-event.sh"),
            command,
            f"@{path}",
            env={"BABY_FEED_QUERY_SCRIPT": str(mock_query)},
        )
        return json.loads(result.stdout)
    finally:
        os.unlink(path)


def test_analyze_event() -> None:
    with tempfile.TemporaryDirectory() as directory:
        mock_query = Path(directory) / "mock-query.sh"
        mock_query.write_text(MOCK_QUERY, encoding="utf-8")

        feeding = analyze(
            mock_query,
            "feeding",
            {
                "id": "delivery-id",
                "type": "feeding.created",
                "data": {
                    "recordId": "feed-current",
                    "babyId": "baby-id",
                    "type": "FORMULA",
                    "startTime": "2026-06-04T06:00:00Z",
                    "formulaAmount": 120,
                },
            },
        )
        assert feeding["event"]["value_display"] == "120 ml"
        assert feeding["interval"]["previous_value_display"] == "80 ml"
        assert feeding["interval"]["minutes"] == 180
        assert feeding["day"]["same_type_sessions"] == 2
        assert feeding["day"]["date"] == "2026-06-04"
        assert feeding["day"]["is_today"] is False
        assert feeding["day"]["display"].startswith("2026-06-04累计")
        assert feeding["week_avg"] is None
        assert feeding["status"] == "ok"

        today = time_helper("today")
        current_feeding = analyze(
            mock_query,
            "feeding",
            {
                "type": "feeding.created",
                "data": {
                    "recordId": "feed-current",
                    "babyId": "baby-id",
                    "type": "FORMULA",
                    "startTime": f"{today}T14:00:00+08:00",
                    "formulaAmount": 120,
                },
            },
        )
        assert current_feeding["day"]["is_today"] is True
        assert current_feeding["day"]["display"].startswith("今天累计")
        assert current_feeding["week_avg"]["value"] == 100.0

        generic_cron = analyze(
            mock_query,
            "reminder",
            {
                "type": "reminder.fired",
                "data": {
                    "triggerType": "cron",
                    "ruleName": "喝水提醒",
                    "babyId": "baby-id",
                    "babyName": "烁烁",
                    "title": "记得喝水",
                    "body": None,
                    "context": {"cronExpr": "0 11 * * *"},
                },
            },
        )
        assert generic_cron["scenario"] == "cron"
        assert generic_cron["generic"] is True
        assert generic_cron["title"] == "记得喝水"

        sleep = analyze(
            mock_query,
            "reminder",
            {
                "type": "reminder.fired",
                "data": {
                    "triggerType": "interval",
                    "ruleName": "小睡提醒",
                    "babyId": "baby-id",
                    "babyName": "烁烁",
                    "title": "该睡觉了",
                    "body": "",
                    "context": {"elapsedMinutes": 120},
                },
            },
        )
        assert sleep["scenario"] == "sleep_timeout"
        assert sleep["last_sleep"]["duration_display"] == "1小时30分钟"

        generic_window = analyze(
            mock_query,
            "reminder",
            {
                "type": "reminder.fired",
                "data": {
                    "triggerType": "event_window",
                    "ruleName": "通用观察窗口",
                    "babyId": "baby-id",
                    "babyName": "烁烁",
                    "title": "观察时间到了",
                    "body": "记录一下情况",
                    "context": {"slot": 2, "windowEnd": "2026-06-05T00:00:00Z"},
                },
            },
        )
        assert generic_window["scenario"] == "generic_event_window"

        health = analyze(
            mock_query,
            "reminder",
            {
                "type": "reminder.fired",
                "data": {
                    "triggerType": "interval",
                    "ruleName": "健康定期提醒",
                    "babyId": "baby-id",
                    "babyName": "烁烁",
                    "title": "该关注大小便了",
                    "body": "定期提醒：大小便",
                    "context": {"elapsedMinutes": 1440},
                },
            },
        )
        assert health["scenario"] == "health_regular"
        assert health["items"][0]["type"] == "DIAPER"
        assert health["items"][0]["latest_value_display"] == "大便 正常"


def test_static_contracts() -> None:
    skill = (SKILL_DIR / "SKILL.md").read_text(encoding="utf-8")
    frontmatter = skill.split("---", 2)[1]
    assert "\nversion:" not in frontmatter
    assert '  version: "2.12.0"' in frontmatter
    assert "raw.githubusercontent.com" not in skill
    assert "/api/stats?babyId=ID&days=1" in skill
    assert "signature-verified webhook" in skill

    api_reference = (SKILL_DIR / "references" / "api.md").read_text(encoding="utf-8")
    assert "no more than one day in the future" in api_reference
    assert "up to five years in the future" in api_reference
    assert 'activeSchedule` is an object shaped as `{ "windows"' in api_reference

    query = (SCRIPTS / "query-api.sh").read_text(encoding="utf-8")
    assert "result = $FILTER" not in query
    updater = (SCRIPTS / "check-update.sh").read_text(encoding="utf-8")
    assert "raw.githubusercontent.com" not in updater
    assert "fast-forward" not in updater
    analyzer = (SCRIPTS / "analyze-event.sh").read_text(encoding="utf-8")
    assert '"data.recordId"' in analyzer
    assert 'call_time date-of "$startTime"' in analyzer
    assert 'temp_status = "发烧"' not in analyzer
    assert 'temp_status = "低烧"' not in analyzer

    playbook = (SKILL_DIR / "resources" / "webhook-analysis.md").read_text(encoding="utf-8")
    assert "data.changes" in playbook
    assert "changes.completed.new" in playbook


def main() -> None:
    tests = [
        test_time_helper,
        test_decode_json,
        test_query_api,
        test_check_update,
        test_analyze_event,
        test_static_contracts,
    ]
    for test in tests:
        test()
        print(f"ok - {test.__name__}")
    print(f"{len(tests)} test groups passed")


if __name__ == "__main__":
    main()
