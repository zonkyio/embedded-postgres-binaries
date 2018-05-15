#!/bin/bash

LITE_OPT=false

while getopts "v:i:l" opt; do
    case $opt in
    v) VERSION=$OPTARG ;;
    i) IMG_NAME=$OPTARG ;;
    l) LITE_OPT=true ;;
    \?) exit 1 ;;
    esac
done

if [ -z "$VERSION" ] ; then
  echo "Version parameter is required!" && exit 1;
fi
if [ -z "$IMG_NAME" ] ; then
  echo "Docker image parameter is required!" && exit 1;
fi
if [[ "$VERSION" == 9.* ]] && [[ "$LITE_OPT" == true ]] ; then
  echo "Lite option is supported only for PostgreSQL 10 or later!" && exit 1;
fi

ICU_ENABLED=$([[ ! "$VERSION" == 9.* ]] && [[ ! "$LITE_OPT" == true ]] && echo true || echo false);

TRG_DIR=$PWD/bundle
mkdir -p $TRG_DIR

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
		\$([ "$ICU_ENABLED" = true ] && echo '--with-icu') \
        --with-libxml \
        --with-libxslt \
        --with-perl \
        --with-python \
        --with-tcl \
        --with-tclconfig=/usr/lib/tcl8.6 \
        --with-includes=/usr/include/tcl8.6 \
        --without-readline \
	&& make -j\$(nproc) \
	&& make install \
	&& cd /usr/local/pg-build \
	&& cp /lib/*/libz.so.1 /lib/*/libuuid.so.1 /lib/*/liblzma.so.5 /usr/lib/*/libxml2.so.2 /usr/lib/*/libxslt.so.1 ./lib \
	&& if [ "$ICU_ENABLED" = true ]; then cp --no-dereference /usr/lib/*/libicudata.so* /usr/lib/*/libicuuc.so* /usr/lib/*/libicui18n.so* ./lib; fi \
	&& find ./bin -type f \( -name 'initdb' -o -name 'pg_ctl' -o -name 'postgres' \) -print0 | xargs -0 -n1 patchelf --set-rpath '\$ORIGIN/../lib' \
	&& tar -cJvf /usr/local/pg-dist/postgres-linux-debian.txz --hard-dereference \
	    share/postgresql \
        lib \
        bin/initdb \
        bin/pg_ctl \
        bin/postgres"