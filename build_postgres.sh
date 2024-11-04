#!/bin/bash
set -ex

ARCH_NAME=amd64
POSTGIS_VERSION=
PGROUTING_VERSION=
PLATFORM_NAME=

while getopts "v:p:a:g:r:" opt; do
    case $opt in
    v) PG_VERSION=$OPTARG ;;
    p) PLATFORM_NAME=$OPTARG ;;
    a) ARCH_NAME=$OPTARG ;;
    g) POSTGIS_VERSION=$OPTARG ;;
    r) PGROUTING_VERSION=$OPTARG ;;
    \?) exit 1 ;;
    esac
done

if [ -z "$PG_VERSION" ]; then
  echo "Postgres version parameter is required!" && exit 1;
fi
if [ "$PLATFORM_NAME" != "darwin" ] && [ "$PLATFORM_NAME" != "windows" ] && [ "$PLATFORM_NAME" != "linux" ]; then
  echo "Platform $PLATFORM_NAME is not supported!" && exit 1;
fi
if [ "$ARCH_NAME" != "amd64" ] && [ "$ARCH_NAME" != "i386" ] && [ "$ARCH_NAME" != "arm64v8" ]; then
  echo "Architecture $ARCH_NAME is not supported!" && exit 1;
fi
if [ "$PLATFORM_NAME" = "darwin" ] && [ "$ARCH_NAME" = "i386" ]; then
  echo "Darwin platform supports only amd64 or arm64v8 architecture!" && exit 1;
fi

# Define filenames and directories
FILE_NAME="postgresql-$PG_VERSION-1"
if [ "$PLATFORM_NAME" = "darwin" ]; then
  FILE_NAME="$FILE_NAME-osx"
else
  FILE_NAME="$FILE_NAME-$PLATFORM_NAME"
fi

if [ "$ARCH_NAME" = "amd64" ] && [ "$PLATFORM_NAME" != "darwin" ]; then
  FILE_NAME="$FILE_NAME-x64-binaries"
else
  FILE_NAME="$FILE_NAME-binaries"
fi

if [ "$PLATFORM_NAME" = "linux" ]; then
  FILE_NAME="$FILE_NAME.tar.gz"
else
  FILE_NAME="$FILE_NAME.zip"
fi

DIST_DIR=$PWD/dist
PKG_DIR=$PWD/package
TRG_DIR=$PWD/bundle
DIST_FILE=$DIST_DIR/$FILE_NAME
POSTGRES_DIR=$PKG_DIR/pgsql

mkdir -p $DIST_DIR $TRG_DIR

[ -e $DIST_FILE ] || wget -O $DIST_FILE "https://get.enterprisedb.com/postgresql/$FILE_NAME"

rm -rf $PKG_DIR && mkdir -p $PKG_DIR

if [ "$PLATFORM_NAME" = "linux" ]; then
  tar -xzf $DIST_FILE -C $PKG_DIR
else
  unzip -q -d $PKG_DIR $DIST_FILE
fi

# Set up environment paths for PostGIS and pgRouting build
export PATH="$POSTGRES_DIR/bin:$PATH"
export PG_CONFIG="$POSTGRES_DIR/bin/pg_config"
export LD_LIBRARY_PATH="$POSTGRES_DIR/lib:$LD_LIBRARY_PATH"

# Install required dependencies for building PostGIS and pgRouting
brew update
brew install pkg-config proj geos gdal

# Compile and install PostGIS if a version is specified
if [ -n "$POSTGIS_VERSION" ]; then
    wget -O postgis.tar.gz "https://download.osgeo.org/postgis/source/postgis-$POSTGIS_VERSION.tar.gz"
    mkdir -p $PKG_DIR/postgis
    tar -xf postgis.tar.gz -C $PKG_DIR/postgis --strip-components 1
    cd $PKG_DIR/postgis
    ./configure \
        --with-pgconfig="$PG_CONFIG" \
        --with-geosconfig=$(brew --prefix geos)/bin/geos-config \
        --with-projdir=$(brew --prefix proj) \
        --with-gdalconfig=$(brew --prefix gdal)/bin/gdal-config
    make -j$(sysctl -n hw.ncpu)
    make install
fi

# Compile and install pgRouting if a version is specified
if [ -n "$PGROUTING_VERSION" ]; then
    wget -O pgrouting.tar.gz "https://github.com/pgRouting/pgrouting/archive/v$PGROUTING_VERSION.tar.gz"
    mkdir -p $PKG_DIR/pgrouting
    tar -xf pgrouting.tar.gz -C $PKG_DIR/pgrouting --strip-components 1
    cd $PKG_DIR/pgrouting
    mkdir build
    cd build
    cmake -DWITH_DOC=OFF -DCMAKE_INSTALL_PREFIX="$POSTGRES_DIR" -DPOSTGRESQL_PGCONFIG="$PG_CONFIG" ..
    make -j$(sysctl -n hw.ncpu)
    make install
fi

# Bundle the PostgreSQL directory with PostGIS and pgRouting extensions
if [ "$PLATFORM_NAME" = "darwin" ]; then
  tar -cJvf $TRG_DIR/postgres-darwin-$ARCH_NAME.txz -C $POSTGRES_DIR .
elif [ "$PLATFORM_NAME" = "linux" ]; then
  tar -cJvf $TRG_DIR/postgres-linux-$ARCH_NAME.txz -C $POSTGRES_DIR .
elif [ "$PLATFORM_NAME" = "windows" ]; then
  zip -r $TRG_DIR/postgres-windows-$ARCH_NAME.zip $POSTGRES_DIR/*
fi
