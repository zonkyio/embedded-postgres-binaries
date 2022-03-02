#!/bin/bash
# I haven't figured out how to do cross compiling for macos yet, so this
# script must be run on an arm machine to make arm64 binaries, and on 
# and intel machine to make the amd64 binaries.
#
# This script is not currently integrated with gradle, on account of my
# not really understanding it. Just run it direcly and it should make 
# the .zip file for manual upload to github releases.

PG_VERSION=14.1
TIMESCALE_VERSION=2.5.1

ARCH=$(uname -m)
if [ "$ARCH" == "x86_64" ]; then
    ARCH="amd64"
fi

mkdir cd darwin_build
cd darwin_build

# Postgres
curl https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2 -o postgresql-${PG_VERSION}.tar.bz2
tar -xjf postgresql-${PG_VERSION}.tar.bz2
PREFIX=$(pwd)/install
cd postgresql-${PG_VERSION}
./configure --prefix=$PREFIX
echo $PREFIX
make
make install
cd ..

# Timescale
brew install cmake
git clone https://github.com/timescale/timescaledb.git
cd timescaledb
git checkout ${TIMESCALE_VERSION}
export BUILD_FORCE_REMOVE=true
./bootstrap -D PG_CONFIG=$PREFIX/bin/pg_config -DUSE_OPENSSL=0 -DCMAKE_BUILD_TYPE=RelWithDebInfo -DREGRESS_CHECKS=OFF -DTAP_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF -DLINTER=OFF
cd build
make
make install

# Make binaries point at libraries relative to executable
find $PREFIX/bin -type f | \
  xargs -L 1 install_name_tool -change \
  $PREFIX/lib/libpq.5.dylib \
  '@executable_path/../lib/libpq.5.dylib'

# Make libraries point at libraries relative to executable
find $PREFIX/lib -type f -name "*.so"  | \
  xargs -L 1 install_name_tool -change \
  $PREFIX/lib/libpq.5.dylib \
  '@executable_path/../lib/libpq.5.dylib'

cd $PREFIX

# Tar it up
tar -cJvf ../embedded-postgres-binaries-darwin-${ARCH}-${PG_VERSION}.0.txz \
  share/* \
  lib/libpq*.dylib \
  lib/*.so \
  bin/initdb \
  bin/pg_ctl \
  bin/postgres

# # Zip the tars (who knows why)
cd ..
zip embedded-postgres-binaries-darwin-${ARCH}-${PG_VERSION}.0.zip embedded-postgres-binaries-darwin-${ARCH}-${PG_VERSION}.0.txz