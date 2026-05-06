#!/usr/bin/env bash
set -uo pipefail

# --- Config di default (puoi override con file o argomenti) ---
RUNNER_DIR="/opt/github-runner/pipeline-agents2-container-1"
CONFIG_FILE="/etc/gh-runner-watch.conf"
MODE="manual"   # manual | scheduled

KUMA_PUSH_URL="${KUMA_PUSH_URL:-}"
RUNNER_KEY_OVERRIDE="${RUNNER_KEY_OVERRIDE:-}"
KUMA_PUSH_URL_FROM_CLI=0

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
    --kuma-push-url)
      [[ $# -ge 2 ]] || { echo "Valore mancante per --kuma-push-url" >&2; exit 30; }
      KUMA_PUSH_URL="$2"
      KUMA_PUSH_URL_FROM_CLI=1
      shift
      ;;
    --runner-key)
      [[ $# -ge 2 ]] || { echo "Valore mancante per --runner-key" >&2; exit 30; }
      RUNNER_KEY_OVERRIDE="$2"
      shift
      ;;
    --help|-h)
      echo "Uso: $0 [--manual|--scheduled] [--runner-dir PATH] [--config FILE] [--kuma-push-url URL] [--runner-key NAME]"
      echo
      echo "Script one-shot: esegue un solo controllo del runner e invia un solo heartbeat a Uptime Kuma."
      echo "Il timing viene deciso dal cron (o da un altro scheduler esterno)."
      echo
      echo "Variabili supportate nel file di config condiviso:"
      echo "  KUMA_PUSH_URL=\"https://kuma.example/api/push/TOKEN\""
      echo "  KUMA_PUSH_URL_PIPELINE_AGENTS2_CONTAINER_1=\"https://kuma.example/api/push/TOKEN\""
      echo "  KUMA_PUSH_URL_PIPELINE_AGENTS2_CONTAINER_2=\"https://kuma.example/api/push/TOKEN\""
      exit 0
      ;;
    *)
      echo "Argomento non riconosciuto: $1" >&2
      exit 30
      ;;
  esac
  shift
done

basename_safe() {
  local dir="${1%/}"
  basename "$dir"
}

runner_display_name() {
  if [[ -n "${RUNNER_KEY_OVERRIDE:-}" ]]; then
    printf '%s\n' "$RUNNER_KEY_OVERRIDE"
  else
    basename_safe "$RUNNER_DIR"
  fi
}

runner_env_key() {
  local raw

  if [[ -n "${RUNNER_KEY_OVERRIDE:-}" ]]; then
    raw="$RUNNER_KEY_OVERRIDE"
  else
    raw="$(basename_safe "$RUNNER_DIR")"
  fi

  raw="${raw//[^A-Za-z0-9]/_}"
  raw="${raw^^}"
  printf '%s\n' "$raw"
}

LOCK_NAME="$(printf '%s' "$RUNNER_DIR" | sed 's#[^A-Za-z0-9._-]#_#g')"
LOCK_FILE="/var/lock/gh-runner-watch-heartbeat.${LOCK_NAME}.lock"
if ! ( : >"$LOCK_FILE" ) 2>/dev/null; then
  LOCK_FILE="/tmp/gh-runner-watch-heartbeat.${LOCK_NAME}.lock"
fi

exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
fi

HOST="$(hostname -f 2>/dev/null || hostname)"
LOG_FILE="/var/log/gh-runner-watch-heartbeat.log"
if ! ( : >>"$LOG_FILE" ) 2>/dev/null; then
  LOG_FILE="${HOME:-/tmp}/gh-runner-watch-heartbeat.log"
fi

SVC="${RUNNER_DIR%/}/svc.sh"
RUNNER_NAME="$(runner_display_name)"
RUNNER_ENV_KEY="$(runner_env_key)"

log() {
  local ts
  ts="$(date -Is)"
  echo "[$ts] $*" | tee -a "$LOG_FILE" >/dev/null
}

print_manual() {
  [[ "$MODE" == "manual" ]] && printf "%b\n" "$1"
}

ensure_dependencies() {
  if ! command -v curl >/dev/null 2>&1; then
    log "ERRORE: curl non trovato"
    print_manual "ERRORE: curl non trovato"
    exit 30
  fi
}

resolve_push_url() {
  local runner_var_name="KUMA_PUSH_URL_${RUNNER_ENV_KEY}"
  local runner_url="${!runner_var_name:-}"
  local resolved=""

  if (( KUMA_PUSH_URL_FROM_CLI )); then
    resolved="$KUMA_PUSH_URL"
  elif [[ -n "$runner_url" ]]; then
    resolved="$runner_url"
  elif [[ -n "${KUMA_PUSH_URL:-}" ]]; then
    resolved="$KUMA_PUSH_URL"
  fi

  if [[ -z "$resolved" ]]; then
    return 1
  fi

  printf '%s\n' "${resolved%%\?*}"
}

flatten_text() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//'
}

now_ms() {
  local ts
  ts="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$ts"
  fi
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

run_status() {
  if [[ ! -x "$SVC" ]]; then
    log "ERRORE: svc.sh non trovato o non eseguibile: $SVC"
    print_manual "ERRORE: svc.sh non trovato o non eseguibile: $SVC"
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

push_kuma() {
  local status="$1"
  local msg="$2"
  local ping_ms="${3:-}"
  local push_url payload_base

  push_url="$(resolve_push_url)" || {
    log "ERRORE: nessuna KUMA_PUSH_URL disponibile per runner ${RUNNER_NAME} (chiave ${RUNNER_ENV_KEY})"
    print_manual "ERRORE: nessuna KUMA_PUSH_URL disponibile per runner ${RUNNER_NAME} (chiave ${RUNNER_ENV_KEY})"
    return 30
  }

  payload_base="$push_url"

  local -a curl_cmd
  curl_cmd=(curl -fsS --get --max-time 15 --data-urlencode "status=${status}" --data-urlencode "msg=${msg}")
  if [[ -n "$ping_ms" ]]; then
    curl_cmd+=(--data-urlencode "ping=${ping_ms}")
  fi
  curl_cmd+=("$payload_base")

  "${curl_cmd[@]}" >/dev/null || {
    log "ERRORE: invio Uptime Kuma fallito per ${RUNNER_NAME} verso ${payload_base}"
    print_manual "ERRORE: invio Uptime Kuma fallito per ${RUNNER_NAME} verso ${payload_base}"
    return 30
  }

  return 0
}

main() {
  local start_ms end_ms ping_ms=""
  local st summary runner_status msg rc

  ensure_dependencies

  start_ms="$(now_ms)"
  st="$(run_status)"
  end_ms="$(now_ms)"

  if [[ -n "$start_ms" && -n "$end_ms" ]]; then
    ping_ms="$((end_ms - start_ms))"
  fi

  summary="$(flatten_text "$st" | cut -c1-220)"
  log "status: ${summary:-empty}"

  if printf "%s" "$st" | is_running; then
    runner_status="up"
    msg="${RUNNER_NAME} running su ${HOST}"
    rc=0
  elif printf "%s" "$st" | is_oom_kill; then
    runner_status="down"
    msg="${RUNNER_NAME} down (oom-kill) su ${HOST}"
    rc=20
  else
    runner_status="down"
    if [[ -n "$summary" ]]; then
      msg="${RUNNER_NAME} down su ${HOST}: ${summary}"
    else
      msg="${RUNNER_NAME} down su ${HOST}"
    fi
    rc=20
  fi

  push_kuma "$runner_status" "$msg" "$ping_ms" || exit 30
  log "heartbeat sent status=${runner_status} runner=${RUNNER_NAME} ping_ms=${ping_ms:-n/a} msg=$(printf '%s' "$msg" | cut -c1-220)"

  if [[ "$MODE" == "manual" ]]; then
    if [[ "$runner_status" == "up" ]]; then
      echo "up"
    else
      printf "%b\n" "$msg"
    fi
  fi

  exit "$rc"
}

main





