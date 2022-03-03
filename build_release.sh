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


for version in "13.6" "14.2"; do
    do_build "$version"
done
