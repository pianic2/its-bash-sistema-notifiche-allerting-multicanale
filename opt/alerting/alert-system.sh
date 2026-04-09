#!/usr/bin/env bash





# ====== Carico Variabili ======
# Controllo se il file di configurazione esiste, se no esco con errore

CONFIG_FILE="/etc/alerting/config.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERRORE: Il file di configurazione $CONFIG_FILE non esiste."
  exit 1
fi
source "$CONFIG_FILE"






# ====== Controllo Variabili ======
# Controllo se le variabili di configurazione sono definite correttamente

if [[ -z "$DISK_USAGE_THRESHOLD" ]]; then
  echo "ERRORE: DISK_USAGE_THRESHOLD non è definito in $CONFIG_FILE"
  exit 1
fi
if [[ -z "$LOAD_AVERAGE_THRESHOLD" ]]; then
  echo "ERRORE: LOAD_AVERAGE_THRESHOLD non è definito in $CONFIG_FILE"
  exit 1
fi
if [[ -z "$MONITORED_SERVICES" ]]; then
  echo "ERRORE: MONITORED_SERVICES non è definito in $CONFIG_FILE"
  exit 1
fi





# ====== Variabili Script ======
HOST="${HOSTNAME_LABEL:-local}" # Se HOSTNAME_LABEL non è definito, usa "local"
NOW="$(date '+%Y-%m-%d %H:%M:%S')" # Timestamp formattato
IP_ADDRESS=$(hostname -I | awk '{print $1}') # Ottengo il primo indirizzo IP disponibile
IP_ADDRESS=${IP_ADDRESS:-"N/A"} # Se IP_ADDRESS è vuoto, assegna "N/A"

# --- DISK ---
# Ottengo l'utilizzo del disco root (/) e rimuovo il simbolo di percentuale
# stampando solo il numero
DISK_USAGE=$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')
# Se DISK_USAGE è vuoto, assegna 0 per evitare errori nei confronti numerici
[[ -z "$DISK_USAGE" ]] && DISK_USAGE=0
# Se DISK_USAGE non è un numero, assegna 0
[[ "$DISK_USAGE" =~ ^[0-9]+$ ]] || DISK_USAGE=0



# --- LOAD ---

# Ottengo il carico medio del sistema nell'ultimo minuto
LOAD_AVG=$(uptime | awk -F'load average: ' '{print $2}' | cut -d',' -f1 | xargs)
[[ ! "$LOAD_AVG" =~ ^[0-9]+(\.[0-9]+)?$ ]] && LOAD_AVG="0.00" # Se LOAD_AVG non è un float, assegna 0.00

# Ottengo il tempo di attività del sistema in formato leggibile (es. "up 1 day, 2 hours")
UPTIME_READABLE=$(uptime -p)
UPTIME_READABLE="${UPTIME_READABLE:-Unknown}"

# Ottengo il numero di utenti attualmente connessi
USERS_CONNECTED=$(who | wc -l)



# --- SERVICES (mock via pgrep) ---
SERVICES_SERIALIZED=""

# Per ogni servizio monitorato, controllo se è attivo usando pgrep. 
# Se è attivo, lo status è "ACTIVE", altrimenti "DOWN". 
# Serializzo i risultati in un formato chiave-valore separato da virgole (es. "nginx:ACTIVE,mysql:DOWN").
for service in $MONITORED_SERVICES; do
  if pgrep "$service" >/dev/null; then
    status="ACTIVE"
  else
    status="DOWN"
  fi

  SERVICES_SERIALIZED+="${service}:${status},"
done

# Rimuovo l'ultima virgola per evitare problemi di parsing
SERVICES_SERIALIZED="${SERVICES_SERIALIZED%,}"

# Conto quanti servizi sono DOWN
SERVICES_DOWN_COUNT=$(echo "$SERVICES_SERIALIZED" | grep -o "DOWN" | wc -l)


# --- STATUS ---
OVERALL_STATUS="OK"

# Controllo se l'utilizzo del disco supera la soglia definita.
# Se sì, imposto lo stato complessivo su "CRITICAL" e invio una notifica.
if (( DISK_USAGE >= DISK_USAGE_THRESHOLD )); then
  OVERALL_STATUS="CRITICAL"
  bash /opt/alerting/send-notification.sh "DISK" "CRITICAL" "Disk Usage Alert" "Disk usage is at ${DISK_USAGE}% which exceeds the threshold of ${DISK_USAGE_THRESHOLD}%."
fi

# Controllo se il carico medio supera la soglia definita.
# Se sì, imposto lo stato complessivo su "WARNING" e invio una notifica.
if (( $(echo "$LOAD_AVG >= $LOAD_AVERAGE_THRESHOLD" | bc) )) && [[ "$OVERALL_STATUS" == "OK" ]]; then
  OVERALL_STATUS="WARNING"
  bash /opt/alerting/send-notification.sh "LOAD" "WARNING" "Load Average Alert" "Load average is at ${LOAD_AVG} which exceeds the threshold of ${LOAD_AVERAGE_THRESHOLD}."
fi

# Controllo se ci sono servizi DOWN.
# Se sì, imposto lo stato complessivo su "CRITICAL" e invio una notifica per ogni servizio DOWN.
if [[ $SERVICES_DOWN_COUNT -gt 0 ]]; then
  OVERALL_STATUS="CRITICAL"
  for service in $MONITORED_SERVICES; do
    if ! pgrep "$service" >/dev/null; then
      bash /opt/alerting/send-notification.sh "SERVICE_DOWN" "CRITICAL" "$service is down" "$service is not running"
    fi
  done
fi

# --- WRITE FILE ---
cat > /opt/alerting/variables.data <<EOF
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