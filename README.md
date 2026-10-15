# docker-escriptorium

A single-container Docker image for [eScriptorium](https://gitlab.com/scripta/escriptorium)
(HTR/OCR platform built on [kraken](https://kraken.re)), maintained as a fork of
the abandoned [usegalaxy-eu/docker-escriptorium](https://github.com/usegalaxy-eu/docker-escriptorium).

Unlike upstream eScriptorium's own [docker-compose.yml](https://gitlab.com/scripta/escriptorium/-/blob/main/docker-compose.yml)
(which splits postgres/redis/nginx/web/celery/etc. into separate containers),
this image runs every service in **one container** via `supervisord`, so it
can be managed entirely from Unraid's (or any other) native Docker UI with a
plain `docker run` — no docker-compose plugin required.

## What's in this fork

| Component | Old (usegalaxy-eu) | This fork |
|---|---|---|
| eScriptorium | `v0.13.8b-hotfixes5` (2024) | `v26.07` (configurable via `ESCRIPTORIUM_VERSION` build arg) |
| kraken | unpinned `pip install kraken` (whatever's latest at build time) | pinned by eScriptorium's own `requirements.txt` (`kraken~=7.1.0`, `dfine-kraken~=0.4.3`) |
| PostgreSQL | distro default (was 15, silently drifts with base image updates) | pinned to **15** explicitly via the PGDG apt repo, to stay compatible with existing data volumes |
| Base image | `python:3.11-slim` | `python:3.11-slim` (unchanged) |
| Celery queues | `default`, `cpu`, `train`, `kraken` (no longer exist) | `default`, `live`, `low-priority`, `gpu`, `intensive-inference`, `jvm` (current eScriptorium queue names) |

Elasticsearch-based search and the mail relay are left disabled by default
(matching upstream's own defaults) to keep this a single, simple container.

## Running it (plain `docker run`, no compose)

```sh
docker run -d --name escriptorium \
  -p 8080:80 -p 5555:5555 \
  --shm-size=3g \
  -e POSTGRES_DB=escriptorium \
  -e POSTGRES_USER=escriptorium \
  -e POSTGRES_PASSWORD=change-me \
  -e SECRET_KEY=$(openssl rand -hex 32) \
  -e DOMAIN=your.server.ip.or.hostname \
  -e CSRF_TRUSTED_ORIGINS=http://your.server.ip.or.hostname:8080 \
  -e KRAKEN_TRAINING_DEVICE=cuda:0 \
  -e KRAKEN_INFERENCE_DEVICE=cuda:0 \
  --gpus all \
  -v /path/to/appdata/escriptorium/media:/home/escriptorium/escriptorium/app/media \
  -v /path/to/appdata/escriptorium/db:/var/lib/postgresql/15/main \
  ghcr.io/jkoev/docker-escriptorium:latest
```

Drop `--gpus all` / `-e KRAKEN_*_DEVICE` if you don't have an NVIDIA GPU
passed through (they default to `cpu`).

## Unraid

Use the native Docker tab — no Community Applications/compose plugin needed:

1. Copy [`unraid-template/escriptorium.xml`](unraid-template/escriptorium.xml)
   to `/boot/config/plugins/dockerMan/templates-user/` on the flash drive.
2. Docker tab → **Add Container** → pick the `escriptorium` template from the
   dropdown, review the fields (paths, passwords, GPU device), **Apply**.

The template keeps the same volume layout as the original image
(`.../appdata/escriptorium/media` and `.../appdata/escriptorium/db`), so an
existing install's data is picked up automatically — see the upgrade notes
below.

## Upgrading an existing install from the old image

This jumps from eScriptorium `v0.13.8` to `v26.07` (roughly two years of
migrations) in one step. Django chains migrations automatically via
`manage.py migrate`, which runs at container start, but:

1. **Back up the database first.** `docker exec <container> su postgres -c "pg_dump escriptorium" > backup.sql`
   (or just copy the `appdata/escriptorium/db` folder while the old container
   is stopped).
2. Stop and remove the old container (keep the `media`/`db` host folders).
3. Build/pull this image and start it pointing at the **same** `media`/`db`
   paths. PostgreSQL major version stays 15, so no `pg_upgrade` is needed —
   only Django's own migrations run.
4. Watch the logs (`docker logs -f escriptorium`, or the `django-init`
   program's log at `/var/log/escriptorium.log` inside the container) until
   migrations finish before relying on the UI.

## Building

```sh
docker build -t docker-escriptorium:local \
  --build-arg ESCRIPTORIUM_VERSION=v26.07 .
```

Bump `ESCRIPTORIUM_VERSION` to track newer upstream releases/tags from
<https://gitlab.com/scripta/escriptorium/-/tags>.

## Ports / volumes

| | Container path | Purpose |
|---|---|---|
| Port | `80` | nginx (web UI), map to e.g. host `8080` |
| Port | `5555` | Flower (celery task monitoring) |
| Volume | `/home/escriptorium/escriptorium/app/media` | uploaded documents/images |
| Volume | `/var/lib/postgresql/15/main` | PostgreSQL 15 data directory |

## License

MIT, see [LICENSE](LICENSE). Originally created by usegalaxy.eu.