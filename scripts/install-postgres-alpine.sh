echo "Starting building postgres binaries"
apk add --no-cache \
        bison \
        coreutils \
        ca-certificates \
        flex \
        wget \
        tar \
        xz \
        gcc \
        make \
        libc-dev \
        icu-dev \
        linux-headers \
        util-linux-dev \
        libxml2-dev \
        libxslt-dev \
        openssl-dev \
        openssl-dev \
        zlib-dev \
        perl-utils \
        perl-ipc-run \
        python3-dev \
        perl-dev \
        tcl-dev \
        chrpath \
        bash \
        cmake \
        dpkg-dev \
        dpkg \
        tzdata

wget -O uuid.tar.gz "https://www.mirrorservice.org/sites/ftp.ossp.org/pkg/lib/uuid/uuid-1.6.2.tar.gz"
mkdir -p /usr/src/ossp-uuid
tar -xf uuid.tar.gz -C /usr/src/ossp-uuid --strip-components 1
cd /usr/src/ossp-uuid
wget -O config.guess "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD"
wget -O config.sub "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD"
./configure --prefix=/usr/local
make -j$(nproc)
make install
cp --no-dereference /usr/local/lib/libuuid.* /lib;

cd /
wget -O postgresql.tar.bz2 "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2"
mkdir -p /usr/src/postgresql
tar -xf postgresql.tar.bz2 -C /usr/src/postgresql --strip-components 1
cd /usr/src/postgresql
wget -O config/config.guess "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD"
wget -O config/config.sub "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD"

gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)";

./configure \
    CFLAGS="-Os" \
    PYTHON=/usr/bin/python3 \
    --build="$gnuArch" \
    --prefix=/usr/local/pg-build \
    --enable-integer-datetimes \
    --enable-thread-safety \
    --with-gnu-ld \
    --with-includes=/usr/local/include \
    --with-libraries=/usr/local/lib \
    --with-icu \
    --with-libxml \
    --with-libxslt \
    --with-openssl \
    --with-perl \
    --with-python \
    --with-tcl \
    --without-readline \
    --with-system-tzdata=/usr/share/zoneinfo

make -j$(nproc) world
make install-world
make -C contrib install

export PATH=/usr/local/pg-build/bin:$PATH
cd /
wget https://github.com/timescale/timescaledb/archive/refs/tags/2.6.0.tar.gz
tar -xzf 2.6.0.tar.gz
cd timescaledb-2.6.0
./bootstrap
cd ./build
make
make install

cd /usr/local/pg-build
cp /lib/libuuid.so.1 /lib/libz.so.1 /lib/libssl.so.1.1 /lib/libcrypto.so.1.1 /usr/lib/libxml2.so.2 /usr/lib/libxslt.so.1 ./lib
cp --no-dereference /usr/lib/libicudata.so* /usr/lib/libicuuc.so* /usr/lib/libicui18n.so* /usr/lib/libstdc++.so* /usr/lib/libgcc_s.so* ./lib
find ./bin -type f \( -name "initdb" -o -name "pg_ctl" -o -name "postgres" \) -print0 | xargs -0 -n1 chrpath -r "\$ORIGIN/../lib"
tar -cJvf /usr/local/pg-dist/postgres-linux-alpine_linux.txz --hard-dereference \
        share/postgresql \
        lib \
        bin/initdb \
        bin/pg_ctl \
        bin/postgres
