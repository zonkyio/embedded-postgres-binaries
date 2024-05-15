#!/bin/bash

set -e

rm -rf release
mkdir release

function do_build {
    version="$1"
    echo "=== Building ${version} ==="
    echo

    ./gradlew clean :repacked-platforms:install -Pversion="${version}.0" -PpgVersion="${version}"
    cp repacked-platforms/build/tmp/buildAmd64DarwinBundle/bundle/postgres-darwin-x86_64.txz "release/postgresql-${version}-darwin-amd64.txz"
    cp repacked-platforms/build/tmp/buildArm64v8DarwinBundle/bundle/postgres-darwin-arm_64.txz "release/postgresql-${version}-darwin-arm64.txz"

    ./gradlew clean install -Pversion="${version}.0" -PpgVersion="${version}" -ParchName=amd64
    cp custom-debian-platform/build/tmp/buildCustomDebianBundle/bundle/postgres-linux-debian.txz "release/postgresql-${version}-linux-amd64.txz"
}

function do_release {
    version="$1"
    release_name="${version}-with-tools-$(date "+%Y%m%d")"
    sums=$(echo "sha256 sums:" && cd release && sha256sum postgresql-${version}-*)
    yes | gh release delete "${release_name}" || true
    gh release create "${release_name}" --notes "${sums}" --title "" release/postgresql-${version}-*
}

for version in "14.10" "15.5" "16.1"; do
    do_build "$version"
    do_release "$version"
done
