.PHONY: darwin
darwin:
	./gradlew clean install -Pversion=14.1.0 -PpgVersion=14.1 -PdistName=darwin -ParchName=amd64

alpine:
	./gradlew clean install -Pversion=14.1.0 -PpgVersion=14.1 -PdistName=alpine -ParchName=amd64

debian:
	./gradlew clean install -Pversion=14.1.0 -PpgVersion=14.1 -ParchName=amd64