#!/bin/bash
set -ex

ARCH_NAME=amd64

while getopts "v:p:a:" opt; do
    case $opt in
    v) PG_VERSION=$OPTARG ;;
    p) PLATFORM_NAME=$OPTARG ;;
    a) ARCH_NAME=$OPTARG ;;
    \?) exit 1 ;;
    esac
done

if [ -z "$PG_VERSION" ] ; then
  echo "Postgres version parameter is required!" && exit 1;
fi
if [ "$PLATFORM_NAME" != "darwin" ] && [ "$PLATFORM_NAME" != "windows" ] && [ "$PLATFORM_NAME" != "linux" ] ; then
  echo "Platform $PLATFORM_NAME is not supported!" && exit 1;
fi
if [ "$ARCH_NAME" != "amd64" ] && [ "$ARCH_NAME" != "i386" ] && [ "$ARCH_NAME" != "arm64v8" ] ; then
  echo "Architecture $ARCH_NAME is not supported!" && exit 1;
fi
if [ "$PLATFORM_NAME" = "darwin" ] && [ "$ARCH_NAME" = "i386" ] ; then
  echo "Darwin platform supports only amd64 or arm64v8 architecture!" && exit 1;
fi


FILE_NAME="postgresql-$PG_VERSION"

if [ "$PLATFORM_NAME" = "darwin" ] ; then
  FILE_NAME="$FILE_NAME-osx"
else
  FILE_NAME="$FILE_NAME-$PLATFORM_NAME"
fi

if [ "$ARCH_NAME" = "amd64" ] && [ "$PLATFORM_NAME" != "darwin" ] ; then
  FILE_NAME="$FILE_NAME-x64-binaries"
else
  FILE_NAME="$FILE_NAME-binaries"
fi

if [ "$PLATFORM_NAME" = "linux" ] ; then
  FILE_NAME="$FILE_NAME.tar.gz"
else
  FILE_NAME="$FILE_NAME.zip"
fi

if [ "$ARCH_NAME" = "amd64" ] ; then
  NORM_ARCH_NAME="x86_64"
elif [ "$ARCH_NAME" = "arm64v8" ] ; then
  NORM_ARCH_NAME="arm_64"
else
  NORM_ARCH_NAME="x86_32"
fi


DIST_DIR=$PWD/dist
PKG_DIR=$PWD/package
TRG_DIR=$PWD/bundle
DIST_FILE=$DIST_DIR/$FILE_NAME


mkdir -p $DIST_DIR $TRG_DIR

[ -e $DIST_FILE ] || wget -O $DIST_FILE "https://get.enterprisedb.com/postgresql/$FILE_NAME"

rm -rf $PKG_DIR && mkdir -p $PKG_DIR

if [ "$PLATFORM_NAME" = "linux" ] ; then
  tar -xzf $DIST_FILE -C $PKG_DIR
else
  unzip -q -d $PKG_DIR $DIST_FILE
fi

cd $PKG_DIR/pgsql


if [ "$PLATFORM_NAME" = "darwin" ] ; then

  if [ "$PG_VERSION" = "13.5-1" ] || [ "$PG_VERSION" = "13.6-1" ] || [ "$PG_VERSION" = "13.7-1" ] || [ "$PG_VERSION" = "13.8-1" ] || [ "$PG_VERSION" = "13.9-1" ] ; then
    mkdir -p ./opt/local/lib
    cp $PKG_DIR/../../../../../libs/libncursesw.6.dylib ./lib/
    ln -s ../../../lib/libncursesw.6.dylib ./opt/local/lib/libncurses.6.dylib
  fi

  tar -cJvf $TRG_DIR/postgres-darwin-$NORM_ARCH_NAME.txz \
    share/postgresql \
    $([ -f lib/libiconv.2.dylib ] && echo lib/libiconv.2.dylib || echo ) \
    $([ -f lib/libicudata.dylib ] && echo lib/libicudata*.dylib lib/libicui18n*.dylib lib/libicuuc*.dylib || echo ) \
    $([ -f lib/libncursesw.6.dylib ] && echo lib/libncurses*.dylib || echo ) \
    $([ -f lib/liblz4.dylib ] && echo lib/liblz*.dylib || echo ) \
    $([ -f lib/libgssapi_krb5.dylib ] && echo lib/libgssapi_krb5.*.*.dylib || echo ) \
    $([ -f lib/libkrb5.dylib ] && echo lib/libkrb5.*.*.dylib || echo ) \
    $([ -f lib/libkrb5support.dylib ] && echo lib/libkrb5support.*.*.dylib || echo ) \
    $([ -f lib/libk5crypto.dylib ] && echo lib/libk5crypto.*.*.dylib || echo ) \
    $([ -f lib/libcom_err.dylib ] && echo lib/libcom_err.*.*.dylib || echo ) \
    $([ -f lib/libintl.dylib ] && echo lib/libintl.*.dylib || echo ) \
    $([ -f opt/local/lib/libncurses.6.dylib ] && echo opt || echo ) \
    lib/libz*.dylib \
    lib/libpq*.dylib \
    lib/libuuid*.dylib \
    lib/libxml2*.dylib \
    lib/libssl*.dylib \
    lib/libcrypto*.dylib \
    lib/libedit*.dylib \
    lib/postgresql/*.* \
    bin/initdb \
    bin/pg_ctl \
    bin/postgres

elif [ "$PLATFORM_NAME" = "windows" ] ; then

  tar -cJvf $TRG_DIR/postgres-windows-$NORM_ARCH_NAME.txz \
    share \
    lib/iconv.lib \
    lib/libxml2.lib \
    $([ -f lib/ssleay32.lib ] && echo lib/ssleay32.lib lib/ssleay32MD.lib || echo lib/libssl.lib lib/libcrypto.lib) \
    lib/*.dll \
    bin/initdb.exe \
    bin/pg_ctl.exe \
    bin/postgres.exe \
    bin/*.dll

elif [ "$PLATFORM_NAME" = "linux" ] ; then

  tar -cJvf $TRG_DIR/postgres-linux-$NORM_ARCH_NAME.txz \
    share/postgresql \
    lib \
    bin/initdb \
    bin/pg_ctl \
    bin/postgres

fi