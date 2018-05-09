#!/bin/bash -ex

VERSION=$1

if [ -z "$VERSION" ] ; then
  echo "Version parameter is required!" && exit 1;
fi

cd `dirname $0`

DIST_DIR=$PWD/build/tmp/postgres/dist
PKG_DIR=$PWD/build/tmp/postgres/package
TRG_DIR=$PWD/build/resources/main

LINUX_DIST=$DIST_DIR/postgresql-$VERSION-linux-x64-binaries.tar.gz
OSX_DIST=$DIST_DIR/postgresql-$VERSION-osx-binaries.zip
WINDOWS_DIST=$DIST_DIR/postgresql-$VERSION-win-binaries.zip

mkdir -p $DIST_DIR $TRG_DIR

[ -e $LINUX_DIST ] || wget -O $LINUX_DIST "http://get.enterprisedb.com/postgresql/postgresql-$VERSION-linux-x64-binaries.tar.gz"
[ -e $OSX_DIST ] || wget -O $OSX_DIST "http://get.enterprisedb.com/postgresql/postgresql-$VERSION-osx-binaries.zip"
[ -e $WINDOWS_DIST ] || wget -O $WINDOWS_DIST "http://get.enterprisedb.com/postgresql/postgresql-$VERSION-windows-x64-binaries.zip"

rm -rf $PKG_DIR/linux && mkdir -p $PKG_DIR/linux
tar -xzf $LINUX_DIST -C $PKG_DIR/linux
cd $PKG_DIR/linux/pgsql
tar -cJvf $TRG_DIR/postgres-linux-x86_64.txz \
  share/postgresql \
  lib \
  bin/initdb \
  bin/pg_ctl \
  bin/postgres

rm -rf $PKG_DIR/darwin && mkdir -p $PKG_DIR/darwin
unzip -q -d $PKG_DIR/darwin $OSX_DIST
cd $PKG_DIR/darwin/pgsql
tar -cJvf $TRG_DIR/postgres-darwin-x86_64.txz \
  share/postgresql \
  $(ls lib/libicudata.57.dylib lib/libicui18n.57.dylib lib/libicuuc.57.dylib lib/libiconv.2.dylib) \
  $(ls lib/libuuid.1.1.dylib lib/libuuid.16.dylib) \
  lib/libxml2.2.dylib \
  lib/libssl.1.0.0.dylib \
  lib/libcrypto.1.0.0.dylib \
  lib/postgresql/*.so \
  bin/initdb \
  bin/pg_ctl \
  bin/postgres

rm -rf $PKG_DIR/windows && mkdir -p $PKG_DIR/windows
unzip -q -d $PKG_DIR/windows $WINDOWS_DIST
cd $PKG_DIR/windows/pgsql
tar -cJvf $TRG_DIR/postgres-windows-x86_64.txz \
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