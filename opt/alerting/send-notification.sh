#!/usr/bin/env bash

# ==========================================
# FILE: send-notification.sh
# RUOLO: gestisce invio notifiche multi-canale e scrittura log strutturato.
#
# FLOW:
# 1. riceve evento e dettagli
# 2. carica config e prepara contesto template
# 3. calcola fingerprint evento
# 4. applica lock per fingerprint
# 5. applica dedup e rate limit
# 6. dispatch ai canali con retry semplice
# 7. aggiorna stato file-based e scrive alerts.log
#
# INPUT:
# - argomenti CLI: event_type, severity, title, details
# - /etc/alerting/config.conf
# - template opzionali in /opt/alerting/templates
#
# OUTPUT:
# - righe strutturate in /var/log/alerts.log
# - stato dedup/rate/lock sotto /opt/alerting/runtime/state
# - exit 0 se evento processato o skipped, exit 1 se uno o piu canali falliscono
#
# DIPENDENZE:
# - bash associativo
# - sha256sum, awk, sed
# - curl/mail solo per canali reali
#
# ATTENZIONE:
# - usa EVENT_LOCK_PATH per evitare race condition tra processi concorrenti
# - NON modificare fingerprint, dedup o contratto log senza audit dedicato
# ==========================================

set -u -o pipefail

# --- CONFIG / PATHS ---
CONFIG_FILE="/etc/alerting/config.conf"
ALERT_LOG="/var/log/alerts.log"
TEMPLATES_DIR="/opt/alerting/templates"
RUNTIME_DIR="/opt/alerting/runtime"
STATE_DIR="$RUNTIME_DIR/state"
DEDUP_DIR="$STATE_DIR/dedup"
RATE_DIR="$STATE_DIR/rate"
LOCK_DIR="$STATE_DIR/locks"

EVENT_TYPE="${1:-}"
SEVERITY="${2:-}"
TITLE="${3:-}"
DETAILS_RAW="${4:-}"

# --- RUNTIME DIRECTORY SETUP ---
mkdir -p "$DEDUP_DIR" "$RATE_DIR" "$LOCK_DIR"

# --- INPUT VALIDATION / CONFIG LOADING ---
if [[ -z "$EVENT_TYPE" || -z "$SEVERITY" || -z "$TITLE" ]]; then
  echo "Usage: send-notification.sh <event_type> <severity> <title> [details]" >&2
  exit 2
fi

if [[ ! -r "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not readable: $CONFIG_FILE" >&2
  exit 3
fi

# shellcheck source=/etc/alerting/config.conf
source "$CONFIG_FILE"

: "${ENABLE_EMAIL:=1}"
: "${ENABLE_SLACK:=1}"
: "${ENABLE_TELEGRAM:=1}"
: "${NOTIFY_SIMULATION_MODE:=1}"
: "${EMAIL_TO:=}"
: "${SLACK_WEBHOOK_URL:=}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"
: "${ALERT_DEDUP_WINDOW_SECONDS:=120}"
: "${ALERT_RATE_LIMIT_SECONDS:=900}"
: "${ALERT_MAX_RETRY:=2}"
: "${ALERT_RETRY_BACKOFF_SECONDS:=2}"

# sanitize
# input: testo libero
# output: testo safe per il contratto alerts.log
# side effects: nessuno
# failure: nessuno; normalizza newline e codifica % e |
sanitize() {
  local input="${1:-}"
  input="${input//$'\n'/ }"
  input="${input//%/%25}"
  input="${input//|/%7C}"
  echo "$input"
}

# emit_log
# input: event_type, severity, title, channel, outcome, details
# output: nessuno
# side effects: appende una riga parseabile a alerts.log
# failure: nessuno esplicito, dipende dalla scrivibilita del file di log
emit_log() {
  local event_type="$1"
  local severity="$2"
  local title="$3"
  local channel="$4"
  local outcome="$5"
  local details="$6"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "$ts|$(sanitize "$event_type")|$(sanitize "$severity")|$(sanitize "$title")|$(sanitize "$channel")|$(sanitize "$outcome")|$(sanitize "$details")" >> "$ALERT_LOG"
}

# as_bool
# input: stringa 0/1
# output: true se 1, false altrimenti
# side effects: nessuno
# failure: nessuno
as_bool() {
  [[ "${1:-0}" == "1" ]]
}

# is_int
# input: stringa
# output: true se intero non negativo
# side effects: nessuno
# failure: nessuno
is_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# is_placeholder
# input: valore config canale
# output: true se vuoto o placeholder non utilizzabile
# side effects: nessuno
# failure: nessuno
is_placeholder() {
  local value="$1"
  [[ -z "$value" || "$value" == "changeme" || "$value" == "<token>" || "$value" == "<id>" ]]
}

# is_transient_code
# input: exit code funzione canale
# output: true se il codice e considerato retryable
# side effects: nessuno
# failure: nessuno
is_transient_code() {
  local code="$1"
  [[ "$code" -eq 20 ]]
}

# --- EVENT CONTEXT BUILD ---
declare -A CTX
if [[ -n "$DETAILS_RAW" ]]; then
  IFS=';' read -ra pairs <<< "$DETAILS_RAW"
  for pair in "${pairs[@]}"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    if [[ -n "$key" && "$pair" == *"="* ]]; then
      CTX["$key"]="$value"
    fi
  done
fi

CTX["EVENT_TYPE"]="$EVENT_TYPE"
CTX["SEVERITY"]="$SEVERITY"
CTX["TITLE"]="$TITLE"
CTX["TIMESTAMP"]="$(date '+%Y-%m-%d %H:%M:%S')"

# render_template
# input: usa EVENT_TYPE e CTX dal contesto globale
# output: messaggio renderizzato o fallback TITLE
# side effects: legge file template se presente
# failure: non fallisce se manca il template; usa fallback semplice
render_template() {
  local template_file
  case "$EVENT_TYPE" in
    DISK) template_file="$TEMPLATES_DIR/disk_high.tpl" ;;
    LOAD) template_file="$TEMPLATES_DIR/cpu_high.tpl" ;;
    SERVICE_DOWN) template_file="$TEMPLATES_DIR/service_down.tpl" ;;
    *) template_file="" ;;
  esac

  if [[ -z "$template_file" || ! -f "$template_file" ]]; then
    echo "$TITLE"
    return 0
  fi

  local content
  content="$(cat "$template_file")"

  local keys=(HOST DISK_USAGE DISK_THRESHOLD LOAD_AVG LOAD_THRESHOLD SERVICE_NAME TIMESTAMP EVENT_TYPE SEVERITY TITLE)
  for key in "${keys[@]}"; do
    local value="${CTX[$key]:-N/A}"
    value="${value//\//\\/}"
    value="${value//&/\\&}"
    content="$(echo "$content" | sed "s/{{${key}}}/${value}/g")"
  done

  echo "$content"
}

MESSAGE="$(render_template)"
FINGERPRINT="$(echo -n "${EVENT_TYPE}|${SEVERITY}|${TITLE}" | sha256sum | awk '{print $1}')"
NOW_EPOCH="$(date +%s)"
EVENT_LOCK_PATH="$LOCK_DIR/${FINGERPRINT}.lock"

# release_event_lock
# input: nessuno
# output: nessuno
# side effects: rimuove la lock directory del fingerprint corrente
# failure: ignora errori per evitare deadlock in cleanup
release_event_lock() {
  if [[ -d "$EVENT_LOCK_PATH" ]]; then
    rmdir "$EVENT_LOCK_PATH" 2>/dev/null || true
  fi
}

# acquire_event_lock
# input: nessuno
# output: return 0 se lock acquisita, non zero se gia presente
# side effects: crea atomicamente una directory lock per fingerprint
# failure: fallisce quando un altro processo sta gestendo lo stesso evento
acquire_event_lock() {
  mkdir "$EVENT_LOCK_PATH" 2>/dev/null
}

# check_dedup
# input: usa FINGERPRINT e ALERT_DEDUP_WINDOW_SECONDS dal contesto globale
# output: return 0 se l'evento e ancora nel dedup window
# side effects: legge il file stato dedup del fingerprint
# failure: file corrotto/non numerico viene trattato come non valido e quindi non blocca l'evento
check_dedup() {
  local file="$DEDUP_DIR/$FINGERPRINT"
  if [[ -f "$file" ]]; then
    local last
    last="$(cat "$file" 2>/dev/null || echo 0)"
    if is_int "$last" && (( NOW_EPOCH - last < ALERT_DEDUP_WINDOW_SECONDS )); then
      return 0
    fi
  fi
  return 1
}

# check_rate_limit
# input: usa FINGERPRINT e ALERT_RATE_LIMIT_SECONDS dal contesto globale
# output: return 0 se l'evento e ancora nel rate limit window
# side effects: legge il file stato rate del fingerprint
# failure: file corrotto/non numerico viene trattato come non valido e quindi non blocca l'evento
check_rate_limit() {
  local file="$RATE_DIR/$FINGERPRINT"
  if [[ -f "$file" ]]; then
    local last
    last="$(cat "$file" 2>/dev/null || echo 0)"
    if is_int "$last" && (( NOW_EPOCH - last < ALERT_RATE_LIMIT_SECONDS )); then
      return 0
    fi
  fi
  return 1
}

# update_event_state
# input: usa FINGERPRINT e NOW_EPOCH dal contesto globale
# output: nessuno
# side effects: aggiorna i timestamp file-based per dedup e rate limit
# failure: dipende dalla scrivibilita della runtime dir
update_event_state() {
  echo "$NOW_EPOCH" > "$DEDUP_DIR/$FINGERPRINT"
  echo "$NOW_EPOCH" > "$RATE_DIR/$FINGERPRINT"
}

# --- LOCKING / DEDUP / RATE LIMIT ---
if ! is_int "$ALERT_DEDUP_WINDOW_SECONDS" || ! is_int "$ALERT_RATE_LIMIT_SECONDS" || ! is_int "$ALERT_MAX_RETRY" || ! is_int "$ALERT_RETRY_BACKOFF_SECONDS"; then
  emit_log "$EVENT_TYPE" "$SEVERITY" "$TITLE" "dispatcher" "failed" "invalid numeric config"
  exit 4
fi

if ! acquire_event_lock; then
  emit_log "$EVENT_TYPE" "$SEVERITY" "$TITLE" "dispatcher" "skipped" "reason=in_progress"
  exit 0
fi

trap release_event_lock EXIT

if check_dedup; then
  emit_log "$EVENT_TYPE" "$SEVERITY" "$TITLE" "dispatcher" "skipped" "reason=dedup window=${ALERT_DEDUP_WINDOW_SECONDS}s"
  exit 0
fi

if check_rate_limit; then
  emit_log "$EVENT_TYPE" "$SEVERITY" "$TITLE" "dispatcher" "skipped" "reason=rate_limited window=${ALERT_RATE_LIMIT_SECONDS}s"
  exit 0
fi

SEND_OUTCOME="failed"
SEND_DETAILS=""

# send_email
# input: usa config, TITLE, SEVERITY, EVENT_TYPE e MESSAGE dal contesto globale
# output: return 0 per sent/skipped/simulated, codice transient per retry, 1 per failure non transient
# side effects: invia mail reale o simulata
# failure: puo ritornare errore se EMAIL_TO manca o il comando mail fallisce
send_email() {
  if ! as_bool "$ENABLE_EMAIL"; then
    SEND_OUTCOME="skipped"
    SEND_DETAILS="disabled"
    return 0
  fi

  if as_bool "$NOTIFY_SIMULATION_MODE"; then
    SEND_OUTCOME="simulated"
    SEND_DETAILS="simulation_mode"
    return 0
  fi

  if [[ -z "$EMAIL_TO" ]]; then
    SEND_OUTCOME="failed"
    SEND_DETAILS="EMAIL_TO missing"
    return 1
  fi

  if ! command -v mail >/dev/null 2>&1; then
    SEND_OUTCOME="simulated"
    SEND_DETAILS="mail command missing"
    return 0
  fi

  if printf '%s\n' "$MESSAGE" | mail -s "[$SEVERITY][$EVENT_TYPE] $TITLE" "$EMAIL_TO"; then
    SEND_OUTCOME="sent"
    SEND_DETAILS="recipient=$EMAIL_TO"
    return 0
  fi

  SEND_OUTCOME="failed"
  SEND_DETAILS="mail command error"
  return 20
}

# send_slack
# input: usa config e payload evento dal contesto globale
# output: return 0 per sent/skipped/simulated, 20 su failure retryable
# side effects: esegue POST HTTP o simulazione
# failure: curl failure viene marcato come transient per retry
send_slack() {
  if ! as_bool "$ENABLE_SLACK"; then
    SEND_OUTCOME="skipped"
    SEND_DETAILS="disabled"
    return 0
  fi

  if as_bool "$NOTIFY_SIMULATION_MODE" || is_placeholder "$SLACK_WEBHOOK_URL"; then
    SEND_OUTCOME="simulated"
    SEND_DETAILS="simulation_or_placeholder"
    return 0
  fi

  payload=$(printf '{"text":"[%s][%s] %s - %s"}' "$SEVERITY" "$EVENT_TYPE" "$TITLE" "$(sanitize "$MESSAGE")")

  if curl -fsS --max-time 10 -X POST -H "Content-Type: application/json" -d "$payload" "$SLACK_WEBHOOK_URL" >/dev/null; then
    SEND_OUTCOME="sent"
    SEND_DETAILS="webhook_ok"
    return 0
  fi

  SEND_OUTCOME="failed"
  SEND_DETAILS="curl failure"
  return 20
}

# send_telegram
# input: usa config e payload evento dal contesto globale
# output: return 0 per sent/skipped/simulated, 20 su failure retryable
# side effects: esegue POST HTTP verso Telegram o simulazione
# failure: curl failure viene marcato come transient per retry
send_telegram() {
  if ! as_bool "$ENABLE_TELEGRAM"; then
    SEND_OUTCOME="skipped"
    SEND_DETAILS="disabled"
    return 0
  fi

  if as_bool "$NOTIFY_SIMULATION_MODE" || is_placeholder "$TELEGRAM_BOT_TOKEN" || is_placeholder "$TELEGRAM_CHAT_ID"; then
    SEND_OUTCOME="simulated"
    SEND_DETAILS="simulation_or_placeholder"
    return 0
  fi

  local api
  api="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

  if curl -fsS --max-time 10 -X POST "$api" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=[$SEVERITY][$EVENT_TYPE] $TITLE - $MESSAGE" >/dev/null; then
    SEND_OUTCOME="sent"
    SEND_DETAILS="telegram_ok"
    return 0
  fi

  SEND_OUTCOME="failed"
  SEND_DETAILS="curl failure"
  return 20
}

# send_with_retry
# input: channel label, nome funzione canale
# output: return 0 se il canale conclude con successo/skipped/simulated, 1 se fallisce definitivamente
# side effects: scrive outcome per canale in alerts.log e applica sleep/backoff sui retry transient
# failure: termina solo quando il canale fallisce definitivamente o supera ALERT_MAX_RETRY
send_with_retry() {
  local channel="$1"
  local fn="$2"
  local attempt=1

  while true; do
    "$fn"
    rc=$?

    if [[ "$rc" -eq 0 ]]; then
      emit_log "$EVENT_TYPE" "$SEVERITY" "$TITLE" "$channel" "$SEND_OUTCOME" "attempt=$attempt $SEND_DETAILS"
      return 0
    fi

    if is_transient_code "$rc" && (( attempt <= ALERT_MAX_RETRY )); then
      sleep $((ALERT_RETRY_BACKOFF_SECONDS * attempt))
      attempt=$((attempt + 1))
      continue
    fi

    emit_log "$EVENT_TYPE" "$SEVERITY" "$TITLE" "$channel" "failed" "attempt=$attempt $SEND_DETAILS"
    return 1
  done
}

# --- CHANNEL DISPATCH / FINAL OUTCOME ---
FAIL_COUNT=0

send_with_retry "email" send_email || FAIL_COUNT=$((FAIL_COUNT + 1))
send_with_retry "slack" send_slack || FAIL_COUNT=$((FAIL_COUNT + 1))
send_with_retry "telegram" send_telegram || FAIL_COUNT=$((FAIL_COUNT + 1))

update_event_state

if (( FAIL_COUNT > 0 )); then
  emit_log "$EVENT_TYPE" "$SEVERITY" "$TITLE" "dispatcher" "failed" "failed_channels=$FAIL_COUNT"
  exit 1
fi

emit_log "$EVENT_TYPE" "$SEVERITY" "$TITLE" "dispatcher" "sent" "all_channels_processed"
exit 0
