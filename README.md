# Instalador del panel de servidores de Minecraft

Instala, en una Ubuntu/Debian recién puesta, todo lo necesario para el panel de servidores de Rassher:

- las dependencias (Docker, nginx, certbot…),
- el **motor** (Pelican + Wings) si no está,
- el panel (imagen privada de GitHub; el instalador pide un token con `read:packages` la primera vez),
- nginx con HTTPS para el panel y para el launcher,
- la actualización automática (cada minuto mira si hay versión nueva).

## Uso

Como `root`, en la máquina nueva y con el DNS de los dominios ya apuntando a ella:

```bash
curl -fsSL https://raw.githubusercontent.com/Rassher/mc-panel-installer/main/install.sh | bash
```

Se puede repetir: conserva `.env.production` y lo que ya está hecho.

Opcional: si antes copias tu `.env.local` a `/tmp/panel.env`, se usa en vez de preguntar cada valor.

## Qué hay aquí

| Archivo | Para qué |
|---|---|
| `install.sh` | Instalador principal |
| `deploy/install-engine.sh` | Instala Pelican + Wings sin tocar el navegador |
| `deploy/pull-images.sh` | Descarga (y mantiene al día) las imágenes de Docker de los eggs: sin ellas Wings no puede instalar servidores |
| `diagnose.sh` | Reúne el estado del motor y del panel en un texto (solo lee, sin secretos) |
| `compose.yml` | Cómo se ejecuta el panel |
| `deploy/update.sh` + `mc-panel-update.*` | Actualización automática (systemd) |

Aquí **no hay secretos ni código del panel**: solo los scripts de instalación. El código del panel está en un repositorio privado.
