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
mkdir -p $TRG_DIR

echo "Resolved docker image '$IMG_NAME'"
docker run -i --rm -v ${TRG_DIR}:/usr/local/pg-dist $IMG_NAME /bin/bash -c "echo 'Starting compilation' \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        lbzip2 \
        xz-utils \
        gcc \
        make \
        pkg-config \
        libc-dev \
        libicu-dev \
        libossp-uuid-dev \
        libxml2-dev \
        libxslt1-dev \
        libz-dev \
        libperl-dev \
        python3-dev \
        tcl8.6-dev \
        patchelf \
	&& wget -O postgresql.tar.bz2 'https://ftp.postgresql.org/pub/source/v$VERSION/postgresql-$VERSION.tar.bz2' \
	&& mkdir -p /usr/src/postgresql \
	&& tar -xf postgresql.tar.bz2 -C /usr/src/postgresql --strip-components 1 \
	&& cd /usr/src/postgresql \
	&& ./configure \
        CFLAGS='-O2 -DMAP_HUGETLB=0x40000' \
        PYTHON=/usr/bin/python3 \
        --prefix=/usr/local/pg-build \
        --enable-debug \
        --enable-integer-datetimes \
        --enable-thread-safety \
        --with-ossp-uuid \
		--with-icu \
        --with-libxml \
        --with-libxslt \
        --with-perl \
        --with-python \
        --with-tcl \
        --with-tclconfig=/usr/lib/x86_64-linux-gnu/tcl8.6 \
        --with-includes=/usr/include/tcl8.6 \
        --without-readline \
	&& make -j\$(nproc) \
	&& make install \
	&& cd /usr/local/pg-build \
	&& cp /lib/*/libz.so.1 /lib/*/libuuid.so.1 /lib/*/liblzma.so.5 /usr/lib/*/libxml2.so.2 /usr/lib/*/libxslt.so.1 ./lib \
	&& cp --no-dereference /usr/lib/*/libicudata.so* /usr/lib/*/libicuuc.so* /usr/lib/*/libicui18n.so* ./lib \
	&& find ./bin -type f -print0 | xargs -0 -n1 patchelf --set-rpath '\$ORIGIN/../lib' \
	&& tar -cJvf /usr/local/pg-dist/postgres-linux-$ARCH_NAME-ubuntu.txz --hard-dereference \
	    share/postgresql \
        lib \
        bin/initdb \
        bin/pg_ctl \
        bin/postgres"