#!/bin/bash -ex

VERSION=$1
ARCH_NAME=$2

if [ -z "$VERSION" ] ; then
  echo "Version parameter is required!" && exit 1;
fi
if [ -z "$ARCH_NAME" ] ; then
  echo "Architecture name is required!" && exit 1;
fi

cd `dirname $0`

TRG_DIR=$PWD/build/resources/main
PKG_DIR=$PWD/build/tmp/postgres/package/alpine/pgsql

mkdir -p $TRG_DIR
rm -rf $PKG_DIR && mkdir -p $PKG_DIR

docker run -i --rm -v ${PKG_DIR}:/usr/local/pg-build -v ${TRG_DIR}:/usr/local/pg-dist alpine:3.7 /bin/sh -c "echo 'Starting compilation' \
    && apk add --no-cache \
		coreutils \
		tar \
		xz \
		gcc \
		make \
		libc-dev \
		util-linux-dev \
		libxml2-dev \
		libxslt-dev \
		zlib-dev \
		chrpath \
	&& wget -O postgresql.tar.bz2 'https://ftp.postgresql.org/pub/source/v$VERSION/postgresql-$VERSION.tar.bz2' \
	&& mkdir -p /usr/src/postgresql \
	&& tar -xf postgresql.tar.bz2 -C /usr/src/postgresql --strip-components 1 \
	&& cd /usr/src/postgresql \
	&& ./configure \
	    CFLAGS='-O2' \
		--prefix=/usr/local/pg-build \
		--enable-integer-datetimes \
		--enable-thread-safety \
		--with-uuid=e2fs \
		--with-gnu-ld \
		--with-includes=/usr/local/include \
		--with-libraries=/usr/local/lib \
		--with-libxml \
		--with-libxslt \
		--without-readline \
	&& make -j 8 \
	&& make install \
	&& cp /lib/libuuid.so.1 /lib/libz.so.1 /usr/local/pg-build/lib \
	&& cp /usr/lib/libxml2.so.2.* /usr/local/pg-build/lib/libxml2.so.2 \
	&& cp /usr/lib/libxslt.so.1.* /usr/local/pg-build/lib/libxslt.so.1 \
	&& chrpath -r '\$ORIGIN/../lib' /usr/local/pg-build/bin/* \
	&& cd /usr/local/pg-build \
	&& tar -cJvf /usr/local/pg-dist/postgres-linux-$ARCH_NAME-alpine_linux.txz --hard-dereference \
	    share/postgresql \
        lib \
        bin/initdb \
        bin/pg_ctl \
        bin/postgres"