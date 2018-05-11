#!/bin/bash -ex

VERSION=$1
ARCH_NAME=$2
IMG_NAME=$3

if [ -z "$VERSION" ] ; then
  echo "Version parameter is required!" && exit 1;
fi
if [ -z "$ARCH_NAME" ] ; then
  echo "Architecture name is required!" && exit 1;
fi
if [ -z "$IMG_NAME" ] ; then
  if [[ "$ARCH_NAME" =~ ^(x86_64|amd64)$ ]] && [[ "$(uname -m)" =~ ^(x86_64|amd64)$ ]] ; then
    IMG_NAME="ubuntu:16.04"
  else
    case "$(uname -s)" in
      Darwin)
        IMG_NAME="$ARCH_NAME/ubuntu:16.04"
        ;;
      Linux)
        case $ARCH_NAME in
          'arm32v6') ARCH_NAME="armel";;
          'arm32v7') ARCH_NAME="armhf";;
          'arm64v8') ARCH_NAME="arm64";;
          'ppc64le') ARCH_NAME="ppc64el";;
        esac
        IMG_NAME="multiarch/ubuntu-core:$ARCH_NAME-xenial"
        ;;
      *)
        echo "Unsupported architecture!" && exit 1;
        ;;
    esac
  fi
fi

cd `dirname $0`

TRG_DIR=$PWD/build/resources/main
PKG_DIR=$PWD/build/tmp/postgres/package/ubuntu/pgsql

mkdir -p $TRG_DIR
rm -rf $PKG_DIR && mkdir -p $PKG_DIR
echo "Resolved docker image '$IMG_NAME'"

docker run -i --rm -v ${PKG_DIR}:/usr/local/pg-build -v ${TRG_DIR}:/usr/local/pg-dist $IMG_NAME /bin/bash -c "echo 'Starting compilation' \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        lbzip2 \
        xz-utils \
        gcc \
        make \
        libc-dev \
        uuid-dev \
        libxml2-dev \
        libxslt-dev \
        zlib1g-dev \
	&& wget -O postgresql.tar.bz2 'https://ftp.postgresql.org/pub/source/v$VERSION/postgresql-$VERSION.tar.bz2' \
	&& mkdir -p /usr/src/postgresql \
	&& tar -xf postgresql.tar.bz2 -C /usr/src/postgresql --strip-components 1 \
	&& cd /usr/src/postgresql \
	&& ./configure \
	    CFLAGS='-O2' \
		--prefix=/usr/local/pg-build \
		--disable-rpath \
		--enable-integer-datetimes \
		--enable-thread-safety \
		--with-uuid=e2fs \
		--with-gnu-ld \
		--with-includes=/usr/local/include \
		--with-libraries=/usr/local/lib \
		--with-libxml \
		--with-libxslt \
		--without-readline \
	&& export LD_RUN_PATH='\$ORIGIN/../lib' \
	&& make -j 8 \
	&& make install \
	&& cp /lib/*/libuuid.so.1.* /usr/local/pg-build/lib/libuuid.so.1 \
	&& cp /lib/*/libz.so.1.* /usr/local/pg-build/lib/libz.so.1 \
	&& cp /usr/lib/*/libxml2.so.2.* /usr/local/pg-build/lib/libxml2.so.2 \
	&& cp /usr/lib/*/libxslt.so.1.* /usr/local/pg-build/lib/libxslt.so.1 \
	&& cp /usr/lib/*/libicudata.so.* /usr/lib/*/libicuuc.so.* /usr/local/pg-build/lib \
	&& cd /usr/local/pg-build \
	&& tar -cJvf /usr/local/pg-dist/postgres-linux-$ARCH_NAME-ubuntu.txz --hard-dereference \
	    share/postgresql \
        lib \
        bin/initdb \
        bin/pg_ctl \
        bin/postgres"