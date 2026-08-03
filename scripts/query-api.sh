#!/usr/bin/env bash

# Usage: query-api.sh METHOD /api/path [JSON_BODY|@FILE] [JSON_SELECTOR]
# Selectors are restricted to object keys/list indexes (for example 0.id,
# todayStats) or a leading list slice (for example [:2]).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${BABY_FEED_CONFIG_PATH:-$SCRIPT_DIR/config.local}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: $CONFIG_PATH not found; copy config.local.example first" >&2
  exit 1
fi

BABY_FEED_BASE_URL=""
BABY_FEED_API_KEY=""

while IFS= read -r config_line || [[ -n "$config_line" ]]; do
  config_line="${config_line%$'\r'}"
  case "$config_line" in
    BABY_FEED_BASE_URL=*) BABY_FEED_BASE_URL="${config_line#*=}" ;;
    BABY_FEED_API_KEY=*) BABY_FEED_API_KEY="${config_line#*=}" ;;
  esac
done < "$CONFIG_PATH"

strip_outer_quotes() {
  local input="$1"
  if [[ ${#input} -ge 2 ]]; then
    local first="${input:0:1}"
    local last="${input: -1}"
    if [[ ( "$first" == '"' && "$last" == '"' ) || ( "$first" == "'" && "$last" == "'" ) ]]; then
      input="${input:1:${#input}-2}"
    fi
  fi
  printf '%s' "$input"
}

BABY_FEED_BASE_URL="$(strip_outer_quotes "$BABY_FEED_BASE_URL")"
BABY_FEED_API_KEY="$(strip_outer_quotes "$BABY_FEED_API_KEY")"

if [[ -z "$BABY_FEED_BASE_URL" || -z "$BABY_FEED_API_KEY" ]]; then
  echo "ERROR: BABY_FEED_BASE_URL and BABY_FEED_API_KEY are required" >&2
  exit 1
fi

case "$BABY_FEED_BASE_URL" in
  http://*|https://*) ;;
  *) echo "ERROR: BABY_FEED_BASE_URL must use http or https" >&2; exit 1 ;;
esac

METHOD="${1:-}"
ENDPOINT="${2:-}"
BODY="${3:-}"
SELECTOR="${4:-}"

METHOD="$(printf '%s' "$METHOD" | tr '[:lower:]' '[:upper:]')"
case "$METHOD" in
  GET|POST|PUT|DELETE) ;;
  *) echo "ERROR: METHOD must be GET, POST, PUT, or DELETE" >&2; exit 1 ;;
esac

if [[ "$ENDPOINT" != /api && "$ENDPOINT" != /api/* ]]; then
  echo "ERROR: endpoint must start with /api/" >&2
  exit 1
fi
if [[ "$ENDPOINT" == *$'\n'* || "$ENDPOINT" == *$'\r'* || "$ENDPOINT" == *'..'* ]]; then
  echo "ERROR: endpoint contains forbidden characters" >&2
  exit 1
fi

if [[ "$BODY" == @* ]]; then
  body_path="${BODY#@}"
  if [[ ! -f "$body_path" || ! -r "$body_path" ]]; then
    echo "ERROR: cannot read body file: $body_path" >&2
    exit 1
  fi
  BODY="$(<"$body_path")"
fi

URL="${BABY_FEED_BASE_URL%/}${ENDPOINT}"
CURL_ARGS=(
  --silent
  --show-error
  --connect-timeout 5
  --max-time 30
  --write-out $'\n%{http_code}'
  --request "$METHOD"
  --header "Authorization: Bearer $BABY_FEED_API_KEY"
  --header "Accept: application/json"
)

if [[ "$METHOD" == "GET" ]]; then
  CURL_ARGS+=(--retry 2 --retry-delay 1 --retry-connrefused)
fi

if [[ "$METHOD" == "POST" || "$METHOD" == "PUT" ]]; then
  CURL_ARGS+=(--header "Content-Type: application/json")
  if [[ -n "$BODY" ]]; then
    CURL_ARGS+=(--data-binary "$BODY")
  fi
fi

if ! RESPONSE="$(curl "${CURL_ARGS[@]}" "$URL")"; then
  echo "ERROR: API request failed before receiving an HTTP response" >&2
  exit 1
fi

HTTP_CODE="${RESPONSE##*$'\n'}"
RESPONSE_BODY="${RESPONSE%$'\n'*}"

if [[ ! "$HTTP_CODE" =~ ^[0-9]{3}$ ]]; then
  echo "ERROR: invalid HTTP status from curl" >&2
  exit 1
fi
if (( HTTP_CODE < 200 || HTTP_CODE >= 300 )); then
  printf '%s\n' "$RESPONSE_BODY" >&2
  echo "HTTP $HTTP_CODE" >&2
  exit 1
fi

if [[ -z "$SELECTOR" ]]; then
  printf '%s\n' "$RESPONSE_BODY"
  exit 0
fi

printf '%s' "$RESPONSE_BODY" | python3 -c '
import json
import re
import sys

selector = sys.argv[1]
data = json.load(sys.stdin)

slice_match = re.fullmatch(r"\[:([0-9]+)\]", selector)
if slice_match:
    if not isinstance(data, list):
        raise SystemExit("ERROR: slice selector requires a JSON list")
    result = data[: int(slice_match.group(1))]
else:
    result = data
    for token in selector.split("."):
        if re.fullmatch(r"[0-9]+", token):
            if not isinstance(result, list):
                raise SystemExit(f"ERROR: selector index {token} requires a JSON list")
            index = int(token)
            if index >= len(result):
                raise SystemExit(f"ERROR: selector index {token} is out of range")
            result = result[index]
        elif re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token):
            if not isinstance(result, dict) or token not in result:
                raise SystemExit(f"ERROR: selector key {token} was not found")
            result = result[token]
        else:
            raise SystemExit(f"ERROR: invalid selector token: {token}")

if isinstance(result, (dict, list)):
    print(json.dumps(result, ensure_ascii=False, indent=2))
elif result is None:
    print("null")
else:
    print(result)
' "$SELECTOR"
