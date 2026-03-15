#!/bin/sh
# Eseguito come CMD del container:
# 1. Genera nginx.conf dal template (sostituisce ${DOMAIN})
# 2. Acquisisce il certificato Let's Encrypt (o self-signed come fallback)
# 3. Avvia supervisord (api, client, nginx, certbot-renew)
set -eu

DOMAIN="${DOMAIN:?DOMAIN env var mancante}"
EMAIL="${LETS_ENCRYPT_EMAIL:?LETS_ENCRYPT_EMAIL env var mancante}"
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
WEBROOT="/var/www/certbot"

# 1. Genera nginx.conf dal template (solo ${DOMAIN} viene sostituito,
#    le variabili nginx come $host $request_uri rimangono intatte)
envsubst '${DOMAIN}' < /etc/nginx/nginx.template.conf > /etc/nginx/nginx.conf
echo "[init-https] nginx.conf generato per dominio: $DOMAIN"

# 2. Acquisisce il certificato se non esiste già
if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    echo "[init-https] Nessun certificato trovato, richiedo a Let's Encrypt..."
    mkdir -p "$WEBROOT"

    # Avvia nginx temporaneo in HTTP-only per rispondere alla ACME challenge
    nginx -c /etc/nginx/nginx-acme.conf
    sleep 1

    if certbot certonly \
        --webroot -w "$WEBROOT" \
        -d "$DOMAIN" \
        --email "$EMAIL" \
        --agree-tos --non-interactive; then
        echo "[init-https] Certificato Let's Encrypt ottenuto con successo"
    else
        echo "[init-https] WARNING: Let's Encrypt fallito, genero certificato self-signed"
        mkdir -p "$CERT_DIR"
        openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN"
        cp "$CERT_DIR/fullchain.pem" "$CERT_DIR/chain.pem"
    fi

    # Ferma il nginx temporaneo
    nginx -s quit 2>/dev/null || true
    sleep 1
else
    echo "[init-https] Certificato già presente per $DOMAIN"
fi

# 3. Avvia supervisor (gestisce api, client, nginx con HTTPS, certbot-renew)
exec /usr/bin/supervisord -c /etc/supervisord.conf
