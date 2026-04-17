FROM php:8.2-apache

RUN apt-get update && apt-get install -y \
    curl \
    procps \
    bsd-mailx \
    && rm -rf /var/lib/apt/lists/*

# Copia struttura base
COPY opt/alerting /opt/alerting
COPY var/www/html /var/www/html
COPY etc/alerting /etc/alerting

RUN chmod +x /opt/alerting/*.sh \
    && mkdir -p /var/log \
    && touch /var/log/alerts.log \
    && echo 'ServerName localhost' > /etc/apache2/conf-available/servername.conf \
    && a2enconf servername

EXPOSE 80