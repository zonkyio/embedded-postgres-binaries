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

docker run -i --rm -v ${TRG_DIR}:/usr/local/pg-dist $IMG_NAME /bin/sh -c "echo 'Starting compilation' \
    && apk add --no-cache \
		coreutils \
        wget \
		tar \
		xz \
		gcc \
		make \
		libc-dev \
		icu-dev \
		util-linux-dev \
		libxml2-dev \
		libxslt-dev \
		zlib-dev \
		perl-dev \
        python3-dev \
        tcl-dev \
		patchelf \
	&& wget -O postgresql.tar.bz2 'https://ftp.postgresql.org/pub/source/v$VERSION/postgresql-$VERSION.tar.bz2' \
	&& mkdir -p /usr/src/postgresql \
	&& tar -xf postgresql.tar.bz2 -C /usr/src/postgresql --strip-components 1 \
	&& cd /usr/src/postgresql \
	&& ./configure \
	    CFLAGS='-O2' \
	    PYTHON=/usr/bin/python3 \
		--prefix=/usr/local/pg-build \
		--enable-integer-datetimes \
		--enable-thread-safety \
		--with-uuid=e2fs \
		--with-gnu-ld \
		--with-includes=/usr/local/include \
		--with-libraries=/usr/local/lib \
		\$([ "$ICU_ENABLED" = true ] && echo '--with-icu') \
		--with-libxml \
		--with-libxslt \
		--with-perl \
        --with-python \
        --with-tcl \
		--without-readline \
	&& make -j\$(nproc) \
	&& make install \
	&& cd /usr/local/pg-build \
	&& cp /lib/libuuid.so.1 /lib/libz.so.1 /usr/lib/libxml2.so.2 /usr/lib/libxslt.so.1 ./lib \
	&& if [ "$ICU_ENABLED" = true ]; then cp --no-dereference /usr/lib/libicudata.so* /usr/lib/libicuuc.so* /usr/lib/libicui18n.so* ./lib; fi \
	&& find ./bin -type f \( -name 'initdb' -o -name 'pg_ctl' -o -name 'postgres' \) -print0 | xargs -0 -n1 patchelf --set-rpath '\$ORIGIN/../lib' \
	&& tar -cJvf /usr/local/pg-dist/postgres-linux-alpine_linux.txz --hard-dereference \
	    share/postgresql \
        lib \
        bin/initdb \
        bin/pg_ctl \
        bin/postgres"