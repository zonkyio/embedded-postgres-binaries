#!/bin/bash -ex

VERSION=$1

cd `dirname $0`

DIST_DIR=$PWD/build/tmp/postgres/dist
PKG_DIR=$PWD/build/tmp/postgres/package
TRG_DIR=$PWD/build/resources/main

[ -e $TRG_DIR/.repacked ] && echo "Already repacked, skipping..." && exit 0

LINUX_DIST=$DIST_DIR/postgresql-$VERSION-linux-x64-binaries.tar.gz
OSX_DIST=$DIST_DIR/postgresql-$VERSION-osx-binaries.zip
WINDOWS_DIST=$DIST_DIR/postgresql-$VERSION-win-binaries.zip

rm -rf $PKG_DIR
mkdir -p $DIST_DIR $PKG_DIR $TRG_DIR

[ -e $LINUX_DIST ] || wget -O $LINUX_DIST "http://get.enterprisedb.com/postgresql/postgresql-$VERSION-linux-x64-binaries.tar.gz"
[ -e $OSX_DIST ] || wget -O $OSX_DIST "http://get.enterprisedb.com/postgresql/postgresql-$VERSION-osx-binaries.zip"
[ -e $WINDOWS_DIST ] || wget -O $WINDOWS_DIST "http://get.enterprisedb.com/postgresql/postgresql-$VERSION-windows-x64-binaries.zip"

tar xzf $LINUX_DIST -C $PKG_DIR
pushd $PKG_DIR/pgsql
tar cJf $TRG_DIR/postgres-linux-x86_64.txz \
  share/postgresql \
  lib \
  bin/initdb \
  bin/pg_ctl \
  bin/postgres
popd
rm -rf $PKG_DIR && mkdir -p $PKG_DIR

unzip -q -d $PKG_DIR $OSX_DIST
pushd $PKG_DIR/pgsql
tar cJf $TRG_DIR/postgres-darwin-x86_64.txz \
  share/postgresql \
  lib/libicudata.57.dylib \
  lib/libicui18n.57.dylib \
  lib/libicuuc.57.dylib \
  lib/libxml2.2.dylib \
  lib/libssl.1.0.0.dylib \
  lib/libcrypto.1.0.0.dylib \
  lib/libuuid.1.1.dylib \
  lib/postgresql/*.so \
  bin/initdb \
  bin/pg_ctl \
  bin/postgres
popd
rm -rf $PKG_DIR && mkdir -p $PKG_DIR

unzip -q -d $PKG_DIR $WINDOWS_DIST
pushd $PKG_DIR/pgsql
tar cJf $TRG_DIR/postgres-windows-x86_64.txz \
  share \
  lib/iconv.lib \
  lib/libxml2.lib \
  lib/ssleay32.lib \
  lib/ssleay32MD.lib \
  lib/*.dll \
  bin/initdb.exe \
  bin/pg_ctl.exe \
  bin/postgres.exe \
  bin/*.dll
popd
rm -rf $PKG_DIR

touch $TRG_DIR/.repacked