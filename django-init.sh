#!/bin/bash
set -e

PG_VERSION=15
PGDATA="/var/lib/postgresql/${PG_VERSION}/main"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

export POSTGRES_DB="${POSTGRES_DB:-escriptorium}"
export POSTGRES_USER="${POSTGRES_USER:-escriptorium}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-escriptorium}"

# The data directory is usually bind-mounted from the host. On a fresh
# install that mount starts out empty, so initialize a new PG 15 cluster
# there the first time. Existing installs (e.g. upgraded from an older
# version of this image) already have data here and are left untouched.
mkdir -p "$PGDATA"
chown -R postgres:postgres "$(dirname "$PGDATA")"
chmod 0700 "$PGDATA"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "No existing PostgreSQL data directory found, initializing a new one at $PGDATA..."
    su postgres -c "$PG_BIN/initdb -D $PGDATA --auth=trust --auth-host=md5"
fi

echo "Waiting for PostgreSQL to accept connections..."
for i in $(seq 1 60); do
    su postgres -c "$PG_BIN/pg_isready -h localhost -p 5432" >/dev/null 2>&1 && break
    sleep 1
done

su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'\"" | grep -q 1 || \
    su postgres -c "psql -c \"CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';\""

su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'\"" | grep -q 1 || \
    su postgres -c "psql -c \"CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};\""

su escriptorium -p -c "cd /home/escriptorium/escriptorium/app/ && python manage.py migrate --noinput && python manage.py collectstatic --noinput"

