#!/bin/sh
set -eu

if [ -z "${JAR_FILE:-}" ]; then
    echo "JAR_FILE environment variable is required!" >&2
    exit 1
fi
if [ -z "${ZIP_FILE:-}" ]; then
    echo "ZIP_FILE environment variable is required!" >&2
    exit 1
fi
if [ -z "${PG_VERSION:-}" ]; then
    echo "PG_VERSION environment variable is required!" >&2
    exit 1
fi

TEST_ROOT="$(mktemp -d /var/tmp/postgresql-freebsd-test.XXXXXX)"
TEST_USER="pgtest"
PG_MAJOR="$(printf "%s" "$PG_VERSION" | sed 's/\..*//')"
PG_ENV=

cleanup() {
    set +e
    if [ -x "$TEST_ROOT/pg-test/bin/pg_ctl" ] && [ -d "$TEST_ROOT/pg-test/data" ]; then
        su -m "$TEST_USER" -c "$TEST_ROOT/pg-test/bin/pg_ctl -w -D $TEST_ROOT/pg-test/data stop" >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

env ASSUME_ALWAYS_YES=yes pkg bootstrap
env ASSUME_ALWAYS_YES=yes pkg update
env ASSUME_ALWAYS_YES=yes pkg install \
    unzip \
    "postgresql${PG_MAJOR}-client"

mkdir -p "$TEST_ROOT/pg-dist"
unzip -q -d "$TEST_ROOT/pg-dist" "$JAR_FILE"
mkdir -p "$TEST_ROOT/pg-test/data"
tar -xJf "$TEST_ROOT/pg-dist/$ZIP_FILE" -C "$TEST_ROOT/pg-test"
chmod 755 "$TEST_ROOT/pg-test/bin/initdb" "$TEST_ROOT/pg-test/bin/pg_ctl" "$TEST_ROOT/pg-test/bin/postgres"
ICU_DATA_DIR=
ICU_DATA_PATH=
if [ -d "$TEST_ROOT/pg-test/share/icu" ]; then
    mkdir -p /usr/local/share
    rm -rf /usr/local/share/icu
    cp -Rp "$TEST_ROOT/pg-test/share/icu" /usr/local/share/
    ICU_DATA_DIR="$(find "$TEST_ROOT/pg-test/share/icu" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)"
fi
if [ -n "$ICU_DATA_DIR" ]; then
    ICU_DATA_PATH="$(find "$ICU_DATA_DIR" -maxdepth 1 -type f -name 'icudt*.dat' | sort | head -n 1)"
fi
PG_ENV="env"

echo "FreeBSD ICU debug:" >&2
echo "  ICU_DATA_DIR=${ICU_DATA_DIR:-<unset>}" >&2
echo "  ICU_DATA_PATH=${ICU_DATA_PATH:-<unset>}" >&2
echo "  PG_ENV=$PG_ENV" >&2
if [ -d "$TEST_ROOT/pg-test/share/icu" ]; then
    find "$TEST_ROOT/pg-test/share/icu" -maxdepth 2 \( -type d -o -type f \) | sort >&2
fi
if [ -d /usr/local/share/icu ]; then
    find /usr/local/share/icu -maxdepth 2 \( -type d -o -type f \) | sort >&2
fi

pw groupshow "$TEST_USER" >/dev/null 2>&1 || pw useradd "$TEST_USER" -m -s /bin/sh
chown -R "$TEST_USER:$TEST_USER" "$TEST_ROOT"

su -m "$TEST_USER" -c "$PG_ENV $TEST_ROOT/pg-test/bin/initdb -A trust -U postgres -D $TEST_ROOT/pg-test/data -E UTF-8"
su -m "$TEST_USER" -c "$PG_ENV $TEST_ROOT/pg-test/bin/pg_ctl -w -D $TEST_ROOT/pg-test/data -o \"-p 65432 -F -c timezone=UTC -c synchronous_commit=off -c max_connections=300\" start"

test "$(psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c "SHOW SERVER_VERSION")" = "$PG_VERSION"
test "$(psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c "CREATE EXTENSION pgcrypto; SELECT digest('test', 'sha256');")" = "\x9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
echo "$(psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c 'CREATE EXTENSION "uuid-ossp"; SELECT uuid_generate_v4();')" | grep -E '^[^-]{8}-[^-]{4}-[^-]{4}-[^-]{4}-[^-]{12}$'

if echo "$PG_VERSION" | grep -qvE '^(10|9)\.' ; then
    count="$(psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c 'SET jit_above_cost = 10; SELECT SUM(relpages) FROM pg_class;')"
    test "$count" -gt 0
fi
