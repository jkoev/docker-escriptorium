# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: build the eScriptorium front-end bundle.
# The front-end is still built with webpack 4 and only builds reliably with
# Node 12, matching upstream's own build image (see their top-level Dockerfile
# at gitlab.com/scripta/escriptorium).
# ---------------------------------------------------------------------------
FROM node:12-alpine AS frontend

ARG ESCRIPTORIUM_VERSION=v26.07

RUN apk add --no-cache git
RUN git clone --depth 1 --branch ${ESCRIPTORIUM_VERSION} \
      https://gitlab.com/scripta/escriptorium.git /src

WORKDIR /src/front
RUN npm ci && npm run production

# ---------------------------------------------------------------------------
# Stage 2: runtime image.
# All services (postgres, redis, nginx, uwsgi, daphne, celery, flower) run in
# this single container via supervisord, matching the original all-in-one
# layout of usegalaxy-eu/docker-escriptorium so it keeps working as a single
# container in Unraid's native Docker manager (no compose).
# ---------------------------------------------------------------------------
FROM python:3.11-slim

ARG ESCRIPTORIUM_VERSION=v26.07
# POSTGRES_PASSWORD and SECRET_KEY are intentionally NOT set here (do not bake
# secrets into image layers) - they fall back to Django's own weak defaults
# (settings.py) and django-init.sh's default of "escriptorium" if not
# supplied via `docker run -e` / the Unraid template, but should always be
# overridden for a real deployment.
ENV ESCRIPTORIUM_VERSION=${ESCRIPTORIUM_VERSION} \
    DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    POSTGRES_DB=escriptorium \
    POSTGRES_USER=escriptorium \
    DOMAIN=localhost \
    CSRF_TRUSTED_ORIGINS=http://localhost:8080 \
    KRAKEN_TRAINING_DEVICE=cpu \
    KRAKEN_INFERENCE_DEVICE=cpu \
    CELERY_MAIN_CONC=10 \
    CELERY_LIVE_CONC=10 \
    CELERY_LOW_CONC=10

# System dependencies + PostgreSQL 15 from the PGDG apt repo.
# Debian's own "postgresql" meta-package now resolves to v17 on this base
# image, which is NOT data-directory compatible with existing v15 volumes
# bind-mounted from older deployments of this project, so pg15 is pinned
# explicitly via upstream PGDG instead of the distro default.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential libpq-dev libxml2-dev libxslt-dev zlib1g-dev \
      libffi-dev libssl-dev git curl wget ca-certificates gnupg \
      libleptonica-dev libvips nano default-jre-headless default-jdk-headless ant \
      gettext netcat-traditional jpegoptim pngcrush \
      redis-server nginx supervisor && \
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    . /etc/os-release && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends postgresql-15 postgresql-contrib-15 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Non-privileged users
RUN addgroup --system uwsgi && \
    adduser --system --no-create-home --ingroup uwsgi uwsgi && \
    useradd -ms /bin/bash escriptorium

WORKDIR /home/escriptorium
RUN git clone --depth 1 --branch ${ESCRIPTORIUM_VERSION} \
      https://gitlab.com/scripta/escriptorium.git

COPY --from=frontend /src/front/dist /home/escriptorium/escriptorium/front/dist

# requirements.txt pulls in the default (CUDA-enabled) PyTorch wheel, which
# bundles the full nvidia-*/cuDNN stack (several GB) even if KRAKEN_*_DEVICE
# is set to cpu (see README's GPU compatibility note - GPUs with compute
# capability < 7.5, e.g. Pascal, can't use it anyway). For a CPU-only
# deployment you can shrink the image by installing torch from
# https://download.pytorch.org/whl/cpu instead before the requirements.txt
# install, but that permanently rules out using a GPU without rebuilding.
RUN pip install --upgrade pip --no-cache-dir && \
    pip install --no-cache-dir -r /home/escriptorium/escriptorium/app/requirements.txt && \
    pip install --no-cache-dir flower psycopg2-binary && \
    chown -R escriptorium:escriptorium /home/escriptorium/escriptorium

# Add supervisord config
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY django-init.sh /django-init.sh
COPY nginx.conf /etc/nginx/sites-available/default
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /django-init.sh && \
    # useradd's default home dir mode (0700) blocks nginx (runs as www-data)
    # from traversing into /home/escriptorium to serve static/media files
    chmod 755 /home/escriptorium

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# nginx (web UI) and flower (celery task monitoring)
EXPOSE 80 5555

# Default command
CMD ["docker-entrypoint.sh"]

