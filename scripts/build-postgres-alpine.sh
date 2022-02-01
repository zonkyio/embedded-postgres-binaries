#!/bin/bash
set -ex

CWD=$(dirname "$0")

DOCKER_OPTS=
POSTGIS_VERSION=
LITE_OPT=false

while getopts "v:i:g:o:l" opt; do
    case $opt in
    v) PG_VERSION=$OPTARG ;;
    i) IMG_NAME=$OPTARG ;;
    g) POSTGIS_VERSION=$OPTARG ;;
    o) DOCKER_OPTS=$OPTARG ;;
    l) LITE_OPT=true ;;
    \?) exit 1 ;;
    esac
done

if [ -z "$PG_VERSION" ] ; then
  echo "Postgres version parameter is required!" && exit 1;
fi
if [ -z "$IMG_NAME" ] ; then
  echo "Docker image parameter is required!" && exit 1;
fi
if echo "$PG_VERSION" | grep -q '^9\.' && [ "$LITE_OPT" = true ] ; then
  echo "Lite option is supported only for PostgreSQL 10 or later!" && exit 1;
fi

E2FS_ENABLED=$(echo "$PG_VERSION" | grep -qv '^9\.[0-3]\.' && echo true || echo false);
ICU_ENABLED=$(echo "$PG_VERSION" | grep -qv '^9\.' && [ "$LITE_OPT" != true ] && echo true || echo false);

TRG_DIR=$PWD/bundle
mkdir -p $TRG_DIR

docker run -i --rm -v ${TRG_DIR}:/usr/local/pg-dist \
-e PG_VERSION=$PG_VERSION \
-v $CWD:/scripts \
$DOCKER_OPTS $IMG_NAME /bin/sh "/scripts/install-postgres-alpine.sh"
