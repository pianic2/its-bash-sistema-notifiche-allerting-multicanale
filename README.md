# Sistema Notifiche e Alerting Multi-Canale Bash

Sistema di monitoraggio con orchestrazione Bash, dashboard PHP servita da Apache e runtime in container Docker singolo.

## Architettura reale

- Bash entrypoint container: `/opt/alerting/entrypoint.sh`
- Bash monitor: `/opt/alerting/alert-system.sh`
- Bash notification engine: `/opt/alerting/send-notification.sh`
- Config: `/etc/alerting/config.conf`
- Dashboard PHP: `/var/www/html/dashboard.php`
- Runtime state: `/opt/alerting/runtime`
- Runtime data contract: `/opt/alerting/variables.data`
- Alert log contract: `/var/log/alerts.log`

## Avvio

```bash
docker compose up -d --build
```

Dashboard:

```txt
http://localhost:8080/dashboard.php
```

## Boot path del container

1. Docker avvia `/opt/alerting/entrypoint.sh`
2. L'entrypoint valida config e script
3. L'entrypoint avvia:
   - loop monitor ogni `MONITOR_INTERVAL_SECONDS`
   - Apache foreground
4. Se uno dei due processi termina, l'entrypoint ferma l'altro e chiude il container

## Config disponibile

File: `etc/alerting/config.conf`

### Monitoring

- `HOSTNAME_LABEL`
- `MONITOR_INTERVAL_SECONDS`
- `MONITORED_SERVICES`
- `DISK_USAGE_THRESHOLD`
- `LOAD_AVERAGE_THRESHOLD`

### Notifiche

- `ENABLE_EMAIL` (`0|1`)
- `ENABLE_SLACK` (`0|1`)
- `ENABLE_TELEGRAM` (`0|1`)
- `NOTIFY_SIMULATION_MODE` (`0|1`)
- `EMAIL_TO`
- `SLACK_WEBHOOK_URL`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`

### Resilienza

- `ALERT_DEDUP_WINDOW_SECONDS`
- `ALERT_RATE_LIMIT_SECONDS`
- `ALERT_MAX_RETRY`
- `ALERT_RETRY_BACKOFF_SECONDS`

## Contratto `variables.data`

Formato line-based `KEY=VALUE`.

Chiavi emesse dal monitor:

- `HOST`
- `TIMESTAMP`
- `OVERALL_STATUS`
- `IP_ADDRESS`
- `DISK_USAGE`
- `DISK_THRESHOLD`
- `LOAD_AVG`
- `LOAD_THRESHOLD`
- `UPTIME_READABLE`
- `USERS_CONNECTED`
- `SERVICES_STATUS` (es. `apache2:ACTIVE,ssh:DOWN`)
- `SERVICES_DOWN_COUNT`

## Contratto `alerts.log`

Formato line-based parseabile deterministicamente:

```txt
timestamp|event_type|severity|title|channel|outcome|details
```

Esempio:

```txt
2026-04-17 12:00:00|DISK|CRITICAL|disk_usage_high|slack|simulated|attempt=1 simulation_mode
```

Valori tipici `outcome`:

- `sent`
- `simulated`
- `skipped`
- `failed`

## Notification engine

`send-notification.sh` implementa:

- dispatch verso `email`, `slack`, `telegram`
- rendering template da `/opt/alerting/templates/*.tpl`
- dedup evento per fingerprint (`event_type|severity|title`)
- rate limit per fingerprint
- retry su errori transient (`curl/mail`)
- logging outcome per canale + outcome dispatcher

## Come funziona internamente

Il sistema segue un flusso lineare e semplice:

1. `alert-system.sh` legge metriche e stato servizi.
2. Quando trova una condizione critica o warning, genera un evento.
3. `send-notification.sh` calcola un fingerprint dell'evento.
4. Prima di inviare, applica lock, dedup e rate limit sul fingerprint.
5. Se l'evento e valido, prova i canali configurati e scrive sempre l'esito nel log strutturato.
6. `dashboard.php` legge `variables.data` e solo le ultime righe di `alerts.log`, poi mostra lo stato corrente e gli ultimi alert.

In pratica:

- monitor -> evento
- evento -> lock / dedup / rate limit
- evento valido -> notifica
- notifica -> log strutturato
- dashboard -> lettura file runtime

## Dashboard

`dashboard.php` mostra:

- stato generale
- metriche base (disk, load, servizi)
- ultimi 20 alert da `alerts.log`
- fallback robusti se file runtime mancanti

## Smoke tests minimi

Script:

```bash
bash scripts/smoke.sh
```

Copertura smoke:

1. sintassi bash (`alert-system.sh`, `send-notification.sh`, `entrypoint.sh`)
2. sintassi PHP dashboard
3. esecuzione monitor e generazione `variables.data`
4. invio simulato multi-canale
5. dedup/rate-limit base
6. rendering dashboard senza fatal

## Verifica manuale rapida

```bash
docker compose up -d --build
docker compose logs -f alerting
```

```bash
docker compose exec -T alerting bash -lc '/opt/alerting/alert-system.sh && tail -n 20 /var/log/alerts.log'
```

```bash
docker compose exec -T alerting php -d display_errors=1 -d error_reporting=E_ALL /var/www/html/dashboard.php >/tmp/dashboard.out
```

## Limiti noti residui

- Invio email reale dipende dalla disponibilita del comando `mail` e della configurazione SMTP del container.
- Slack/Telegram in produzione richiedono credenziali valide nel config.
- Lo storage runtime e file-based (scelta intenzionale v1 semplice), non distribuito.
