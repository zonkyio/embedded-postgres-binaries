#!/bin/bash
set -ex

DOCKER_OPTS=
POSTGIS_VERSION=
LITE_OPT=false

while getopts "v:i:g:o:l" opt; do
    case $opt in
    v) PG_VERSION=$OPTARG ;;
    i) IMG_NAME=$OPTARG ;;
    g) POSTGIS_VERSION=$OPTARG ;;
    o) DOCKER_OPTS=$OPTARG ;;
    l) LITE_OPT=true ;;
    \?) exit 1 ;;
    esac
done

if [ -z "$PG_VERSION" ] ; then
  echo "Postgres version parameter is required!" && exit 1;
fi
if [ -z "$IMG_NAME" ] ; then
  echo "Docker image parameter is required!" && exit 1;
fi
if echo "$PG_VERSION" | grep -q '^9\.' && [ "$LITE_OPT" = true ] ; then
  echo "Lite option is supported only for PostgreSQL 10 or later!" && exit 1;
fi

ICU_ENABLED=$(echo "$PG_VERSION" | grep -qv '^9\.' && [ "$LITE_OPT" != true ] && echo true || echo false);

TRG_DIR=$PWD/bundle
mkdir -p $TRG_DIR

docker run -i --rm -v ${TRG_DIR}:/usr/local/pg-dist \
-e PG_VERSION=$PG_VERSION \
-e POSTGIS_VERSION=$POSTGIS_VERSION \
-e ICU_ENABLED=$ICU_ENABLED \
-e PROJ_VERSION=6.0.0 \
-e PROJ_DATUMGRID_VERSION=1.8 \
-e GEOS_VERSION=3.7.2 \
-e GDAL_VERSION=2.4.1 \
$DOCKER_OPTS $IMG_NAME /bin/bash -ex -c 'echo "Starting building postgres binaries" \
    && ln -snf /usr/share/zoneinfo/Etc/UTC /etc/localtime && echo "Etc/UTC" > /etc/timezone \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        bzip2 \
        xz-utils \
        gcc \
        g++ \
        make \
        pkg-config \
        libc-dev \
        libicu-dev \
        libossp-uuid-dev \
        libxml2-dev \
        libxslt1-dev \
        libssl-dev \
        libz-dev \
        libperl-dev \
        python3-dev \
        tcl-dev \
        \
    && wget -O patchelf.tar.gz "https://nixos.org/releases/patchelf/patchelf-0.9/patchelf-0.9.tar.gz" \
    && mkdir -p /usr/src/patchelf \
    && tar -xf patchelf.tar.gz -C /usr/src/patchelf --strip-components 1 \
    && cd /usr/src/patchelf \
    && wget -O config.guess "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" \
    && wget -O config.sub "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" \
    && ./configure --prefix=/usr/local \
    && make -j$(nproc) \
    && make install \
    \
    && wget -O postgresql.tar.bz2 "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2" \
    && mkdir -p /usr/src/postgresql \
    && tar -xf postgresql.tar.bz2 -C /usr/src/postgresql --strip-components 1 \
    && cd /usr/src/postgresql \
    && wget -O config/config.guess "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" \
    && wget -O config/config.sub "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" \
    && ./configure \
        CFLAGS="-Os -DMAP_HUGETLB=0x40000" \
        PYTHON=/usr/bin/python3 \
        --prefix=/usr/local/pg-build \
        --enable-integer-datetimes \
        --enable-thread-safety \
        --with-ossp-uuid \
        $([ "$ICU_ENABLED" = true ] && echo "--with-icu") \
        --with-libxml \
        --with-libxslt \
        --with-openssl \
        --with-perl \
        --with-python \
        --with-tcl \
        --without-readline \
    && make -j$(nproc) world \
    && make install-world \
    && make -C contrib install \
    \
    && if [ -n "$POSTGIS_VERSION" ]; then \
      apt-get install -y --no-install-recommends curl libjson-c-dev libsqlite3-0 libsqlite3-dev sqlite3 unzip protobuf-c-compiler libprotobuf-dev libprotobuf-c-dev \
      && mkdir -p /usr/src/proj \
        && curl -sL "https://download.osgeo.org/proj/proj-$PROJ_VERSION.tar.gz" | tar -xzf - -C /usr/src/proj --strip-components 1 \
        && cd /usr/src/proj \
        && curl -sL "https://download.osgeo.org/proj/proj-datumgrid-$PROJ_DATUMGRID_VERSION.zip" > proj-datumgrid.zip \
        && unzip -o proj-datumgrid.zip -d data\
        && curl -sL "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" > config.guess \
        && curl -sL "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" > config.sub \
        && ./configure --disable-static --prefix=/usr/local/pg-build \
        && make -j$(nproc) \
        && make install \
      && mkdir -p /usr/src/geos \
        && curl -sL "https://download.osgeo.org/geos/geos-$GEOS_VERSION.tar.bz2" | tar -xjf - -C /usr/src/geos --strip-components 1 \
        && cd /usr/src/geos \
        && curl -sL "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" > config.guess \
        && curl -sL "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" > config.sub \
        && ./configure --disable-static --prefix=/usr/local/pg-build \
        && make -j$(nproc) \
        && make install \
      && mkdir -p /usr/src/gdal \
        && curl -sL "https://download.osgeo.org/gdal/$GDAL_VERSION/gdal-$GDAL_VERSION.tar.xz" | tar -xJf - -C /usr/src/gdal --strip-components 1 \
        && cd /usr/src/gdal \
        && curl -sL "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" > config.guess \
        && curl -sL "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" > config.sub \
        && ./configure --disable-static --prefix=/usr/local/pg-build \
        && make -j$(nproc) \
        && make install \
      && mkdir -p /usr/src/postgis \
        && curl -sL "https://postgis.net/stuff/postgis-$POSTGIS_VERSION.tar.gz" | tar -xzf - -C /usr/src/postgis --strip-components 1 \
        && cd /usr/src/postgis \
        && curl -sL "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" > config.guess \
        && curl -sL "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=b8ee5f79949d1d40e8820a774d813660e1be52d3" > config.sub \
        && ./configure \
            --prefix=/usr/local/pg-build \
            --with-pgconfig=/usr/local/pg-build/bin/pg_config \
            --with-geosconfig=/usr/local/pg-build/bin/geos-config \
            --with-projdir=/usr/local/pg-build \
            --with-gdalconfig=/usr/local/pg-build/bin/gdal-config \
        && make -j$(nproc) \
        && make install \
    ; fi \
    \
    && cd /usr/local/pg-build \
    && cp /usr/lib/libossp-uuid.so.16 ./lib || cp /usr/lib/*/libossp-uuid.so.16 ./lib \
    && cp /lib/*/libz.so.1 /lib/*/liblzma.so.5 /usr/lib/*/libxml2.so.2 /usr/lib/*/libxslt.so.1 ./lib \
    && cp /lib/*/libssl.so.1* /lib/*/libcrypto.so.1* ./lib || cp /usr/lib/*/libssl.so.1* /usr/lib/*/libcrypto.so.1* ./lib \
    && if [ "$ICU_ENABLED" = true ]; then cp --no-dereference /usr/lib/*/libicudata.so* /usr/lib/*/libicuuc.so* /usr/lib/*/libicui18n.so* ./lib; fi \
    && if [ -n "$POSTGIS_VERSION" ]; then cp --no-dereference /lib/*/libjson-c.so* /usr/lib/*/libsqlite3.so* ./lib ; fi \
    && find ./bin -type f \( -name "initdb" -o -name "pg_ctl" -o -name "postgres" \) -print0 | xargs -0 -n1 patchelf --set-rpath "\$ORIGIN/../lib" \
    && find ./lib -maxdepth 1 -type f -name "*.so*" -print0 | xargs -0 -n1 patchelf --set-rpath "\$ORIGIN" \
    && find ./lib/postgresql -maxdepth 1 -type f -name "*.so*" -print0 | xargs -0 -n1 patchelf --set-rpath "\$ORIGIN/.." \
    && tar -cJvf /usr/local/pg-dist/postgres-linux-debian.txz --hard-dereference \
        share/postgresql \
        lib \
        bin/initdb \
        bin/pg_ctl \
        bin/postgres'
