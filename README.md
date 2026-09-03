# <img src="zonky.jpg" height="100"> Embedded Postgres Binaries

## Introduction

This project provides lightweight bundles of PostgreSQL binaries with reduced size that are intended for testing purposes.
It is a supporting project for the primary [io.zonky.test:embedded-database-spring-test](https://github.com/zonkyio/embedded-database-spring-test) and [io.zonky.test:embedded-postgres](https://github.com/zonkyio/embedded-postgres) projects.
However, with a little effort, the embedded binaries can also be integrated with other projects.

## Provided features

* Lightweight bundles of PostgreSQL binaries with reduced size (~10MB)
* Embedded PostgreSQL 11+ binaries even for Linux platform
* Configurable version of PostgreSQL binaries

## Projects using the embedded binaries

* [zonkyio/embedded-database-spring-test](https://github.com/zonkyio/embedded-database-spring-test) (Java - Spring)
* [zonkyio/embedded-postgres](https://github.com/zonkyio/embedded-postgres) (Java)
* [hgschmie/pg-embedded](https://github.com/hgschmie/pg-embedded) (Java)
* [fergusstrange/embedded-postgres](https://github.com/fergusstrange/embedded-postgres) (Go)
* [theseus-rs/postgresql-embedded](https://github.com/theseus-rs/postgresql-embedded) (Rust)
* [faokunega/pg-embed](https://github.com/faokunega/pg-embed) (Rust)
* [leinelissen/embedded-postgres](https://github.com/leinelissen/embedded-postgres) (NodeJS)

## Postgres version

The version of the postgres binaries can be managed by importing `embedded-postgres-binaries-bom` in a required version in your dependency management section.

```xml
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>io.zonky.test.postgres</groupId>
            <artifactId>embedded-postgres-binaries-bom</artifactId>
            <version>18.6.0</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>
```

A list of all available versions of postgres binaries is here: https://mvnrepository.com/artifact/io.zonky.test.postgres/embedded-postgres-binaries-bom

## Supported architectures

By default, only dependencies for `amd64` architecture, in the [io.zonky.test:embedded-database-spring-test](https://github.com/zonkyio/embedded-database-spring-test) and [io.zonky.test:embedded-postgres](https://github.com/zonkyio/embedded-postgres) projects, are included.
Support for other architectures can be enabled by adding the corresponding Maven dependencies as shown in the example below.

```xml
<dependency>
    <groupId>io.zonky.test.postgres</groupId>
    <artifactId>embedded-postgres-binaries-linux-i386</artifactId>
    <scope>test</scope>
</dependency>
```

**Supported platforms:** `Darwin`, `Windows`, `Linux`, `Alpine Linux`, `FreeBSD 13`, `FreeBSD 14`  
**Supported architectures:** `amd64`, `i386`, `arm32v6`, `arm32v7`, `arm64v8`, `ppc64le`

Note that not all architectures are supported by all platforms, you can find an exhaustive list of all available artifacts here: https://mvnrepository.com/artifact/io.zonky.test.postgres

FreeBSD runtime compatibility verified so far:

- `freebsd13` artifact on FreeBSD `13.5`
- `freebsd13` artifact on FreeBSD `14.4`
- `freebsd14` artifact on FreeBSD `14.4`
- `freebsd14` artifact on FreeBSD `15.0`

## Building from Source
The project uses a [Gradle](http://gradle.org)-based build system. In the instructions
below, [`./gradlew`](http://vimeo.com/34436402) is invoked from the root of the source tree and serves as
a cross-platform, self-contained bootstrap mechanism for the build.

### Prerequisites

[Git](http://help.github.com/set-up-git-redirect), [JDK 6 or later](http://www.oracle.com/technetwork/java/javase/downloads) and [Docker](https://www.docker.com/get-started)

Be sure that your `JAVA_HOME` environment variable points to the `jdk1.6.0` folder
extracted from the JDK download.

The Gradle wrapper used in this project is based on Gradle `6.9.3`. On modern machines it is safest to run the build with Java `8`, `11` or `17`. Java `19+` is not supported by this Gradle version.

Compiling non-native architectures rely on emulation, so it is necessary to register `qemu-*-static` executables:
   
`docker run --rm --privileged multiarch/qemu-user-static:register --reset`

**Note that the complete build of all supported architectures is now supported only on Linux platform.**

### Check out sources
`git clone git@github.com:zonkyio/embedded-postgres-binaries.git`

### Make complete build

Builds all supported artifacts for all supported platforms and architectures, and also builds a BOM to control the versions of postgres binaries.

`./gradlew clean install --parallel -Pversion=18.6.0 -PpgVersion=18.6`

Note that the complete build can take a very long time, even a few hours, depending on the performance of the machine on which the build is running.

### Make partial build

Builds only binaries for a specified platform/submodule.

`./gradlew clean :repacked-platforms:install -Pversion=18.6.0 -PpgVersion=18.6`

### Build only a single binary

Builds only a single binary for a specified platform and architecture.

`./gradlew clean install -Pversion=18.6.0 -PpgVersion=18.6 -ParchName=arm64v8 -PdistName=alpine`

For the FreeBSD 13 amd64 artifact:

`./gradlew clean :custom-freebsd-platform:install -Pversion=18.3.0 -PpgVersion=18.3 -PdistName=freebsd13`

For the FreeBSD 14 amd64 artifact:

`./gradlew clean :custom-freebsd-platform:install -Pversion=18.3.0 -PpgVersion=18.3 -PdistName=freebsd14`

These builds run a FreeBSD guest inside QEMU from a Docker container. By default:

- `freebsd13` uses the official FreeBSD `13.5-RELEASE` installer image
- `freebsd14` uses the official FreeBSD `14.4-RELEASE` installer image

Downloads are cached under `.cache/freebsd-builder`.

To override the FreeBSD installer image or cache directory:

`./gradlew clean :custom-freebsd-platform:install -Pversion=18.3.0 -PpgVersion=18.3 -PdistName=freebsd13 -PfreebsdImageUrl=https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/13.5/FreeBSD-13.5-RELEASE-amd64-disc1.iso.xz -PcacheDir=$PWD/.cache/freebsd-builder`

`./gradlew clean :custom-freebsd-platform:install -Pversion=18.3.0 -PpgVersion=18.3 -PdistName=freebsd14 -PfreebsdImageUrl=https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/14.4/FreeBSD-14.4-RELEASE-amd64-disc1.iso.xz -PcacheDir=$PWD/.cache/freebsd-builder`

The generated runtime archive is named `postgres-freebsd13-x86_64.txz` or `postgres-freebsd14-x86_64.txz`, and the resulting jar artifact is named `embedded-postgres-binaries-freebsd13-amd64-<version>.jar` or `embedded-postgres-binaries-freebsd14-amd64-<version>.jar`.

Current FreeBSD runtime assumption:

- the bundled PostgreSQL binaries and shared libraries are packaged inside the artifact
- ICU data is expected to be available using the standard FreeBSD layout under `/usr/local/share/icu`

In other words, the current FreeBSD artifact is suitable for embedded PostgreSQL on a normal FreeBSD host, but it is not yet a fully self-contained ICU runtime.

### Test the FreeBSD artifact

After creating the jar, the FreeBSD smoke test can be run with:

`./gradlew :custom-freebsd-platform:test -Pversion=18.3.0 -PpgVersion=18.3 -PdistName=freebsd13`

`./gradlew :custom-freebsd-platform:test -Pversion=18.3.0 -PpgVersion=18.3 -PdistName=freebsd14`

This smoke test boots a disposable FreeBSD guest for the requested major version and verifies:

- `initdb`
- `pg_ctl`
- `SHOW SERVER_VERSION`
- `pgcrypto`
- `uuid-ossp`

It is also possible to include the PostGIS extension by passing the `postgisVersion` parameter, e.g. `-PpostgisVersion=2.5.2`. Note that this option is not (yet) available for Windows and Mac OS platforms.

Optional parameters:
- *postgisVersion*
  - default value: unset
  - supported values: a postgis version number (only 2.5.2+, 2.4.7+, 2.3.9+ versions are supported)
- *archName*
  - default value: `amd64`
  - supported values: `amd64`, `i386`, `arm32v6`, `arm32v7`, `arm64v8`, `ppc64le`
- *distName*
  - default value: debian-like distribution
  - supported values: the default value, `alpine`, `freebsd13` or `freebsd14`
- *dockerImage*
  - default value: resolved based on the platform
  - supported values: any supported docker image
- *qemuPath*
  - default value: executables are resolved from `/usr/bin` directory or downloaded from https://github.com/multiarch/qemu-user-static/releases/download/v2.12.0
  - supported values: a path to a directory containing qemu executables

## License
The project is released under version 2.0 of the [Apache License](http://www.apache.org/licenses/LICENSE-2.0.html).
