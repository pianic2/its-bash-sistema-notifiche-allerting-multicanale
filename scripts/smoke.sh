#!/usr/bin/env bash

# ==========================================
# FILE: smoke.sh
# RUOLO: esegue una verifica smoke end-to-end del sistema dopo build/start container.
#
# FLOW:
# 1. builda e avvia il container
# 2. verifica startup pulito e sintassi script/dashboard
# 3. forza un ciclo monitor
# 4. verifica dispatch simulato e contratto log
# 5. verifica dedup e lock di concorrenza
# 6. renderizza la dashboard senza fatal
#
# INPUT:
# - repository root con docker compose
# - container service alerting
#
# OUTPUT:
# - exit 0 se tutti gli assert smoke passano
# - exit non zero sul primo controllo fallito
#
# DIPENDENZE:
# - docker compose
# - bash nel container
# - php nel container
#
# ATTENZIONE:
# - questo script copre solo scenari smoke, non sostituisce test di carico o audit manuali
# - usa titoli dinamici per evitare collisioni con eventi precedenti nei log
# ==========================================

set -euo pipefail

# --- WORKSPACE SETUP ---
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

# --- CONTAINER BUILD / START ---
echo "[smoke] build and start container"
docker compose up -d --build

# --- STARTUP ASSERTS ---
echo "[smoke] startup clean"
if docker compose logs --no-color --tail 20 alerting | grep -q 'entrypoint.sh: line'; then
	echo "[smoke] startup contains shell errors"
	exit 1
fi

# --- SYNTAX ASSERTS ---
echo "[smoke] syntax checks"
docker compose exec -T alerting bash -lc 'bash -n /opt/alerting/alert-system.sh && bash -n /opt/alerting/send-notification.sh && bash -n /opt/alerting/entrypoint.sh'
docker compose exec -T alerting php -l /var/www/html/dashboard.php

# --- MONITOR EXECUTION ASSERT ---
echo "[smoke] run monitor cycle"
docker compose exec -T alerting bash -lc '/opt/alerting/alert-system.sh && test -s /opt/alerting/variables.data'

# --- NOTIFICATION / LOG CONTRACT ASSERTS ---
echo "[smoke] simulated multi-channel dispatch"
TEST_TITLE="smoke_test_$(date +%s)"
docker compose exec -T alerting bash -lc '/opt/alerting/send-notification.sh TEST_EVENT WARNING '"$TEST_TITLE"' "HOST=smoke;TIMESTAMP=$(date +%F_%T)"'

echo "[smoke] log contract has 7 fields"
docker compose exec -T alerting bash -lc 'line=$(grep "|TEST_EVENT|WARNING|'"$TEST_TITLE"'|" /var/log/alerts.log | tail -n 1); [[ -n "$line" ]]; awk -F"|" "NF != 7 { exit 1 }" <<< "$line"'

echo "[smoke] dedup/rate-limit behavior"
docker compose exec -T alerting bash -lc '/opt/alerting/send-notification.sh TEST_EVENT WARNING '"$TEST_TITLE"' "HOST=smoke;TIMESTAMP=$(date +%F_%T)"'
docker compose exec -T alerting bash -lc 'grep "|TEST_EVENT|WARNING|'"$TEST_TITLE"'|dispatcher|" /var/log/alerts.log | tail -n 2 | tee /tmp/smoke-dedup.log && grep -q "|skipped|reason=dedup" /tmp/smoke-dedup.log'

# --- CONCURRENCY ASSERT ---
echo "[smoke] concurrency dedup lock"
RACE_TITLE="smoke_race_$(date +%s)"
docker compose exec -T alerting bash -lc '/opt/alerting/send-notification.sh RACE_EVENT WARNING '"$RACE_TITLE"' "HOST=race" >/tmp/r1.log 2>/tmp/r1.err & /opt/alerting/send-notification.sh RACE_EVENT WARNING '"$RACE_TITLE"' "HOST=race" >/tmp/r2.log 2>/tmp/r2.err & wait; sent_count=$(grep -c "|RACE_EVENT|WARNING|'"$RACE_TITLE"'|dispatcher|sent|" /var/log/alerts.log || true); [[ "$sent_count" -eq 1 ]]; grep "|RACE_EVENT|WARNING|'"$RACE_TITLE"'|dispatcher|" /var/log/alerts.log | tail -n 3'

# --- DASHBOARD ASSERT ---
echo "[smoke] dashboard render check"
docker compose exec -T alerting php -d display_errors=1 -d error_reporting=E_ALL /var/www/html/dashboard.php >/tmp/dashboard-smoke.out

echo "[smoke] success"
