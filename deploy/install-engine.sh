#!/usr/bin/env bash
# Instala el «motor» del panel: Pelican (crea/borra servidores) y Wings (los ejecuta en Docker).
# Lo llama deploy/install.sh, pero también se puede ejecutar solo. Se puede repetir: lo que ya está no se pisa.
#
# Hace, sin tocar el navegador: PHP + nginx + HTTPS, Pelican con SQLite, tu usuario administrador, los eggs de
# Minecraft, el nodo, Wings como servicio, y una clave de API para nuestro panel. Al final deja los valores
# listos en /opt/mc-panel/engine.env (el instalador del panel los usa para rellenar .env.production).
#
# Variables opcionales (si no, pregunta): PANEL_DOMAIN NODE_DOMAIN ADMIN_EMAIL ADMIN_USER ADMIN_PASSWORD
set -euo pipefail
# Si algo falla, que diga qué comando y en qué línea (si no, `set -e` sale sin explicar nada).
trap 'printf "\033[31m✗ Falló (línea %s): %s\033[0m\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

PEL="/var/www/pelican"
OUT="/opt/mc-panel/engine.env"
EGGS_BASE="https://raw.githubusercontent.com/pelican-eggs/minecraft/HEAD"
EGGS=(
  java/paper/egg-paper.yaml
  java/purpur/egg-purpur.yaml
  java/spigot/egg-spigot.yaml
  java/fabric/egg-fabric.yaml
  java/forge/egg-forge-minecraft.yaml
  java/vanilla/egg-vanilla-minecraft.yaml
  java/neoforge/egg-neo-forge.json
  java/folia/egg-folia.yaml
  proxy/java/velocity/egg-velocity.json
)

b() { printf '\033[1m%s\033[0m\n' "$*"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ejecútalo con sudo."
command -v apt-get >/dev/null || die "Solo Debian/Ubuntu (usa apt)."
export DEBIAN_FRONTEND=noninteractive

ask() {
  local var="$1" text="$2" def="${3:-}" secret="${4:-}" val
  if [ -n "${!var:-}" ]; then return; fi
  if [ -n "$def" ]; then text="$text [$def]"; fi
  if [ -n "$secret" ]; then read -r -s -p "$text: " val </dev/tty; echo; else read -r -p "$text: " val </dev/tty; fi
  printf -v "$var" '%s' "${val:-$def}"
}

b "Motor (Pelican + Wings): datos"
ask PANEL_DOMAIN "Dominio de Pelican (motor oculto)" "panel.rassher.es"
ask NODE_DOMAIN "Dominio del nodo (Wings)" "nodo.rassher.es"
ask ADMIN_EMAIL "Correo del administrador de Pelican (también para los certificados)"
ask ADMIN_USER "Usuario administrador de Pelican" "rassher"
GEN_PASS=""
if [ -z "${ADMIN_PASSWORD:-}" ]; then
  ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  GEN_PASS=1
fi

MYIP="$(curl -4 -fsS https://ifconfig.me 2>/dev/null || true)"
dns_ok() {
  local ip; ip="$(getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}')"
  [ -n "$ip" ] && { [ -z "$MYIP" ] || [ "$ip" = "$MYIP" ]; }
}
for d in "$PANEL_DOMAIN" "$NODE_DOMAIN"; do
  dns_ok "$d" || die "El DNS de $d no apunta a esta máquina (${MYIP:-IP desconocida}). Crea el registro A y vuelve a ejecutar."
done

# ---------------------------------------------------------------------------------------------
b "1/8 Paquetes (PHP, nginx, certbot, Docker…)"
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl tar unzip git sudo nginx certbot python3-certbot-nginx \
  php-cli php-fpm php-gd php-mysql php-mbstring php-bcmath php-xml php-curl php-zip php-intl php-sqlite3 sqlite3 >/dev/null
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
systemctl enable --now docker nginx >/dev/null 2>&1 || true
PHPV="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
SOCK="/run/php/php${PHPV}-fpm.sock"
systemctl enable --now "php${PHPV}-fpm" >/dev/null 2>&1 || die "No arranca php${PHPV}-fpm."
ok "PHP $PHPV listo"

# ---------------------------------------------------------------------------------------------
b "2/8 Pelican (panel)"
art() { sudo -u www-data php "$PEL/artisan" "$@"; }
# Igual, pero en silencio si va bien y enseñando el motivo si falla.
art_q() {
  local out
  out="$(art "$@" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
}
if [ ! -f "$PEL/artisan" ]; then
  mkdir -p "$PEL"
  curl -fsSL https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xz -C "$PEL"
  command -v composer >/dev/null || { curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer >/dev/null; }
  (cd "$PEL" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction >/dev/null 2>&1) || die "composer install falló (ejecútalo a mano en $PEL para ver el error)."
fi
chown -R www-data:www-data "$PEL"
chmod -R 755 "$PEL/storage" "$PEL/bootstrap/cache"

FIRST=""
if [ ! -f "$PEL/.env" ] || ! grep -q '^APP_INSTALLED=true' "$PEL/.env"; then
  FIRST=1
  [ -f "$PEL/.env" ] || cp "$PEL/.env.example" "$PEL/.env"
  chown www-data:www-data "$PEL/.env"
  grep -qE '^APP_KEY=.+' "$PEL/.env" || art_q key:generate --force --no-interaction
  # En las versiones recientes de Pelican p:environment:setup no admite --url: la dirección se escribe en .env.
  sed -i "s#^APP_URL=.*#APP_URL=https://$PANEL_DOMAIN#" "$PEL/.env"
  art_q p:environment:setup --no-interaction
  # Se acepta el esquema de instalación por CLI: sin el asistente web.
  sed -i 's/^APP_INSTALLED=.*/APP_INSTALLED=true/' "$PEL/.env"
  grep -q '^TRUSTED_PROXIES=' "$PEL/.env" || echo 'TRUSTED_PROXIES=127.0.0.1' >> "$PEL/.env"
  touch "$PEL/database/database.sqlite" && chown www-data:www-data "$PEL/database/database.sqlite"
  art_q migrate --seed --force --no-interaction
fi
ok "Pelican configurado"

# ---------------------------------------------------------------------------------------------
b "3/8 nginx + HTTPS para $PANEL_DOMAIN"
cat > "/etc/nginx/sites-available/$PANEL_DOMAIN" <<'NGINX'
server {
    listen 80;
    server_name __DOMAIN__;
    root /var/www/pelican/public;
    index index.php;
    charset utf-8;
    client_max_body_size 100m;

    location / { try_files $uri $uri/ /index.php?$query_string; }
    location = /favicon.ico { access_log off; log_not_found off; }
    access_log off;
    error_log /var/log/nginx/pelican.app-error.log error;
    sendfile off;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:__SOCK__;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
    location ~ /\.ht { deny all; }
}
NGINX
sed -i "s#__DOMAIN__#$PANEL_DOMAIN#; s#__SOCK__#$SOCK#" "/etc/nginx/sites-available/$PANEL_DOMAIN"
ln -sf "/etc/nginx/sites-available/$PANEL_DOMAIN" "/etc/nginx/sites-enabled/$PANEL_DOMAIN"
nginx -t >/dev/null 2>&1 || die "nginx -t falla: revisa /etc/nginx/sites-available/$PANEL_DOMAIN"
systemctl reload nginx
CERT_ACCOUNT="--email $ADMIN_EMAIL"
certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos --redirect $CERT_ACCOUNT >/dev/null 2>&1 \
  || die "certbot no pudo emitir el certificado de $PANEL_DOMAIN (¿DNS y puertos 80/443 abiertos?)."
ok "https://$PANEL_DOMAIN activo"

# ---------------------------------------------------------------------------------------------
b "4/8 Cola, tareas y usuario administrador"
cat > /etc/cron.d/pelican <<CRON
* * * * * www-data /usr/bin/php $PEL/artisan schedule:run >> /dev/null 2>&1
CRON
php "$PEL/artisan" p:environment:queue-service --service-name=pelican-queue --user=www-data --group=www-data --overwrite --no-interaction >/dev/null
systemctl daemon-reload
systemctl enable --now pelican-queue >/dev/null 2>&1 || warn "No pude activar pelican-queue (revisa: systemctl status pelican-queue)."
if [ -n "$FIRST" ]; then
  art_q p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" --password="$ADMIN_PASSWORD" --admin=1 --no-interaction \
    || die "No pude crear el usuario administrador."
  ok "Administrador «$ADMIN_USER» creado"
fi

# Pequeño ayudante para ejecutar PHP dentro de la aplicación (servicios internos de Pelican).
phpx() {
  local f; f="$(mktemp /tmp/pelx.XXXXXX.php)"
  {
    echo "<?php require '$PEL/vendor/autoload.php'; \$app = require '$PEL/bootstrap/app.php';"
    echo "\$app->make(Illuminate\\Contracts\\Console\\Kernel::class)->bootstrap();"
    cat
  } > "$f"
  chmod 644 "$f"
  sudo -u www-data php "$f" "$@"
  rm -f "$f"
}

# ---------------------------------------------------------------------------------------------
b "5/8 Eggs de Minecraft"
for egg in "${EGGS[@]}"; do
  for try in 1 2 3; do
    if phpx "$EGGS_BASE/$egg" >/dev/null 2>&1 <<'PHP'
$egg = app(\App\Services\Eggs\Sharing\EggImporterService::class)->fromUrl($argv[1]);
echo $egg->name;
PHP
    then ok "$(basename "$egg")"; break; fi
    [ "$try" = 3 ] && warn "No se pudo importar $egg (se puede añadir luego desde Pelican → Eggs → Importar)."
    sleep 2
  done
done

# ---------------------------------------------------------------------------------------------
b "5b/8 Imágenes de Docker de los eggs"
# Sin ellas, Wings aborta la instalación del primer servidor («No such image»). Ver pull-images.sh.
PULL="$(dirname "$(readlink -f "$0")")/pull-images.sh"
if [ -f "$PULL" ]; then bash "$PULL" --install && ok "Imágenes descargadas y revisión programada cada 30 min"; else warn "No encuentro $PULL"; fi

# ---------------------------------------------------------------------------------------------
b "6/8 Nodo ($NODE_DOMAIN) y su certificado"
cat > "/etc/nginx/sites-available/$NODE_DOMAIN" <<NGINX
server {
    listen 80;
    server_name $NODE_DOMAIN;
    location / { return 404; }
}
NGINX
ln -sf "/etc/nginx/sites-available/$NODE_DOMAIN" "/etc/nginx/sites-enabled/$NODE_DOMAIN"
nginx -t >/dev/null 2>&1 && systemctl reload nginx
certbot certonly --nginx -d "$NODE_DOMAIN" --non-interactive --agree-tos $CERT_ACCOUNT >/dev/null 2>&1 \
  || die "certbot no pudo emitir el certificado de $NODE_DOMAIN."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl restart wings\n' > /etc/letsencrypt/renewal-hooks/deploy/wings.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/wings.sh

MEM_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 * 9 / 10 ))
DISK_MB=$(( $(df -m --output=avail / | tail -1) * 9 / 10 ))
NODE_ID="$(phpx "$NODE_DOMAIN" <<'PHP'
echo \App\Models\Node::query()->where('fqdn', $argv[1])->value('id');
PHP
)"
if [ -z "$NODE_ID" ]; then
  art_q p:node:make --no-interaction --name="Principal" --description="Nodo principal" --fqdn="$NODE_DOMAIN" \
    --public=1 --scheme=https --proxy=0 --maintenance=0 \
    --maxMemory="$MEM_MB" --overallocateMemory=0 --maxDisk="$DISK_MB" --overallocateDisk=0 \
    --maxCpu=0 --overallocateCpu=0 || die "No pude crear el nodo."
  NODE_ID="$(phpx "$NODE_DOMAIN" <<'PHP'
echo \App\Models\Node::query()->where('fqdn', $argv[1])->value('id');
PHP
)"
fi
[ -n "$NODE_ID" ] || die "No encuentro el nodo recién creado."
ok "Nodo #$NODE_ID"

# ---------------------------------------------------------------------------------------------
b "7/8 Wings"
mkdir -p /etc/pelican /var/run/wings /var/lib/pelican/volumes
ARCH="$([ "$(uname -m)" = x86_64 ] && echo amd64 || echo arm64)"
if [ ! -x /usr/local/bin/wings ]; then
  curl -fsSL -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_$ARCH"
  chmod u+x /usr/local/bin/wings
fi
art p:node:configuration "$NODE_ID" > /etc/pelican/config.yml
chmod 600 /etc/pelican/config.yml
cat > /etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Pelican Wings
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable wings >/dev/null 2>&1
systemctl restart wings
for i in $(seq 1 30); do
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 3 "https://$NODE_DOMAIN:8080/api/system" || true)"
  [ "$code" = 401 ] || [ "$code" = 403 ] && break
  sleep 2
done
[ "$code" = 401 ] || [ "$code" = 403 ] && ok "Wings responde en https://$NODE_DOMAIN:8080" || warn "Wings aún no responde (mira: journalctl -u wings -n 30)."

# ---------------------------------------------------------------------------------------------
b "8/8 Clave de API para el panel y datos de salida"
WINGS_TOKEN_VALUE="$(awk '/^token:/{print $2}' /etc/pelican/config.yml | tr -d "\"'")"
OWNER_ID="$(phpx "$ADMIN_EMAIL" <<'PHP'
echo \App\Models\User::query()->where('email', $argv[1])->value('id');
PHP
)"
API_KEY="$(phpx "$OWNER_ID" <<'PHP'
use App\Models\ApiKey;
$perms = array_fill_keys(ApiKey::getPermissionList(), 3);
$key = app(\App\Services\Api\KeyCreationService::class)->setKeyType(ApiKey::TYPE_APPLICATION)
    ->handle(['user_id' => (int) $argv[1], 'memo' => 'mc-panel (creado por el instalador)', 'permissions' => $perms]);
echo $key->identifier . $key->token;
PHP
)"
[ -n "$API_KEY" ] || die "No pude crear la clave de API."

mkdir -p "$(dirname "$OUT")"
umask 077
cat > "$OUT" <<ENV
PELICAN_URL=https://$PANEL_DOMAIN
PELICAN_API_KEY=$API_KEY
PELICAN_OWNER_ID=$OWNER_ID
PELICAN_NODE_ID=$NODE_ID
PELICAN_ALLOCATION_IP=${MYIP}
WINGS_URL=https://$NODE_DOMAIN:8080
WINGS_ORIGIN=https://$PANEL_DOMAIN
WINGS_TOKEN=$WINGS_TOKEN_VALUE
ENV
ok "Valores guardados en $OUT (solo root)"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80,443,8080/tcp >/dev/null; ufw allow 25565:25599/tcp >/dev/null; ufw allow 25565:25599/udp >/dev/null
  ok "Puertos 80, 443, 8080 y 25565-25599 abiertos en ufw"
fi

echo
b "Motor listo."
echo "  Pelican:  https://$PANEL_DOMAIN   (usuario: $ADMIN_USER)"
if [ -n "$GEN_PASS" ] && [ -n "$FIRST" ]; then
  echo "  Contraseña generada: $ADMIN_PASSWORD   ← apúntala ahora; no se vuelve a mostrar"
fi
echo "  Nodo:     https://$NODE_DOMAIN:8080"
