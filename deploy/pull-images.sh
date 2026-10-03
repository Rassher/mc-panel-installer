#!/usr/bin/env bash
# Descarga las imágenes de Docker que usan los eggs de Pelican (las de Java de los servidores y las de instalación).
#
# Por qué hace falta: Wings crea el contenedor del servidor en el momento de crearlo y, si la imagen no está ya en
# la máquina, la instalación se aborta («No such image»): el servidor se queda «instalando» para siempre. En una
# máquina nueva no hay ninguna imagen, así que se bajan todas de antemano y se revisan cada media hora (por si se
# importa un egg nuevo o aparece una versión de Java nueva).
#
#   pull-images.sh              descarga lo que falte ahora
#   pull-images.sh --install    además, lo deja programado cada 30 minutos (cron)
set -u
PEL=/var/www/pelican
SELF="$(readlink -f "$0")"

[ -f "$PEL/artisan" ] || exit 0          # sin Pelican en esta máquina no hay nada que hacer
command -v docker >/dev/null || exit 0

if [ "${1:-}" = "--install" ]; then
  printf '*/30 * * * * root %s >> /var/log/pelican-images.log 2>&1\n' "$SELF" > /etc/cron.d/pelican-images
  chmod 644 /etc/cron.d/pelican-images
fi

# Imágenes de todos los eggs: las de ejecución (docker_images) y la del script de instalación.
LIST="$(sudo -u www-data env HOME=/tmp php "$PEL/artisan" tinker --execute='
foreach (\App\Models\Egg::all() as $e) {
  foreach ((array) $e->docker_images as $i) { echo $i, "\n"; }
  if (!empty($e->script_container)) { echo $e->script_container, "\n"; }
}' 2>/dev/null | grep -E '^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$' | sort -u)"

[ -n "$LIST" ] || { echo "No pude leer las imágenes de los eggs (¿Pelican sin eggs todavía?)."; exit 0; }

for img in $LIST; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    # Ya está: se actualiza en silencio por si hay una versión nueva con el mismo nombre.
    docker pull -q "$img" >/dev/null 2>&1 || true
  else
    echo "Descargando $img …"
    docker pull -q "$img" >/dev/null 2>&1 && echo "  listo" || echo "  ✗ no se pudo descargar $img"
  fi
done
