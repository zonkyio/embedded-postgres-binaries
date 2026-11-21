#!/bin/bash
set -ex

while getopts "j:z:v:" opt; do
    case $opt in
    j) JAR_FILE=$OPTARG ;;
    z) ZIP_FILE=$OPTARG ;;
    v) PG_VERSION=$OPTARG ;;
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

LIB_DIR=$PWD
TRG_DIR=$(mktemp -d)

mkdir -p $TRG_DIR/pg-dist
unzip -q -d $TRG_DIR/pg-dist $LIB_DIR/$JAR_FILE

mkdir -p $TRG_DIR/pg-test/data
tar -xJf $TRG_DIR/pg-dist/$ZIP_FILE -C $TRG_DIR/pg-test

$TRG_DIR/pg-test/bin/initdb -A trust -U postgres -D $TRG_DIR/pg-test/data -E UTF-8
$TRG_DIR/pg-test/bin/pg_ctl -w -D $TRG_DIR/pg-test/data -o '-p 65432 -F -c timezone=UTC -c synchronous_commit=off -c max_connections=300' start

# Shutdown DB server and do cleanup on exit
function cleanup() {
  local errcode=$?
  $TRG_DIR/pg-test/bin/pg_ctl -w -D $TRG_DIR/pg-test/data stop
  rm -rf $TRG_DIR
  return $errcode
}

trap cleanup EXIT

test $($TRG_DIR/pg-test/bin/psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c "SHOW SERVER_VERSION") = $PG_VERSION
test $($TRG_DIR/pg-test/bin/psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c "CREATE EXTENSION pgcrypto; SELECT digest('test', 'sha256');") = "\x9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
echo $($TRG_DIR/pg-test/bin/psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c 'CREATE EXTENSION "uuid-ossp"; SELECT uuid_generate_v4();') | grep -E '^[^-]{8}-[^-]{4}-[^-]{4}-[^-]{4}-[^-]{12}$'

$TRG_DIR/pg-test/bin/psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c "CREATE TABLE dump_test AS SELECT generate_series(1, 100) AS id;"
$TRG_DIR/pg-test/bin/pg_dump -Fc -h localhost -p 65432 -U postgres -d postgres -t dump_test -f $TRG_DIR/dump_test.dump
$TRG_DIR/pg-test/bin/psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c "CREATE DATABASE restore_test;"
$TRG_DIR/pg-test/bin/pg_restore -h localhost -p 65432 -U postgres -d restore_test $TRG_DIR/dump_test.dump
test $($TRG_DIR/pg-test/bin/psql -qAtX -h localhost -p 65432 -U postgres -d restore_test -c "SELECT COUNT(*) FROM dump_test;") = 100

if echo "$PG_VERSION" | grep -qvE '^(10|9)\.' ; then
  count=$($TRG_DIR/pg-test/bin/psql -qAtX -h localhost -p 65432 -U postgres -d postgres -c 'SET jit_above_cost = 10; SELECT SUM(relpages) FROM pg_class;')
  test $count -gt 0
fi
