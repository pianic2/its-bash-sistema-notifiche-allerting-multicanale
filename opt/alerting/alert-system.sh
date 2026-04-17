#!/usr/bin/env bash

# ==========================================
# FILE: alert-system.sh
# RUOLO: raccoglie metriche runtime, valuta soglie e genera eventi di alert.
#
# FLOW:
# 1. carica e valida la configurazione
# 2. verifica dipendenze e lock di singola esecuzione
# 3. legge metriche host e stato servizi
# 4. valuta condizioni CRITICAL/WARNING
# 5. invoca send-notification.sh per gli eventi generati
# 6. aggiorna variables.data e scrive log strutturato di sistema
#
# INPUT:
# - /etc/alerting/config.conf
# - stato servizi/processi del container
#
# OUTPUT:
# - /opt/alerting/variables.data
# - /var/log/alerts.log
# - exit code non zero su boot/config/dependency failure
#
# DIPENDENZE:
# - awk, df, uptime, hostname, who, pgrep, sed, grep
# - send-notification.sh
#
# ATTENZIONE:
# - usa monitor.lock per evitare doppia esecuzione concorrente
# - non modificare il contratto di variables.data senza allineare la dashboard
# ==========================================

set -u -o pipefail

# --- CONFIG / PATHS ---
CONFIG_FILE="/etc/alerting/config.conf"
VARIABLES_FILE="/opt/alerting/variables.data"
ALERT_LOG="/var/log/alerts.log"
NOTIFY_SCRIPT="/opt/alerting/send-notification.sh"
RUNTIME_DIR="/opt/alerting/runtime"
LOCK_FILE="$RUNTIME_DIR/monitor.lock"

mkdir -p "$RUNTIME_DIR"

# log_system
# input: severity, title, details opzionale
# output: nessuno
# side effects: appende una riga nel contratto alerts.log per eventi di sistema
# failure: nessuno esplicito, dipende dalla scrivibilita del log file
log_system() {
  local severity="$1"
  local title="$2"
  local details="${3:-}"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  details="${details//$'\n'/ }"
  details="${details//%/%25}"
  details="${details//|/%7C}"
  title="${title//%/%25}"
  title="${title//|/%7C}"
  severity="${severity//%/%25}"
  severity="${severity//|/%7C}"
  echo "$ts|SYSTEM|$severity|$title|system|$severity|$details" >> "$ALERT_LOG"
}

# fail
# input: exit code, messaggio errore
# output: nessuno
# side effects: scrive su alerts.log e stderr, poi termina il processo
# failure: termina sempre con il codice fornito
fail() {
  local code="$1"
  local message="$2"
  log_system "failed" "monitor_boot_failure" "$message"
  echo "ERROR: $message" >&2
  exit "$code"
}

# validate_int
# input: nome variabile, valore
# output: nessuno
# side effects: termina il processo via fail se il valore non e intero
# failure: exit non zero con monitor_boot_failure loggato
validate_int() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail 12 "invalid integer for $name: $value"
}

# validate_float
# input: nome variabile, valore
# output: nessuno
# side effects: termina il processo via fail se il valore non e float valido
# failure: exit non zero con monitor_boot_failure loggato
validate_float() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail 13 "invalid float for $name: $value"
}

# require_cmd
# input: nome comando
# output: nessuno
# side effects: termina il processo se la dipendenza runtime manca
# failure: exit non zero con monitor_boot_failure loggato
require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail 14 "missing dependency: $cmd"
}

# acquire_lock
# input: nessuno
# output: nessuno
# side effects: crea/aggiorna monitor.lock e registra cleanup via trap EXIT
# failure: termina il processo se trova un'altra esecuzione attiva
acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local old_pid
    old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      fail 15 "monitor lock already held by pid $old_pid"
    fi
  fi
  echo "$$" > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
}

# --- CONFIG LOADING / VALIDATION ---
if [[ ! -r "$CONFIG_FILE" ]]; then
  fail 10 "config file not readable: $CONFIG_FILE"
fi

# shellcheck source=/etc/alerting/config.conf
source "$CONFIG_FILE"

: "${HOSTNAME_LABEL:=local}"
: "${MONITORED_SERVICES:=}"
: "${DISK_USAGE_THRESHOLD:=}"
: "${LOAD_AVERAGE_THRESHOLD:=}"

[[ -n "$MONITORED_SERVICES" ]] || fail 11 "MONITORED_SERVICES is required"
[[ -n "$DISK_USAGE_THRESHOLD" ]] || fail 11 "DISK_USAGE_THRESHOLD is required"
[[ -n "$LOAD_AVERAGE_THRESHOLD" ]] || fail 11 "LOAD_AVERAGE_THRESHOLD is required"

validate_int "DISK_USAGE_THRESHOLD" "$DISK_USAGE_THRESHOLD"
validate_float "LOAD_AVERAGE_THRESHOLD" "$LOAD_AVERAGE_THRESHOLD"

require_cmd awk
require_cmd df
require_cmd uptime
require_cmd hostname
require_cmd who
require_cmd pgrep
require_cmd sed
require_cmd grep

if [[ ! -x "$NOTIFY_SCRIPT" ]]; then
  fail 16 "notification script not executable: $NOTIFY_SCRIPT"
fi

# --- LOCKING ---
acquire_lock

# --- METRICS COLLECTION ---
HOST="$HOSTNAME_LABEL"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
IP_ADDRESS="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP_ADDRESS="${IP_ADDRESS:-N/A}"

DISK_USAGE="$(df / 2>/dev/null | awk 'NR==2 {gsub("%", "", $5); print $5}')"
[[ -n "$DISK_USAGE" ]] || DISK_USAGE=0
[[ "$DISK_USAGE" =~ ^[0-9]+$ ]] || DISK_USAGE=0

LOAD_AVG="$(uptime 2>/dev/null | awk -F'load average: ' '{print $2}' | cut -d',' -f1 | xargs)"
[[ "$LOAD_AVG" =~ ^[0-9]+(\.[0-9]+)?$ ]] || LOAD_AVG="0.00"

UPTIME_READABLE="$(uptime -p 2>/dev/null || true)"
UPTIME_READABLE="${UPTIME_READABLE:-Unknown}"

USERS_CONNECTED="$(who 2>/dev/null | wc -l | tr -d ' ')"
[[ "$USERS_CONNECTED" =~ ^[0-9]+$ ]] || USERS_CONNECTED=0

SERVICES_SERIALIZED=""
SERVICES_DOWN_COUNT=0

for service in $MONITORED_SERVICES; do
  if pgrep "$service" >/dev/null 2>&1; then
    status="ACTIVE"
  else
    status="DOWN"
    SERVICES_DOWN_COUNT=$((SERVICES_DOWN_COUNT + 1))
  fi
  SERVICES_SERIALIZED+="${service}:${status},"
done
SERVICES_SERIALIZED="${SERVICES_SERIALIZED%,}"

OVERALL_STATUS="OK"

# --- ALERT EVALUATION / DISPATCH ---
if (( DISK_USAGE >= DISK_USAGE_THRESHOLD )); then
  OVERALL_STATUS="CRITICAL"
  "$NOTIFY_SCRIPT" \
    "DISK" \
    "CRITICAL" \
    "disk_usage_high" \
    "HOST=$HOST;DISK_USAGE=$DISK_USAGE;DISK_THRESHOLD=$DISK_USAGE_THRESHOLD;LOAD_AVG=$LOAD_AVG;LOAD_THRESHOLD=$LOAD_AVERAGE_THRESHOLD;TIMESTAMP=$NOW" || \
    log_system "failed" "notify_dispatch_error" "type=DISK"
fi

if awk -v a="$LOAD_AVG" -v b="$LOAD_AVERAGE_THRESHOLD" 'BEGIN {exit !(a >= b)}'; then
  if [[ "$OVERALL_STATUS" == "OK" ]]; then
    OVERALL_STATUS="WARNING"
  fi
  "$NOTIFY_SCRIPT" \
    "LOAD" \
    "WARNING" \
    "load_average_high" \
    "HOST=$HOST;DISK_USAGE=$DISK_USAGE;DISK_THRESHOLD=$DISK_USAGE_THRESHOLD;LOAD_AVG=$LOAD_AVG;LOAD_THRESHOLD=$LOAD_AVERAGE_THRESHOLD;TIMESTAMP=$NOW" || \
    log_system "failed" "notify_dispatch_error" "type=LOAD"
fi

if (( SERVICES_DOWN_COUNT > 0 )); then
  OVERALL_STATUS="CRITICAL"
  for service in $MONITORED_SERVICES; do
    if ! pgrep "$service" >/dev/null 2>&1; then
      "$NOTIFY_SCRIPT" \
        "SERVICE_DOWN" \
        "CRITICAL" \
        "service_down_$service" \
        "HOST=$HOST;SERVICE_NAME=$service;DISK_USAGE=$DISK_USAGE;DISK_THRESHOLD=$DISK_USAGE_THRESHOLD;LOAD_AVG=$LOAD_AVG;LOAD_THRESHOLD=$LOAD_AVERAGE_THRESHOLD;TIMESTAMP=$NOW" || \
        log_system "failed" "notify_dispatch_error" "type=SERVICE_DOWN service=$service"
    fi
  done
fi

# --- OUTPUT / CONTRACT WRITE ---
TMP_FILE="${VARIABLES_FILE}.tmp"
cat > "$TMP_FILE" <<EOF
HOST=$HOST
TIMESTAMP=$NOW
OVERALL_STATUS=$OVERALL_STATUS
IP_ADDRESS=$IP_ADDRESS
DISK_USAGE=$DISK_USAGE
DISK_THRESHOLD=$DISK_USAGE_THRESHOLD
LOAD_AVG=$LOAD_AVG
LOAD_THRESHOLD=$LOAD_AVERAGE_THRESHOLD
UPTIME_READABLE=$UPTIME_READABLE
USERS_CONNECTED=$USERS_CONNECTED
SERVICES_STATUS=$SERVICES_SERIALIZED
SERVICES_DOWN_COUNT=$SERVICES_DOWN_COUNT
EOF

mv "$TMP_FILE" "$VARIABLES_FILE"
log_system "sent" "monitor_cycle_completed" "status=$OVERALL_STATUS down=$SERVICES_DOWN_COUNT"
