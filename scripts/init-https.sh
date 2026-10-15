#!/bin/sh
# Run as the CMD of the container:
# 1. Generate nginx.conf from the template (substitutes ${DOMAIN})
# 2. Get the Let's Encrypt certificate (or a self-signed one as a fallback)
# 3. Start supervisord (api, client, nginx, certbot-renew)
set -eu

DOMAIN="${DOMAIN:?DOMAIN env var is missing}"
EMAIL="${LETS_ENCRYPT_EMAIL:?LETS_ENCRYPT_EMAIL env var is missing}"
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
WEBROOT="/var/www/certbot"

# 1. Generate nginx.conf from the template (only ${DOMAIN} is substituted,
#    nginx variables such as $host $request_uri stay intact)
envsubst '${DOMAIN}' < /etc/nginx/nginx.template.conf > /etc/nginx/nginx.conf
echo "[init-https] nginx.conf generated for domain: $DOMAIN"

# 2. Get the certificate if it does not exist yet
if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    echo "[init-https] No certificate found, requesting one from Let's Encrypt..."
    mkdir -p "$WEBROOT"

    # Start a temporary HTTP-only nginx to answer the ACME challenge
    nginx -c /etc/nginx/nginx-acme.conf
    sleep 1

    if certbot certonly \
        --webroot -w "$WEBROOT" \
        -d "$DOMAIN" \
        -d "www.$DOMAIN" \
        --email "$EMAIL" \
        --agree-tos --non-interactive; then
        echo "[init-https] Let's Encrypt certificate obtained successfully"
    else
        echo "[init-https] WARNING: Let's Encrypt failed, generating a self-signed certificate"
        mkdir -p "$CERT_DIR"
        openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName=DNS:$DOMAIN,DNS:www.$DOMAIN"
        cp "$CERT_DIR/fullchain.pem" "$CERT_DIR/chain.pem"
    fi

    # Stop the temporary nginx
    nginx -s quit 2>/dev/null || true
    sleep 1
else
    echo "[init-https] Certificate already present for $DOMAIN"
fi

# 3. Start supervisor (manages api, client, nginx with HTTPS, certbot-renew)
exec /usr/bin/supervisord -c /etc/supervisord.conf
