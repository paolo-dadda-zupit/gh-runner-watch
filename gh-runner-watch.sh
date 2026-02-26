#!/usr/bin/env bash
set -uo pipefail

# --- Config di default (puoi override con file o argomenti) ---
RUNNER_DIR="/opt/github-runner/pipeline-agents2-container-1"
CONFIG_FILE="/etc/gh-runner-watch.conf"
MODE="manual"   # manual | scheduled
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scheduled) MODE="scheduled" ;;
    --manual) MODE="manual" ;;
    --runner-dir) RUNNER_DIR="$2"; shift ;;
    --config) CONFIG_FILE="$2"; shift ;;
    --slack-webhook) SLACK_WEBHOOK_URL="$2"; shift ;;
    --help|-h)
      echo "Uso: $0 [--manual|--scheduled] [--runner-dir PATH] [--config FILE] [--slack-webhook URL]"
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

# --- Carica config file (se esiste) ---
# Il file può contenere ad esempio:
# SLACK_WEBHOOK_URL="https://hooksslackcom/services/XXX/YYY/ZZZ"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# --- Lock anti-overlap (cron ogni 3 min) ---
LOCK_FILE="/var/lock/gh-runner-watch.lock"
if ! ( : >"$LOCK_FILE" ) 2>/dev/null; then
  LOCK_FILE="/tmp/gh-runner-watchlock"
fi
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
fi

# --- Logging minimale ---
HOST="$(hostname -f 2>/dev/null || hostname)"
TS="$(date -Is)"
LOG_FILE="/var/log/gh-runner-watch.log"
if ! ( : >>"$LOG_FILE" ) 2>/dev/null; then
  LOG_FILE="${HOME:-/tmp}/gh-runner-watchlog"
fi

log() {
  echo "[$TS] $*" | tee -a "$LOG_FILE" >/dev/null
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

json_escape() {
  # usa python3 se disponibile per escape JSON corretto
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import json,sys
print(jsondumps(sysstdinread()))
PY
  else
    # fallback "abbastanza" sicuro per testo semplice
    local s
    s="$(cat)"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf "\"%s\"" "$s"
  fi
}

slack_send() {
  local text="$1"
  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    log "SLACK_WEBHOOK_URL non impostato; impossibile inviare Slack"
    return 1
  fi

  local payload
  payload="{\"text\":$(printf "%s" "$text" | json_escape)}"

  curl -sS -X POST -H 'Content-type: application/json' \
    --data "$payload" \
    "$SLACK_WEBHOOK_URL" >/dev/null
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