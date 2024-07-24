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
            <version>16.0.0</version>
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

**Supported platforms:** `Darwin`, `Windows`, `Linux`, `Alpine Linux`  
**Supported architectures:** `amd64`, `i386`, `arm32v6`, `arm32v7`, `arm64v8`, `ppc64le`

Note that not all architectures are supported by all platforms, you can find an exhaustive list of all available artifacts here: https://mvnrepository.com/artifact/io.zonky.test.postgres

## Building from Source
The project uses a [Gradle](http://gradle.org)-based build system. In the instructions
below, [`./gradlew`](http://vimeo.com/34436402) is invoked from the root of the source tree and serves as
a cross-platform, self-contained bootstrap mechanism for the build.

### Prerequisites

[Git](http://help.github.com/set-up-git-redirect), [JDK 6 or later](http://www.oracle.com/technetwork/java/javase/downloads) and [Docker](https://www.docker.com/get-started)

Be sure that your `JAVA_HOME` environment variable points to the `jdk1.6.0` folder
extracted from the JDK download.

Compiling non-native architectures rely on emulation, so it is necessary to register `qemu-*-static` executables:
   
`docker run --rm --privileged multiarch/qemu-user-static:register --reset`

**Note that the complete build of all supported architectures is now supported only on Linux platform.**

### Check out sources
`git clone git@github.com:zonkyio/embedded-postgres-binaries.git`

### Make complete build

Builds all supported artifacts for all supported platforms and architectures, and also builds a BOM to control the versions of postgres binaries.

`./gradlew clean install --parallel -Pversion=10.6.0 -PpgVersion=10.6`

Note that the complete build can take a very long time, even a few hours, depending on the performance of the machine on which the build is running.

### Make partial build

Builds only binaries for a specified platform/submodule.

`./gradlew clean :repacked-platforms:install -Pversion=10.6.0 -PpgVersion=10.6`

### Build only a single binary

Builds only a single binary for a specified platform and architecture.

`./gradlew clean install -Pversion=10.6.0 -PpgVersion=10.6 -ParchName=arm64v8 -PdistName=alpine`

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
  - supported values: the default value or `alpine`
- *dockerImage*
  - default value: resolved based on the platform
  - supported values: any supported docker image
- *qemuPath*
  - default value: executables are resolved from `/usr/bin` directory or downloaded from https://github.com/multiarch/qemu-user-static/releases/download/v2.12.0
  - supported values: a path to a directory containing qemu executables

## License
The project is released under version 2.0 of the [Apache License](http://www.apache.org/licenses/LICENSE-2.0.html).
