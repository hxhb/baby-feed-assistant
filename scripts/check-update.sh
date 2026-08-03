#!/usr/bin/env bash

# Read-only update discovery for the baby-feed-assistant Git submodule.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REMOTE_NAME="origin"
REMOTE_BRANCH="master"
REMOTE_REF="refs/remotes/$REMOTE_NAME/$REMOTE_BRANCH"
TRUSTED_FETCH_URL="https://github.com/hxhb/baby-feed-assistant.git"
FETCH_TIMEOUT_SECONDS=20

emit_result() {
  local status="$1" reason="$2" local_version="$3" remote_version="$4"
  local local_commit="$5" remote_commit="$6" ahead="$7" behind="$8" dirty="$9"
  export CU_STATUS="$status" CU_REASON="$reason"
  export CU_LOCAL_VERSION="$local_version" CU_REMOTE_VERSION="$remote_version"
  export CU_LOCAL_COMMIT="$local_commit" CU_REMOTE_COMMIT="$remote_commit"
  export CU_AHEAD="$ahead" CU_BEHIND="$behind" CU_DIRTY="$dirty"
  python3 <<'PYEOF'
import json
import os

behind = int(os.environ.get("CU_BEHIND", "0") or 0)
result = {
    "status": os.environ["CU_STATUS"],
    "updateAvailable": behind > 0,
    "localVersion": os.environ.get("CU_LOCAL_VERSION") or None,
    "remoteVersion": os.environ.get("CU_REMOTE_VERSION") or None,
    "localCommit": os.environ.get("CU_LOCAL_COMMIT") or None,
    "remoteCommit": os.environ.get("CU_REMOTE_COMMIT") or None,
    "ahead": int(os.environ.get("CU_AHEAD", "0") or 0),
    "behind": behind,
    "dirty": os.environ.get("CU_DIRTY") == "true",
}
reason = os.environ.get("CU_REASON", "")
if reason:
    result["reason"] = reason
print(json.dumps(result, ensure_ascii=False))
PYEOF
}

read_version_file() {
  python3 - "$1" <<'PYEOF'
import re
import sys

try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    raise SystemExit(1)

match = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
if not match:
    raise SystemExit(1)

frontmatter = match.group(1)
version = None
in_metadata = False
for line in frontmatter.splitlines():
    if re.fullmatch(r"metadata:\s*", line):
        in_metadata = True
        continue
    if line and not line.startswith((" ", "\t")):
        in_metadata = False
    candidate = re.fullmatch(r"version:\s*['\"]?([^'\"\s]+)['\"]?\s*", line)
    nested = re.fullmatch(r"\s+version:\s*['\"]?([^'\"\s]+)['\"]?\s*", line)
    if candidate or (in_metadata and nested):
        version = (candidate or nested).group(1)
        break

if not version or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", version):
    raise SystemExit(1)
print(version)
PYEOF
}

fetch_remote() {
  python3 - "$SKILL_DIR" "$TRUSTED_FETCH_URL" "$REMOTE_BRANCH" "$REMOTE_REF" "$FETCH_TIMEOUT_SECONDS" <<'PYEOF'
import os
import subprocess
import sys

skill_dir, remote_url, remote_branch, remote_ref, timeout_raw = sys.argv[1:]
environment = os.environ.copy()
environment["GIT_TERMINAL_PROMPT"] = "0"

try:
    subprocess.run(
        [
            "git",
            "-C",
            skill_dir,
            "fetch",
            "--quiet",
            "--no-tags",
            remote_url,
            f"+refs/heads/{remote_branch}:{remote_ref}",
        ],
        check=True,
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=int(timeout_raw),
    )
except (OSError, subprocess.SubprocessError, ValueError):
    raise SystemExit(1)
PYEOF
}

local_version="$(read_version_file "$SKILL_DIR/SKILL.md" 2>/dev/null || true)"

if ! command -v git >/dev/null 2>&1 || ! git -C "$SKILL_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  emit_result "unavailable" "not_a_git_repository" "$local_version" "" "" "" 0 0 false
  exit 0
fi

remote_url="$(git -C "$SKILL_DIR" remote get-url "$REMOTE_NAME" 2>/dev/null || true)"
case "$remote_url" in
  git@github.com:hxhb/baby-feed-assistant.git|https://github.com/hxhb/baby-feed-assistant.git|ssh://git@github.com/hxhb/baby-feed-assistant.git) ;;
  *)
    emit_result "unavailable" "untrusted_origin" "$local_version" "" "" "" 0 0 false
    exit 0
    ;;
esac

local_commit="$(git -C "$SKILL_DIR" rev-parse --verify HEAD 2>/dev/null || true)"
dirty=false
if [[ -n "$(git -C "$SKILL_DIR" status --porcelain --untracked-files=normal 2>/dev/null || true)" ]]; then
  dirty=true
fi

if ! fetch_remote; then
  emit_result "unavailable" "fetch_failed" "$local_version" "" "$local_commit" "" 0 0 "$dirty"
  exit 0
fi

remote_commit="$(git -C "$SKILL_DIR" rev-parse --verify "$REMOTE_REF" 2>/dev/null || true)"
if [[ -z "$local_commit" || -z "$remote_commit" ]]; then
  emit_result "unavailable" "missing_revision" "$local_version" "" "$local_commit" "$remote_commit" 0 0 "$dirty"
  exit 0
fi

counts="$(git -C "$SKILL_DIR" rev-list --left-right --count "$local_commit...$remote_commit" 2>/dev/null || true)"
read -r ahead behind <<< "$counts"
if [[ ! "${ahead:-}" =~ ^[0-9]+$ || ! "${behind:-}" =~ ^[0-9]+$ ]]; then
  emit_result "unavailable" "comparison_failed" "$local_version" "" "$local_commit" "$remote_commit" 0 0 "$dirty"
  exit 0
fi

remote_skill="$(mktemp "${TMPDIR:-/tmp}/bf-skill-remote.XXXXXX")"
trap 'rm -f "$remote_skill"' EXIT
chmod 600 "$remote_skill"
git -C "$SKILL_DIR" show "$REMOTE_REF:SKILL.md" > "$remote_skill" 2>/dev/null || true
remote_version="$(read_version_file "$remote_skill" 2>/dev/null || true)"

status="up_to_date"
if (( behind > 0 && ahead > 0 )); then
  status="diverged"
elif (( behind > 0 )); then
  status="update_available"
elif (( ahead > 0 )); then
  status="local_ahead"
fi

emit_result "$status" "" "$local_version" "$remote_version" "$local_commit" "$remote_commit" "$ahead" "$behind" "$dirty"
