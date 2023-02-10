#!/bin/bash
set -ex

DOCKER_OPTS=
POSTGIS_VERSION=

while getopts "j:z:i:v:g:o:" opt; do
    case $opt in
    j) JAR_FILE=$OPTARG ;;
    z) ZIP_FILE=$OPTARG ;;
    i) IMG_NAME=$OPTARG ;;
    v) PG_VERSION=$OPTARG ;;
    g) POSTGIS_VERSION=$OPTARG ;;
    o) DOCKER_OPTS=$OPTARG ;;
    \?) exit 1 ;;
    esac
done

if [ -z "$JAR_FILE" ] ; then
  echo "Jar file parameter is required!" && exit 1;
fi
if [ -z "$ZIP_FILE" ] ; then
  echo "Zip file parameter is required!" && exit 1;
fi
if [ -z "$PG_VERSION" ] ; then
  echo "Postgres version parameter is required!" && exit 1;
fi
if [ -z "$IMG_NAME" ] ; then
  echo "Docker image parameter is required!" && exit 1;
fi

LIB_DIR=$PWD

docker run -i --rm -v ${LIB_DIR}:/usr/local/pg-lib:ro \
-e JAR_FILE=$JAR_FILE \
-e ZIP_FILE=$ZIP_FILE \
-e PG_VERSION=$PG_VERSION \
-e POSTGIS_VERSION=$POSTGIS_VERSION \
$DOCKER_OPTS $IMG_NAME /bin/bash -ex -c 'echo "Starting testing postgres binaries" \
    && apt-get update && apt-get install -y --no-install-recommends \
        postgresql-client \
        xz-utils \
        unzip \
        \
    && groupadd --system --gid 1000 test \
    && useradd --system --gid test --uid 1000 --shell /bin/bash --create-home test \
    \
    && mkdir -p /usr/local/pg-dist \
    && unzip -q -d /usr/local/pg-dist /usr/local/pg-lib/$JAR_FILE \
    \
    && mkdir -p /usr/local/pg-test/data \
    && tar -xJf /usr/local/pg-dist/$ZIP_FILE -C /usr/local/pg-test \
    && chown test:test /usr/local/pg-test/data \
    \
    && su test -c '\''/usr/local/pg-test/bin/initdb -A trust -U postgres -D /usr/local/pg-test/data -E UTF-8'\'' \
    && su test -c '\''/usr/local/pg-test/bin/pg_ctl -w -D /usr/local/pg-test/data -o "-p 65432 -F -c timezone=UTC -c synchronous_commit=off -c max_connections=300" start'\'' \
    \
    && test $(psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c "SHOW SERVER_VERSION") = $PG_VERSION \
    && test $(psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c "CREATE EXTENSION pgcrypto; SELECT digest('\''test'\'', '\''sha256'\'');") = "\x9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" \
    && echo $(psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c '\''CREATE EXTENSION "uuid-ossp"; SELECT uuid_generate_v4();'\'') | grep -E '\''^[^-]{8}-[^-]{4}-[^-]{4}-[^-]{4}-[^-]{12}$'\'' \
    \
    && if echo "$PG_VERSION" | grep -qvE '\''^(10|9)\.'\'' ; then test $(psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c '\''SET jit_above_cost = 10; SELECT SUM(relpages) FROM pg_class;'\'') -gt 0 ; fi \
    \
    && if [ -n "$POSTGIS_VERSION" ]; then test $(psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c "CREATE EXTENSION postgis; SELECT PostGIS_Lib_Version();") = $POSTGIS_VERSION ; fi'