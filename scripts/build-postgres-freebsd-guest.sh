#!/bin/sh
set -eu

if [ -z "${PG_VERSION:-}" ]; then
    echo "PG_VERSION environment variable is required!" >&2
    exit 1
fi
if [ -n "${POSTGIS_VERSION:-}" ]; then
    echo "PostGIS is not supported yet for the FreeBSD builder!" >&2
    exit 1
fi

PATH="/usr/local/bin:/usr/local/sbin:${PATH}"
DIST_DIR="${DIST_DIR:-/tmp/pg-dist}"
BUILD_ROOT="$(mktemp -d /tmp/postgresql-freebsd-build.XXXXXX)"
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
ICU_ENABLED=false
PG_SOURCE_FILE="${PG_SOURCE_FILE:-}"
FREEBSD_VERSION="$(freebsd-version -u 2>/dev/null || freebsd-version)"
FREEBSD_MAJOR="$(printf "%s" "$FREEBSD_VERSION" | sed "s/\..*//")"
ARCH_NAME="$(uname -m)"
CONFIGURE_LDFLAGS="-L/usr/local/lib -Wl,-z,origin"

case "$ARCH_NAME" in
    amd64) NORM_ARCH_NAME="x86_64" ;;
    aarch64) NORM_ARCH_NAME="arm_64" ;;
    i386) NORM_ARCH_NAME="x86_32" ;;
    *) NORM_ARCH_NAME="$ARCH_NAME" ;;
esac

cleanup() {
    rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT INT TERM

copy_runtime_file() {
    source_path="$1"
    target_dir="$2"
    target_path="$target_dir/$(basename "$source_path")"
    resolved_path=
    resolved_target_path=

    if [ -e "$target_path" ] || [ -L "$target_path" ]; then
        :
    elif [ -L "$source_path" ]; then
        cp -pP "$source_path" "$target_path"
    else
        cp -p "$source_path" "$target_path"
    fi

    if resolved_path=$(realpath "$source_path" 2>/dev/null); then
        resolved_target_path="$target_dir/$(basename "$resolved_path")"
        if [ "$resolved_path" != "$source_path" ] && [ ! -e "$resolved_target_path" ] && [ ! -L "$resolved_target_path" ]; then
            cp -p "$resolved_path" "$resolved_target_path"
        fi
    fi
}

should_bundle_system_lib() {
    dep_path="$1"

    case "$dep_path" in
        /usr/lib/libssl.so.*|/lib/libcrypto.so.*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

case "$PG_VERSION" in
    9.*) ICU_ENABLED=false ;;
    *) ICU_ENABLED=true ;;
esac

mkdir -p "$DIST_DIR"
env ASSUME_ALWAYS_YES=yes pkg bootstrap
env ASSUME_ALWAYS_YES=yes pkg update
env ASSUME_ALWAYS_YES=yes pkg install \
    ca_root_nss \
    curl \
    gmake \
    icu \
    libxml2 \
    libxslt \
    perl5 \
    pkgconf \
    python3 \
    tcl86 \
    bison \
    flex \
    patchelf

if [ -n "$PG_SOURCE_FILE" ] && [ -f "$PG_SOURCE_FILE" ]; then
    cp "$PG_SOURCE_FILE" "$BUILD_ROOT/postgresql.tar.bz2"
else
    fetch -o "$BUILD_ROOT/postgresql.tar.bz2" "https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2"
fi
mkdir -p "$BUILD_ROOT/postgresql"
tar -xjf "$BUILD_ROOT/postgresql.tar.bz2" -C "$BUILD_ROOT/postgresql" --strip-components 1

cd "$BUILD_ROOT/postgresql"
env CPPFLAGS="-I/usr/local/include" LDFLAGS="$CONFIGURE_LDFLAGS" \
    ./configure \
        CFLAGS="-Os" \
        PYTHON=/usr/local/bin/python3 \
        --prefix=/usr/local/pg-build \
        --enable-integer-datetimes \
        --enable-thread-safety \
        --with-uuid=bsd \
        --with-includes=/usr/local/include \
        --with-libraries=/usr/local/lib \
        $( [ "$ICU_ENABLED" = true ] && echo "--with-icu" ) \
        --with-libxml \
        --with-libxslt \
        --with-openssl \
        --with-perl \
        --with-python \
        --with-tcl \
        --without-readline

# Make the default FreeBSD rpath point at our packaged lib directory.
perl -0pi -e 's/^rpathdir = \$\(libdir\)$/rpathdir = \$\$ORIGIN\/..\/lib/m' src/Makefile.global

# Shared modules live in lib/postgresql, so they need a different relative rpath.
find contrib src/pl -type f \( -name Makefile -o -name GNUmakefile \) | while IFS= read -r makefile_path; do
    if grep -Eq '^(MODULES|MODULE_big)[[:space:]]*=' "$makefile_path" &&
       ! grep -Eq '^(PROGRAM|PROGRAMS)[[:space:]]*=' "$makefile_path"; then
        printf '\n# Embedded Postgres FreeBSD packaging uses a bundle-relative rpath.\nrpathdir = $$ORIGIN/..\n' >> "$makefile_path"
    fi
done

gmake -j"$NCPU" world-bin
gmake install-world-bin
gmake -C contrib install

STAGE_PREFIX="postgres-freebsd${FREEBSD_MAJOR}"
RUNTIME_ROOT="$BUILD_ROOT/runtime"
RUNTIME_LIB_DIR="$RUNTIME_ROOT/lib"
RUNTIME_PLUGIN_DIR="$RUNTIME_LIB_DIR/postgresql"
RUNTIME_BIN_DIR="$RUNTIME_ROOT/bin"
RUNTIME_SHARE_DIR="$RUNTIME_ROOT/share"
SEEN_DEPS="$BUILD_ROOT/seen-deps.txt"

set -x

mkdir -p "$RUNTIME_PLUGIN_DIR" "$RUNTIME_BIN_DIR" "$RUNTIME_SHARE_DIR"
cp -Rp /usr/local/pg-build/share/postgresql "$RUNTIME_SHARE_DIR/"
if [ "$ICU_ENABLED" = true ] && [ -d /usr/local/share/icu ]; then
    cp -Rp /usr/local/share/icu "$RUNTIME_SHARE_DIR/"
fi
cp -p /usr/local/pg-build/bin/initdb /usr/local/pg-build/bin/pg_ctl /usr/local/pg-build/bin/postgres "$RUNTIME_BIN_DIR/"
cp -Rp /usr/local/pg-build/lib/postgresql "$RUNTIME_LIB_DIR/"
for libpq_file in /usr/local/pg-build/lib/libpq.so*; do
    copy_runtime_file "$libpq_file" "$RUNTIME_LIB_DIR"
done

collect_deps() {
    object_path="$1"

    [ -e "$object_path" ] || return
    if [ -f "$SEEN_DEPS" ] && grep -Fxq "$object_path" "$SEEN_DEPS"; then
        return
    fi
    printf "%s\n" "$object_path" >> "$SEEN_DEPS"

    deps_file="$BUILD_ROOT/ldd.$(basename "$object_path").txt"
    ldd "$object_path" 2>/dev/null | awk '
        /^[^[:space:]]+:$/ { next }
        {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^\//) {
                    gsub(/:$/, "", $i)
                    print $i
                }
            }
        }
    ' > "$deps_file"

    while IFS= read -r dep_path; do
        case "$dep_path" in
            /usr/local/pg-build/*)
                collect_deps "$dep_path"
                ;;
            /usr/local/*)
                copy_runtime_file "$dep_path" "$RUNTIME_LIB_DIR"
                collect_deps "$dep_path"
                ;;
            *)
                if should_bundle_system_lib "$dep_path"; then
                    copy_runtime_file "$dep_path" "$RUNTIME_LIB_DIR"
                    collect_deps "$dep_path"
                fi
                ;;
        esac
    done < "$deps_file"
}

collect_deps /usr/local/pg-build/bin/initdb
collect_deps /usr/local/pg-build/bin/pg_ctl
collect_deps /usr/local/pg-build/bin/postgres

find /usr/local/pg-build/lib/postgresql -maxdepth 1 -type f -name "*.so" | while IFS= read -r module_path; do
    collect_deps "$module_path"
done

find "$RUNTIME_BIN_DIR" -type f \( -name "initdb" -o -name "pg_ctl" -o -name "postgres" \) -print0 | \
    xargs -0 -n1 patchelf --set-rpath '$ORIGIN/../lib'
find "$RUNTIME_LIB_DIR" -maxdepth 1 -type f -name "*.so*" -print0 | \
    xargs -0 -n1 patchelf --set-rpath '$ORIGIN'
find "$RUNTIME_PLUGIN_DIR" -maxdepth 1 -type f -name "*.so*" -print0 | \
    xargs -0 -n1 patchelf --set-rpath '$ORIGIN/..'

find /usr/local/pg-build -type f | sort > "$DIST_DIR/${STAGE_PREFIX}-build-manifest.txt"
find "$RUNTIME_ROOT" -type f | sort > "$DIST_DIR/${STAGE_PREFIX}-runtime-manifest.txt"
pkg info > "$DIST_DIR/${STAGE_PREFIX}-pkg-info.txt"
{
    echo "# ldd: bin/initdb"
    ldd /usr/local/pg-build/bin/initdb || true
    echo
    echo "# ldd: bin/pg_ctl"
    ldd /usr/local/pg-build/bin/pg_ctl || true
    echo
    echo "# ldd: bin/postgres"
    ldd /usr/local/pg-build/bin/postgres || true
    echo
    echo "# elfdump: bin/initdb"
    elfdump -d /usr/local/pg-build/bin/initdb || true
    echo
    echo "# elfdump: bin/pg_ctl"
    elfdump -d /usr/local/pg-build/bin/pg_ctl || true
    echo
    echo "# elfdump: bin/postgres"
    elfdump -d /usr/local/pg-build/bin/postgres || true
    echo
    echo "# elfdump: runtime/bin/initdb"
    elfdump -d "$RUNTIME_BIN_DIR/initdb" || true
    echo
    echo "# elfdump: runtime/bin/pg_ctl"
    elfdump -d "$RUNTIME_BIN_DIR/pg_ctl" || true
    echo
    echo "# elfdump: runtime/bin/postgres"
    elfdump -d "$RUNTIME_BIN_DIR/postgres" || true
    echo
    echo "# elfdump: runtime/lib/libicui18n.so.76"
    elfdump -d "$RUNTIME_LIB_DIR/libicui18n.so.76" || true
    echo
    echo "# elfdump: runtime/lib/libicudata.so.76"
    elfdump -d "$RUNTIME_LIB_DIR/libicudata.so.76" || true
} > "$DIST_DIR/${STAGE_PREFIX}-ldd.txt"

tar -C /usr/local -cJf "$DIST_DIR/${STAGE_PREFIX}-build.txz" pg-build
tar -C "$RUNTIME_ROOT" -cJf "$DIST_DIR/${STAGE_PREFIX}-${NORM_ARCH_NAME}.txz" \
    share/postgresql \
    $( [ -d "$RUNTIME_SHARE_DIR/icu" ] && echo share/icu ) \
    lib \
    bin/initdb \
    bin/pg_ctl \
    bin/postgres

echo "Generated FreeBSD build artifacts:"
find "$DIST_DIR" -maxdepth 1 -type f | sort
