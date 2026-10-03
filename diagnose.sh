#!/usr/bin/env bash
# Diagnóstico del panel y del motor (Pelican + Wings). Solo LEE: no cambia nada.
# Reúne en un único texto lo que hace falta para saber por qué algo no funciona (por ejemplo, un servidor que
# se queda «instalando»). Quita tokens y claves antes de mostrarlo, así que se puede pegar tal cual.
#
#   curl -fsSL https://raw.githubusercontent.com/Rassher/mc-panel-installer/main/diagnose.sh | bash
#
# El resultado también queda en /tmp/diagnostico.txt
set -u
OUT=/tmp/diagnostico.txt
PEL=/var/www/pelican

redact() {
  sed -E \
    -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1<oculto>/g' \
    -e 's/(papp_|pacc_)[A-Za-z0-9]+/\1<oculto>/g' \
    -e 's/((token|secret|password|api_key|key)[A-Za-z_]*[=:] *)[^ ,"]+/\1<oculto>/Ig'
}
sec() { printf '\n===== %s =====\n' "$*"; }

{
  echo "Diagnóstico $(date -Is)"
  sec "Sistema"
  . /etc/os-release 2>/dev/null; echo "$PRETTY_NAME | $(uname -m) | RAM libre: $(free -h | awk '/Mem/{print $7}') | disco libre: $(df -h / | awk 'NR==2{print $4}')"
  echo "Docker: $(docker --version 2>&1)"
  echo "Wings:  $(/usr/local/bin/wings version 2>&1 | head -1)"
  echo "Pelican: $(sudo -u www-data php "$PEL/artisan" --version 2>&1 | head -1)"

  sec "Servicios"
  for s in docker nginx "php*-fpm" wings pelican-queue mc-panel-update.timer; do
    printf '%-22s %s\n' "$s" "$(systemctl is-active $s 2>&1 | tr '\n' ' ')"
  done

  sec "Contenedores"
  docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>&1 | head -20

  sec "Servidores según Pelican (nombre | estado | egg | imagen)"
  sudo -u www-data env HOME=/tmp php "$PEL/artisan" tinker --execute='foreach(\App\Models\Server::with("egg")->get() as $s){ echo $s->uuid." | ".$s->name." | estado: ".($s->status?->value ?? "ninguno")." | egg: ".($s->egg?->name)." | imagen: ".$s->image."\n"; }' 2>&1 | head -20

  sec "Nodo según Pelican"
  sudo -u www-data env HOME=/tmp php "$PEL/artisan" tinker --execute='foreach(\App\Models\Node::all() as $n){ echo $n->id." | ".$n->name." | ".$n->scheme."://".$n->fqdn.":".$n->daemon_connect." | proxy:".(int)$n->behind_proxy."\n"; }' 2>&1 | head -5

  sec "Archivos de cada servidor en Wings"
  for d in /var/lib/pelican/volumes/*/; do [ -d "$d" ] && { echo "$d"; ls -la "$d" | head -12; }; done 2>&1 | head -60

  sec "Registros de instalación de Wings (/var/log/pelican/install)"
  ls -la /var/log/pelican/install 2>&1 | head -10
  for f in $(ls -t /var/log/pelican/install/*.log 2>/dev/null | head -2); do echo "--- $f"; tail -40 "$f"; done

  sec "Wings: qué pasó con instalaciones y creaciones (últimas 6 h)"
  journalctl -u wings --since "6 hours ago" --no-pager 2>&1 | grep -iE "install|creat|egg|script|download|pull|error|warn|fail|panel|remote" | grep -v "TLS handshake" | tail -60

  sec "Pelican: errores recientes (storage/logs)"
  tail -c 6000 "$(ls -t $PEL/storage/logs/*.log 2>/dev/null | head -1)" 2>/dev/null | grep -E "ERROR|Exception|Error" | cut -c1-300 | tail -15

  sec "Panel (contenedor): últimas líneas"
  docker logs --tail 25 mc-panel-panel-1 2>&1 | cut -c1-250

  sec "nginx: sitios activos"
  ls /etc/nginx/sites-enabled/ 2>&1
} 2>&1 | redact | tee "$OUT"

echo
echo "Guardado también en $OUT. Pega aquí el texto de arriba (no lleva tokens ni claves)."
