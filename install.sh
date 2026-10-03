#!/usr/bin/env bash
# Instalador del panel en la VPS. Se puede ejecutar las veces que haga falta: lo que ya está
# hecho se respeta (no pisa .env.production) y lo demás se actualiza.
#
# Uso (una sola línea; en una Ubuntu/Debian recién instalada, como root):
#   curl -fsSL https://raw.githubusercontent.com/Rassher/mc-panel-installer/main/install.sh | bash
#
# Opcional: si antes copias tu .env.local a /tmp/panel.env, se usa en vez de preguntar cada valor.
set -euo pipefail
# Si algo falla, que diga qué comando y en qué línea (si no, `set -e` sale sin explicar nada).
trap 'printf "\033[31m✗ Falló (línea %s): %s\033[0m\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

IMAGE="ghcr.io/rassher/mc-panel:latest"
DIR="/opt/mc-panel"
RAW="https://raw.githubusercontent.com/Rassher/mc-panel-installer/main"
GH_USER="Rassher"
DEFAULT_DOMAIN="gestor.rassher.es"

b() { printf '\033[1m%s\033[0m\n' "$*"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ejecútalo con sudo."
[ -r /dev/tty ] || die "Hace falta un terminal interactivo."

# Pregunta un valor. ask VARIABLE "texto" [valor_por_defecto] [secreto]
ask() {
  local var="$1" text="$2" def="${3:-}" secret="${4:-}" val
  if [ -n "${!var:-}" ]; then return; fi
  if [ -n "$def" ]; then text="$text [$def]"; fi
  if [ -n "$secret" ]; then
    read -r -s -p "$text: " val </dev/tty; echo
  else
    read -r -p "$text: " val </dev/tty
  fi
  printf -v "$var" '%s' "${val:-$def}"
}

b "1/7 Dependencias (máquina nueva: se instala lo que falte)"
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null; then
  apt-get update -qq
  # curl/openssl/ca-certificates: descargas y claves · nginx+certbot: HTTPS · ufw: cortafuegos (solo se usa si está activo)
  apt-get install -y -qq curl ca-certificates openssl gnupg nginx certbot python3-certbot-nginx ufw >/dev/null
else
  warn "No es un sistema con apt (Debian/Ubuntu): instala a mano curl, openssl, nginx y certbot."
fi
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker >/dev/null 2>&1 || true
systemctl enable --now nginx >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 || die "Falta el plugin «docker compose»."
ok "Docker listo"

b "2/7 Archivos de despliegue"
mkdir -p "$DIR/deploy"
for f in compose.yml deploy/install-engine.sh deploy/update.sh deploy/mc-panel-update.service deploy/mc-panel-update.timer; do
  curl -fsSL "$RAW/$f" -o "$DIR/$f" || die "No pude descargar $RAW/$f"
done
chmod +x "$DIR"/deploy/*.sh
ok "Archivos en $DIR"

b "2b/7 Motor: Pelican + Wings"
if [ -f /etc/pelican/config.yml ] && [ -f /var/www/pelican/.env ]; then
  ok "Pelican y Wings ya están instalados"
elif [ -f "$DIR/engine.env" ]; then
  ok "Motor ya preparado (engine.env)"
else
  read -r -p "¿Instalar Pelican y Wings en esta máquina? (hacen falta para crear y ejecutar servidores) [S/n]: " ENGINE </dev/tty
  case "${ENGINE:-S}" in
    [nN]*) warn "Sin motor: tendrás que rellenar a mano los datos de Pelican y Wings." ;;
    *) bash "$DIR/deploy/install-engine.sh" ;;
  esac
fi
# Si el motor dejó sus datos, se usan como valores por defecto (no se vuelven a preguntar).
if [ -f "$DIR/engine.env" ] && [ ! -f "$DIR/.env.production" ]; then
  set -a; . "$DIR/engine.env"; set +a
fi

b "3/7 Configuración"
if [ -f "$DIR/.env.production" ]; then
  ok ".env.production ya existe: se conserva"
  DOMAIN="$(grep -E '^APP_URL=' "$DIR/.env.production" | sed -E 's#^APP_URL=https?://##; s#/.*##')"
  LAUNCHER_DOMAIN="$(grep -E '^LAUNCHER_URL=' "$DIR/.env.production" | sed -E 's#^LAUNCHER_URL=https?://##; s#/.*##' || true)"
  if [ -z "$LAUNCHER_DOMAIN" ]; then
    LAUNCHER_DOMAIN="launcher.${DOMAIN#*.}"
    printf 'LAUNCHER_URL=https://%s\n' "$LAUNCHER_DOMAIN" >> "$DIR/.env.production"
  fi
else
  ask DOMAIN "Dominio del panel" "$DEFAULT_DOMAIN"
  ask LAUNCHER_DOMAIN "Dominio público del launcher (NLauncher)" "launcher.${DOMAIN#*.}"
  if [ -f /tmp/panel.env ]; then
    cp /tmp/panel.env "$DIR/.env.production"
    sed -i '/^APP_URL=/d; /^SFTP_HOST=/d; /^NODE_ENV=/d; /^LAUNCHER_URL=/d' "$DIR/.env.production"
    printf '\nAPP_URL=https://%s\nSFTP_HOST=%s\nLAUNCHER_URL=https://%s\n' "$DOMAIN" "$DOMAIN" "$LAUNCHER_DOMAIN" >> "$DIR/.env.production"
    shred -u /tmp/panel.env 2>/dev/null || rm -f /tmp/panel.env
    ok "Usando los valores de /tmp/panel.env (y borrado de /tmp)"
  else
    echo "Los datos salen de tu Discord Developer Portal, de Wings (/etc/pelican/config.yml) y de Pelican."
    ask DISCORD_CLIENT_ID "Discord · Client ID"
    ask DISCORD_CLIENT_SECRET "Discord · Client Secret (no se ve al escribir)" "" 1
    ask ADMIN_DISCORD_IDS "IDs de Discord de los administradores (separados por comas)"
    ask ALLOWED_DISCORD_IDS "IDs de Discord de usuarios normales (opcional)" ""
    ask WINGS_URL "URL de Wings" "https://nodo.rassher.es:8080"
    ask WINGS_TOKEN "Token de Wings (no se ve al escribir)" "" 1
    ask WINGS_ORIGIN "Origen del Pelican (para el WebSocket)" "https://panel.rassher.es"
    ask PELICAN_URL "URL de Pelican" "https://panel.rassher.es"
    ask PELICAN_API_KEY "Clave de API de aplicación de Pelican (papp_…)" "" 1
    ask PELICAN_OWNER_ID "ID del usuario dueño de los servidores en Pelican" "1"
    ask PELICAN_NODE_ID "ID del nodo en Pelican" "2"
    ask PELICAN_PORT_RANGE "Rango de puertos para servidores nuevos" "25566-25599"
    umask 077
    cat > "$DIR/.env.production" <<ENV
APP_URL=https://$DOMAIN
SESSION_SECRET=$(openssl rand -hex 32)
DISCORD_CLIENT_ID=$DISCORD_CLIENT_ID
DISCORD_CLIENT_SECRET=$DISCORD_CLIENT_SECRET
ADMIN_DISCORD_IDS=$ADMIN_DISCORD_IDS
ALLOWED_DISCORD_IDS=$ALLOWED_DISCORD_IDS
WINGS_URL=$WINGS_URL
WINGS_TOKEN=$WINGS_TOKEN
WINGS_ORIGIN=$WINGS_ORIGIN
PELICAN_URL=$PELICAN_URL
PELICAN_API_KEY=$PELICAN_API_KEY
PELICAN_OWNER_ID=$PELICAN_OWNER_ID
PELICAN_NODE_ID=$PELICAN_NODE_ID
PELICAN_PORT_RANGE=$PELICAN_PORT_RANGE
${PELICAN_ALLOCATION_IP:+PELICAN_ALLOCATION_IP=$PELICAN_ALLOCATION_IP}
SFTP_PORT=2222
SFTP_HOST=$DOMAIN
LAUNCHER_URL=https://$LAUNCHER_DOMAIN
ENV
    ok "Guardado en $DIR/.env.production (solo legible por root)"
  fi
fi
chmod 600 "$DIR/.env.production"

WINGS_CHECK="$(grep -E '^WINGS_URL=' "$DIR/.env.production" | cut -d= -f2-)"
if [ -n "$WINGS_CHECK" ] && ! curl -ks -o /dev/null --max-time 8 "$WINGS_CHECK/api/system"; then
  warn "No llego a Wings en $WINGS_CHECK. El panel arrancará, pero no podrá gestionar servidores hasta que Wings (y Pelican) estén funcionando."
fi

b "3b/7 Imagen del panel"
# La imagen es privada: la primera vez hace falta un token de GitHub (classic) con el permiso read:packages.
registry_login() {
  docker pull -q "$IMAGE" >/dev/null 2>&1 && return 0
  warn "La imagen del panel es privada. Hace falta un token de GitHub (de la cuenta $GH_USER) con el permiso read:packages."
  echo "  Créalo aquí (tipo «classic»): https://github.com/settings/tokens/new?scopes=read:packages&description=vps-mc-panel"
  local i T
  for i in 1 2 3; do
    T=""
    read -r -s -p "Token de GitHub (empieza por ghp_ y tiene unos 40 caracteres): " T </dev/tty; echo
    echo "  (llegaron ${#T} caracteres)"
    if printf '%s' "$T" | docker login ghcr.io -u "$GH_USER" --password-stdin >/dev/null 2>&1 && docker pull -q "$IMAGE" >/dev/null 2>&1; then
      ok "Acceso al registro correcto (se queda guardado para las actualizaciones automáticas)"
      return 0
    fi
    warn "GitHub rechazó ese token. Comprueba que es «classic», con read:packages, de la cuenta $GH_USER, y que lo copiaste entero."
  done
  die "No consigo acceder a la imagen $IMAGE."
}
registry_login
ok "Imagen del panel descargada"

b "4/7 Arrancando el panel"
(cd "$DIR" && docker compose up -d)
sleep 4
docker compose -f "$DIR/compose.yml" --project-directory "$DIR" logs --tail 5 panel || true
ok "Panel en marcha (127.0.0.1:3000)"

b "5/7 Actualización automática"
cp "$DIR"/deploy/mc-panel-update.service "$DIR"/deploy/mc-panel-update.timer /etc/systemd/system/
sed -i "s#/opt/mc-panel#$DIR#g" /etc/systemd/system/mc-panel-update.service
systemctl daemon-reload
systemctl enable --now mc-panel-update.timer >/dev/null
ok "Cada minuto comprueba si hay una versión nueva"

b "6/7 Cortafuegos"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 2222/tcp >/dev/null
  ok "Puerto 2222 (SFTP) abierto en ufw"
else
  ok "ufw no está activo: nada que abrir (si tu proveedor tiene cortafuegos externo, abre el 2222/tcp)"
fi

MYIP="$(curl -4 -fsS https://ifconfig.me 2>/dev/null || true)"

# web DOMINIO MODO   (MODO: panel = todo el panel · launcher = solo lo público que usa NLauncher)
web() {
  local domain="$1" mode="$2" dnsip conf
  dnsip="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -z "$dnsip" ] || { [ -n "$MYIP" ] && [ "$dnsip" != "$MYIP" ]; }; then
    warn "El DNS de $domain ${dnsip:+apunta a $dnsip, no a esta VPS ($MYIP)}${dnsip:-no resuelve todavía}."
    warn "Crea el registro A  $domain → ${MYIP:-la IP de esta VPS}  y vuelve a ejecutar este instalador (no pierde nada)."
    return 0
  fi
  if ! command -v nginx >/dev/null || ! command -v certbot >/dev/null; then
    apt-get update -qq && apt-get install -y -qq nginx certbot python3-certbot-nginx >/dev/null
  fi
  conf="/etc/nginx/conf.d/$domain.conf"
  if [ -d /etc/nginx/sites-available ]; then conf="/etc/nginx/sites-available/$domain"; ln -sf "$conf" "/etc/nginx/sites-enabled/$domain"; fi
  if [ ! -f "$conf" ]; then
    if [ "$mode" = "launcher" ]; then
      # Solo se exponen la lista de servidores, los manifiestos y las descargas. El resto del panel no existe en este dominio.
      cat > "$conf" <<NGINX
server {
    listen 80;
    server_name $domain;

    location ~ ^/(api/launcher/|dl/) {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;          # descargas grandes sin pasar por disco
        proxy_read_timeout 10m;
    }
    location / { return 404; }
}
NGINX
    else
      cat > "$conf" <<NGINX
server {
    listen 80;
    server_name $domain;
    client_max_body_size 1100m;       # subida de mods/packs desde el panel

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;          # consola en vivo (Server-Sent Events)
        proxy_request_buffering off;  # subidas en streaming
        proxy_read_timeout 1h;
    }
}
NGINX
    fi
  fi
  nginx -t >/dev/null 2>&1 || die "La configuración de nginx tiene errores (nginx -t)."
  systemctl reload nginx
  local flag="--register-unsafely-without-email"
  [ -d /etc/letsencrypt/accounts ] && flag=""
  # shellcheck disable=SC2086
  certbot --nginx -d "$domain" --non-interactive --agree-tos --redirect $flag >/dev/null 2>&1 \
    && ok "HTTPS activo en https://$domain" \
    || warn "certbot no pudo emitir el certificado; mira: certbot --nginx -d $domain"
}

b "7/7 Web con HTTPS ($DOMAIN y $LAUNCHER_DOMAIN)"
web "$DOMAIN" panel
web "$LAUNCHER_DOMAIN" launcher

echo
b "Listo. Falta una cosa en Discord:"
echo "  Developer Portal → tu aplicación → OAuth2 → Redirects → añade:"
echo "  https://$DOMAIN/api/auth/discord/callback"
echo
echo "NLauncher descarga de:  https://$LAUNCHER_DOMAIN  (lista de servidores y archivos)."
echo "Para traer los mods y servidores del Drive viejo (una sola vez), mira el README → «Importar desde Drive»."
echo
echo "Para actualizar el panel no hay que hacer nada: se actualiza solo al subir cambios a GitHub."
echo "Si ejecutas este instalador otra vez, no pierde nada: conserva .env.production y lo demás."
echo "Ver el estado:  sudo docker compose -f $DIR/compose.yml --project-directory $DIR logs -f panel"
