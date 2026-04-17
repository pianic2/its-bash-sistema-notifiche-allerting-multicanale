#!/usr/bin/env bash

# ==========================================
# FILE: entrypoint.sh
# RUOLO: orchestration entrypoint del container alerting.
#
# FLOW:
# 1. valida config e prerequisiti minimi
# 2. avvia monitor loop in background
# 3. avvia Apache in foreground-like background supervision
# 4. attende che uno dei due processi termini
# 5. esegue shutdown pulito dell'altro processo
#
# INPUT:
# - /etc/alerting/config.conf
# - /opt/alerting/alert-system.sh
#
# OUTPUT:
# - log su stdout/stderr del container
# - exit code del primo processo terminato
#
# DIPENDENZE:
# - bash
# - apache2-foreground
# - alert-system.sh eseguibile
#
# ATTENZIONE:
# - gestisce SIGTERM/SIGINT per stop pulito del container
# - non cambiare la sequenza wait/shutdown senza verificare il lifecycle
# ==========================================

set -euo pipefail

# --- CONFIG / RUNTIME STATE ---
CONFIG_FILE="/etc/alerting/config.conf"
ALERT_SCRIPT="/opt/alerting/alert-system.sh"
EXIT_REQUESTED=0
MONITOR_PID=""
APACHE_PID=""
SLEEP_PID=""

# log
# input: messaggio libero
# output: nessuno
# side effects: scrive su stdout con timestamp e prefisso entrypoint
# failure: nessuno, salvo errori I/O del processo padre
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [entrypoint] $*"
}

# --- CONFIG VALIDATION ---

# Validazione minima della configurazione e dei prerequisiti per evitare crash immediati o loop rumorosi
if [[ ! -r "$CONFIG_FILE" ]]; then
  log "ERROR missing config file: $CONFIG_FILE"
  exit 1
fi

# shellcheck source=/etc/alerting/config.conf
source "$CONFIG_FILE"

# Validazione variabile di ambiente MONITOR_INTERVAL_SECONDS
MONITOR_INTERVAL_SECONDS="${MONITOR_INTERVAL_SECONDS:-60}"
if [[ ! "$MONITOR_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$MONITOR_INTERVAL_SECONDS" -lt 1 ]]; then
  log "ERROR invalid MONITOR_INTERVAL_SECONDS: $MONITOR_INTERVAL_SECONDS"
  exit 2
fi

# Validazione eseguibilità dello script di monitoraggio
if [[ ! -x "$ALERT_SCRIPT" ]]; then
  log "ERROR alert script not executable: $ALERT_SCRIPT"
  exit 3
fi

# shutdown
# input: nessuno
# output: nessuno
# side effects: ferma sleep, monitor loop e Apache; attende la chiusura dei child
# failure: ignora errori di kill/wait per evitare stop rumorosi in shutdown
shutdown() {
  EXIT_REQUESTED=1
  log "Stopping processes"
  if [[ -n "${SLEEP_PID:-}" ]] && kill -0 "$SLEEP_PID" 2>/dev/null; then
    kill "$SLEEP_PID" 2>/dev/null || true
  fi
  if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill "$MONITOR_PID" 2>/dev/null || true
  fi
  if [[ -n "${APACHE_PID:-}" ]] && kill -0 "$APACHE_PID" 2>/dev/null; then
    kill "$APACHE_PID" 2>/dev/null || true
  fi
  if [[ -n "${MONITOR_PID:-}" ]]; then
    wait "$MONITOR_PID" 2>/dev/null || true
  fi
  if [[ -n "${APACHE_PID:-}" ]]; then
    wait "$APACHE_PID" 2>/dev/null || true
  fi
}

# handle_signal
# input: segnale TERM/INT via trap
# output: exit 0 del processo entrypoint
# side effects: richiama shutdown completo
# failure: nessuno gestito esplicitamente, perche lo scopo e terminare pulitamente
handle_signal() {
  shutdown
  exit 0
}

trap handle_signal TERM INT

# monitor_loop
# input: usa MONITOR_INTERVAL_SECONDS e ALERT_SCRIPT dal contesto globale
# output: nessuno
# side effects: esegue periodicamente alert-system.sh e scrive log di errore se fallisce
# failure: non termina il container su singolo ciclo fallito; continua il loop finche non arriva uno stop
monitor_loop() {
  log "Monitor loop started (interval=${MONITOR_INTERVAL_SECONDS}s)"
  while [[ "$EXIT_REQUESTED" -eq 0 ]]; do
    if "$ALERT_SCRIPT"; then
      :
    else
      rc=$?
      log "Monitor execution failed with code: $rc"
    fi

    if [[ "$EXIT_REQUESTED" -eq 1 ]]; then
      break
    fi

    sleep "$MONITOR_INTERVAL_SECONDS" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
  done
}

# --- PROCESS STARTUP ---
monitor_loop &
MONITOR_PID=$!

apache2-foreground &
APACHE_PID=$!

# --- PROCESS SUPERVISION / SHUTDOWN ---
set +e
wait -n "$MONITOR_PID" "$APACHE_PID"
EXITED_RC=$?
set -e
log "One process exited (rc=$EXITED_RC), shutting down"
shutdown
exit "$EXITED_RC"
