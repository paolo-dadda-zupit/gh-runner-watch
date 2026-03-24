#!/usr/bin/env bash
set -uo pipefail

# --- Config di default (puoi override con file o argomenti) ---
RUNNER_DIR="/opt/github-runner/pipeline-agents2-container-1"
CONFIG_FILE="/etc/gh-runner-watch.conf"
MODE="manual"   # manual | scheduled

SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_CHANNEL_ID="${SLACK_CHANNEL_ID:-}"

# --- Primo pass: leggi solo --config, così poi carichi il file giusto ---
ARGS=("$@")
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  case "${ARGS[$i]}" in
    --config)
      ((i++))
      if [[ $i -ge ${#ARGS[@]} ]]; then
        echo "Valore mancante per --config" >&2
        exit 30
      fi
      CONFIG_FILE="${ARGS[$i]}"
      ;;
  esac
  ((i++))
done

# --- Carica config file (se esiste) ---
# Il file può contenere ad esempio:
# SLACK_BOT_TOKEN="xoxb-..."
# SLACK_CHANNEL_ID="C12345678"
# SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# --- Secondo pass: parse completo, così la CLI vince sul config file ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scheduled)
      MODE="scheduled"
      ;;
    --manual)
      MODE="manual"
      ;;
    --runner-dir)
      [[ $# -ge 2 ]] || { echo "Valore mancante per --runner-dir" >&2; exit 30; }
      RUNNER_DIR="$2"
      shift
      ;;
    --config)
      [[ $# -ge 2 ]] || { echo "Valore mancante per --config" >&2; exit 30; }
      CONFIG_FILE="$2"
      shift
      ;;
    --slack-webhook)
      [[ $# -ge 2 ]] || { echo "Valore mancante per --slack-webhook" >&2; exit 30; }
      SLACK_WEBHOOK_URL="$2"
      shift
      ;;
    --slack-bot-token)
      [[ $# -ge 2 ]] || { echo "Valore mancante per --slack-bot-token" >&2; exit 30; }
      SLACK_BOT_TOKEN="$2"
      shift
      ;;
    --slack-channel-id)
      [[ $# -ge 2 ]] || { echo "Valore mancante per --slack-channel-id" >&2; exit 30; }
      SLACK_CHANNEL_ID="$2"
      shift
      ;;
    --help|-h)
      echo "Uso: $0 [--manual|--scheduled] [--runner-dir PATH] [--config FILE] [--slack-webhook URL] [--slack-bot-token TOKEN] [--slack-channel-id ID]"
      exit 0
      ;;
    *)
      echo "Argomento non riconosciuto: $1" >&2
      exit 30
      ;;
  esac
  shift
done

SVC="${RUNNER_DIR%/}/svc.sh"

# --- Lock anti-overlap, specifico per runner ---
LOCK_NAME="$(printf '%s' "$RUNNER_DIR" | sed 's#[^A-Za-z0-9._-]#_#g')"
LOCK_FILE="/var/lock/gh-runner-watch.${LOCK_NAME}.lock"
if ! ( : >"$LOCK_FILE" ) 2>/dev/null; then
  LOCK_FILE="/tmp/gh-runner-watch.${LOCK_NAME}.lock"
fi

exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
fi

# --- Logging minimale ---
HOST="$(hostname -f 2>/dev/null || hostname)"
LOG_FILE="/var/log/gh-runner-watch.log"
if ! ( : >>"$LOG_FILE" ) 2>/dev/null; then
  LOG_FILE="${HOME:-/tmp}/gh-runner-watch.log"
fi

log() {
  local ts
  ts="$(date -Is)"
  echo "[$ts] $*" | tee -a "$LOG_FILE" >/dev/null
}

# --- Sudo (distingue tra interattivo e non interattivo) ---
SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if [[ "$MODE" == "scheduled" ]]; then
    SUDO="sudo -n"
  else
    SUDO="sudo"
  fi
fi

need_slack() {
  [[ "$MODE" == "scheduled" ]]
}

build_slack_webapi_payload() {
  local channel="$1"
  local text="$2"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$channel" "$text" <<'PY'
import json, sys
print(json.dumps({
    "channel": sys.argv[1],
    "text": sys.argv[2],
}))
PY
  elif command -v jq >/dev/null 2>&1; then
    jq -cn --arg channel "$channel" --arg text "$text" \
      '{channel: $channel, text: $text}'
  else
    log "Serve python3 o jq per costruire il payload Slack API"
    return 1
  fi
}

build_slack_webhook_payload() {
  local text="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$text" <<'PY'
import json, sys
print(json.dumps({
    "text": sys.argv[1],
}))
PY
  elif command -v jq >/dev/null 2>&1; then
    jq -cn --arg text "$text" '{text: $text}'
  else
    log "Serve python3 o jq per costruire il payload webhook"
    return 1
  fi
}

slack_api_response_ok() {
  local resp="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, json; d=json.load(sys.stdin); raise SystemExit(0 if d.get("ok") else 1)' <<<"$resp"
  elif command -v jq >/dev/null 2>&1; then
    jq -e '.ok == true' >/dev/null 2>&1 <<<"$resp"
  else
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<<"$resp"
  fi
}

slack_api_response_error() {
  local resp="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, json; d=json.load(sys.stdin); print(d.get("error", "unknown_error"))' <<<"$resp"
  elif command -v jq >/dev/null 2>&1; then
    jq -r '.error // "unknown_error"' <<<"$resp"
  else
    local err
    err="$(sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$resp" | head -n1)"
    printf '%s\n' "${err:-unknown_error}"
  fi
}

slack_send() {
  local text="$1"
  local payload resp err

  # 1) Preferisci bot token + channel id
  if [[ -n "${SLACK_BOT_TOKEN:-}" && -n "${SLACK_CHANNEL_ID:-}" ]]; then
    payload="$(build_slack_webapi_payload "$SLACK_CHANNEL_ID" "$text")" || return 1

    resp="$(
      curl -fsS -X POST 'https://slack.com/api/chat.postMessage' \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H 'Content-type: application/json; charset=utf-8' \
        --data "$payload"
    )" || {
      log "Errore HTTP verso Slack API"
      return 1
    }

    if slack_api_response_ok "$resp"; then
      return 0
    fi

    err="$(slack_api_response_error "$resp")"
    log "Slack API chat.postMessage fallita: ${err:-unknown_error}"
    return 1
  fi

  # 2) Fallback a webhook
  if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    payload="$(build_slack_webhook_payload "$text")" || return 1

    curl -fsS -X POST \
      -H 'Content-type: application/json' \
      --data "$payload" \
      "$SLACK_WEBHOOK_URL" >/dev/null || {
        log "Invio webhook Slack fallito"
        return 1
      }

    return 0
  fi

  log "Nessuna configurazione Slack disponibile (bot token/channel id o webhook)"
  return 1
}

notify() {
  local msg="$1"
  if need_slack; then
    slack_send "$msg" || true
  else
    printf "%b\n" "$msg"
  fi
}

run_status() {
  if [[ ! -x "$SVC" ]]; then
    log "ERRORE: svc.sh non trovato o non eseguibile: $SVC"
    notify "ERRORE: svc.sh non trovato o non eseguibile: $SVC"
    exit 30
  fi

  local out
  out="$(
    cd "$RUNNER_DIR" && $SUDO ./svc.sh status 2>&1 || true
  )"
  printf "%s" "$out"
}

is_running() {
  grep -Fq "active (running)"
}

is_oom_kill() {
  grep -Fq "Result: oom-kill"
}

restart_runner() {
  local out_stop out_start out_status
  out_stop="$(
    cd "$RUNNER_DIR" && $SUDO ./svc.sh stop 2>&1 || true
  )"
  out_start="$(
    cd "$RUNNER_DIR" && $SUDO ./svc.sh start 2>&1 || true
  )"
  out_status="$(run_status)"

  printf "%s\n%s\n%s" "$out_stop" "$out_start" "$out_status"
}

main() {
  local st
  st="$(run_status)"
  log "status: $(echo "$st" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-300)"

  if printf "%s" "$st" | is_running; then
    [[ "$MODE" == "manual" ]] && echo "running"
    exit 0
  fi

  if printf "%s" "$st" | is_oom_kill; then
    notify "⚠️ GitHub runner DOWN per OOM-KILL su ${HOST}\nRunner: ${RUNNER_DIR}\nStato:\n${st}\n\nAzione: tentativo stop/start…"

    local r
    r="$(restart_runner)"
    log "restart output: $(echo "$r" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-300)"

    local st2
    st2="$(run_status)"

    if printf "%s" "$st2" | is_running; then
      notify "✅ Runner ripartito dopo OOM-KILL su ${HOST}\nRunner: ${RUNNER_DIR}\nNuovo stato:\n${st2}"
      exit 10
    else
      notify "🚨 Runner ANCORA non running dopo restart (OOM-KILL) su ${HOST}\nRunner: ${RUNNER_DIR}\nNuovo stato:\n${st2}"
      exit 11
    fi
  fi

  # Non running, ma non oom-kill
  notify "⚠️ GitHub runner NON running su ${HOST}\nRunner: ${RUNNER_DIR}\nStato:\n${st}"
  exit 20
}

main