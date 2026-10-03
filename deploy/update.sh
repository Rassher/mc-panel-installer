#!/bin/sh
# Descarga la imagen más reciente del panel y reinicia el contenedor solo si ha cambiado.
# Lo ejecuta un temporizador de systemd cada minuto (deploy/mc-panel-update.timer).
set -eu
cd "$(dirname "$0")/.."

before=$(docker compose images -q panel 2>/dev/null || true)
docker compose pull --quiet panel
after=$(docker image inspect --format '{{.Id}}' ghcr.io/rassher/mc-panel:latest 2>/dev/null || true)

# `up -d` solo recrea el contenedor si su imagen cambió; si no, no toca nada.
docker compose up -d --remove-orphans panel
if [ "$before" != "$after" ]; then
  echo "$(date -Is) panel actualizado a ${after}"
  docker image prune -f >/dev/null
fi
