#!/bin/bash
set -euo pipefail

DOCKER_OPTS=
VM_IMAGE_URL=
VM_MEMORY_MB=4096
VM_CPUS=4
VM_DISK_SIZE=12G
SSH_PORT=2222
SERIAL_PORT=4444
CACHE_DIR=

while getopts "j:z:i:v:o:u:m:c:p:s:k:r:" opt; do
    case $opt in
    j) JAR_FILE=$OPTARG ;;
    z) ZIP_FILE=$OPTARG ;;
    i) IMG_NAME=$OPTARG ;;
    v) PG_VERSION=$OPTARG ;;
    o) DOCKER_OPTS=$OPTARG ;;
    u) VM_IMAGE_URL=$OPTARG ;;
    m) VM_MEMORY_MB=$OPTARG ;;
    c) VM_CPUS=$OPTARG ;;
    p) SSH_PORT=$OPTARG ;;
    s) VM_DISK_SIZE=$OPTARG ;;
    k) CACHE_DIR=$OPTARG ;;
    r) SERIAL_PORT=$OPTARG ;;
    \?) exit 1 ;;
    esac
done

if [ -z "${JAR_FILE:-}" ] ; then
  echo "Jar file parameter is required!" && exit 1;
fi
if [ -z "${ZIP_FILE:-}" ] ; then
  echo "Zip file parameter is required!" && exit 1;
fi
if [ -z "${PG_VERSION:-}" ] ; then
  echo "Postgres version parameter is required!" && exit 1;
fi
if [ -z "${IMG_NAME:-}" ] ; then
  echo "Docker image parameter is required!" && exit 1;
fi
if [ -z "${VM_IMAGE_URL:-}" ] ; then
  echo "FreeBSD VM image URL parameter is required!" && exit 1;
fi

PROVISION_MODE=
if echo "$VM_IMAGE_URL" | grep -q 'BASIC-CLOUDINIT'; then
  PROVISION_MODE=cloudinit
elif echo "$VM_IMAGE_URL" | grep -Eq 'disc1\.iso(\.xz)?$'; then
  PROVISION_MODE=installer
else
  echo "FreeBSD VM image URL must point to either a BASIC-CLOUDINIT image or a release disc1.iso installer image." && exit 1;
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB_DIR=$PWD
CACHE_DIR=${CACHE_DIR:-$PWD/.cache/freebsd-builder}
mkdir -p "$CACHE_DIR"

if [ ! -f "$LIB_DIR/$JAR_FILE" ] ; then
  if [ ! -f "$JAR_FILE" ] ; then
    echo "Jar file not found: $JAR_FILE" && exit 1;
  fi
  JAR_HOST_PATH="$JAR_FILE"
else
  JAR_HOST_PATH="$LIB_DIR/$JAR_FILE"
fi

JAR_HOST_DIR=$(cd "$(dirname "$JAR_HOST_PATH")" && pwd)
JAR_HOST_BASENAME=$(basename "$JAR_HOST_PATH")
JAR_GUEST_NAME=$(basename "$JAR_FILE")

docker run -i --rm \
    -v "${LIB_DIR}:/usr/local/pg-lib:ro" \
    -v "${JAR_HOST_DIR}:/usr/local/pg-jar-src:ro" \
    -v "${CACHE_DIR}:/usr/local/pg-cache" \
    -v "${SCRIPT_DIR}:/usr/local/pg-scripts:ro" \
    -e IMG_NAME="$IMG_NAME" \
    -e JAR_FILE="$JAR_FILE" \
    -e JAR_HOST_BASENAME="$JAR_HOST_BASENAME" \
    -e JAR_GUEST_NAME="$JAR_GUEST_NAME" \
    -e ZIP_FILE="$ZIP_FILE" \
    -e PG_VERSION="$PG_VERSION" \
    -e PROVISION_MODE="$PROVISION_MODE" \
    -e VM_IMAGE_URL="$VM_IMAGE_URL" \
    -e VM_MEMORY_MB="$VM_MEMORY_MB" \
    -e VM_CPUS="$VM_CPUS" \
    -e VM_DISK_SIZE="$VM_DISK_SIZE" \
    -e SSH_PORT="$SSH_PORT" \
    -e SERIAL_PORT="$SERIAL_PORT" \
    $DOCKER_OPTS "$IMG_NAME" /bin/bash -eu -c '
        log() {
            echo "[freebsd-test] $*"
        }

        wait_for_ssh() {
            local user=$1
            local max_attempts=$2

            log "Waiting for SSH from FreeBSD guest as ${user}"
            for attempt in $(seq 1 "$max_attempts"); do
                if ssh $SSH_OPTS "${user}@127.0.0.1" true >/dev/null 2>&1; then
                    log "SSH is reachable as ${user}"
                    return 0
                fi
                if [ $((attempt % 6)) -eq 0 ]; then
                    log "SSH not ready yet after $((attempt * 5))s"
                    tail -n 20 "$WORK_DIR/serial.log" || true
                fi
                sleep 5
            done

            echo "FreeBSD guest did not become reachable over SSH as ${user}" >&2
            tail -n 200 "$WORK_DIR/serial.log" >&2 || true
            exit 1
        }

        run_guest_test() {
            local user=$1
            local runner=$2

            log "Copying bundle and guest test helper"
            scp $SCP_OPTS "/usr/local/pg-jar-src/${JAR_HOST_BASENAME}" "${user}@127.0.0.1:/tmp/${JAR_GUEST_NAME}"
            scp $SCP_OPTS /usr/local/pg-scripts/test-postgres-freebsd-guest.sh "${user}@127.0.0.1:/tmp/test-postgres-freebsd-guest.sh"

            log "Running PostgreSQL smoke test inside FreeBSD guest"
            if [ -n "$runner" ]; then
                ssh $SSH_OPTS "${user}@127.0.0.1" "chmod +x /tmp/test-postgres-freebsd-guest.sh && ${runner} env JAR_FILE=/tmp/${JAR_GUEST_NAME} ZIP_FILE=${ZIP_FILE} PG_VERSION=${PG_VERSION} /tmp/test-postgres-freebsd-guest.sh"
            else
                ssh $SSH_OPTS "${user}@127.0.0.1" "chmod +x /tmp/test-postgres-freebsd-guest.sh && env JAR_FILE=/tmp/${JAR_GUEST_NAME} ZIP_FILE=${ZIP_FILE} PG_VERSION=${PG_VERSION} /tmp/test-postgres-freebsd-guest.sh"
            fi
        }

        export DEBIAN_FRONTEND=noninteractive
        log "Installing host-side dependencies inside Docker image $IMG_NAME"
        apt-get update
        apt-get install -y --no-install-recommends \
            ca-certificates \
            curl \
            expect \
            netcat-openbsd \
            openssh-client \
            qemu-system-x86 \
            qemu-utils \
            xorriso \
            xz-utils

        WORK_DIR=$(mktemp -d /tmp/freebsd-test.XXXXXX)
        cleanup() {
            local errcode=$?
            if [ -f "$WORK_DIR/qemu.pid" ]; then
                kill "$(cat "$WORK_DIR/qemu.pid")" 2>/dev/null || true
                wait "$(cat "$WORK_DIR/qemu.pid")" 2>/dev/null || true
            fi
            if [ -f "$WORK_DIR/serial-driver.pid" ]; then
                kill "$(cat "$WORK_DIR/serial-driver.pid")" 2>/dev/null || true
                wait "$(cat "$WORK_DIR/serial-driver.pid")" 2>/dev/null || true
            fi
            rm -rf "$WORK_DIR"
            return $errcode
        }
        trap cleanup EXIT

        ssh-keygen -q -t ed25519 -N "" -f "$WORK_DIR/id_ed25519"
        SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i $WORK_DIR/id_ed25519 -p $SSH_PORT"
        SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i $WORK_DIR/id_ed25519 -P $SSH_PORT"

        if [ -e /dev/kvm ]; then
            QEMU_ACCEL=kvm
            QEMU_CPU=max
        else
            QEMU_ACCEL=tcg
            QEMU_CPU=qemu64
        fi

        if [ "$PROVISION_MODE" = cloudinit ]; then
            mkdir -p "$WORK_DIR/seed"
            VM_CACHE_BASENAME=$(basename "$VM_IMAGE_URL")
            if [ ! -f "/usr/local/pg-cache/${VM_CACHE_BASENAME}" ]; then
                log "Downloading FreeBSD cloud image from $VM_IMAGE_URL"
                curl -fsSL "$VM_IMAGE_URL" -o "/usr/local/pg-cache/${VM_CACHE_BASENAME}"
            else
                log "Using cached FreeBSD cloud image ${VM_CACHE_BASENAME}"
            fi
            if echo "$VM_IMAGE_URL" | grep -q "\.xz$"; then
                log "Decompressing FreeBSD cloud image"
                xz -dc "/usr/local/pg-cache/${VM_CACHE_BASENAME}" > "$WORK_DIR/freebsd-base.qcow2"
            else
                cp "/usr/local/pg-cache/${VM_CACHE_BASENAME}" "$WORK_DIR/freebsd-base.qcow2"
            fi

            log "Creating writable overlay"
            qemu-img create -q -f qcow2 -F qcow2 -b "$WORK_DIR/freebsd-base.qcow2" "$WORK_DIR/freebsd-overlay.qcow2"

            cat > "$WORK_DIR/seed/meta-data" <<EOF
instance-id: embedded-postgres-test-${PG_VERSION}
local-hostname: embedded-postgres-freebsd-test
EOF

            cat > "$WORK_DIR/seed/user-data" <<EOF
#!cloud-config
packages:
  - opendoas
users:
  - default
  - name: builder
    gecos: Embedded Postgres Test Runner
    groups:
      - wheel
    shell: /bin/sh
    ssh_authorized_keys:
      - $(cat "$WORK_DIR/id_ed25519.pub")
    doas: "permit nopass %u as root"
EOF

            xorriso -as mkisofs \
                -quiet \
                -o "$WORK_DIR/seed.iso" \
                -V cidata \
                -J \
                -R \
                "$WORK_DIR/seed/meta-data" \
                "$WORK_DIR/seed/user-data"

            log "Starting FreeBSD guest with QEMU accel=$QEMU_ACCEL memory=${VM_MEMORY_MB}MB cpus=$VM_CPUS ssh_port=$SSH_PORT"
            qemu-system-x86_64 \
                -daemonize \
                -display none \
                -monitor none \
                -pidfile "$WORK_DIR/qemu.pid" \
                -serial "file:$WORK_DIR/serial.log" \
                -machine "q35,accel=$QEMU_ACCEL" \
                -cpu "$QEMU_CPU" \
                -m "$VM_MEMORY_MB" \
                -smp "$VM_CPUS" \
                -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
                -device e1000,netdev=net0 \
                -drive "if=virtio,format=qcow2,file=$WORK_DIR/freebsd-overlay.qcow2" \
                -drive "if=virtio,media=cdrom,readonly=on,file=$WORK_DIR/seed.iso"

            wait_for_ssh builder 120
            log "Waiting for opendoas inside guest"
            ssh $SSH_OPTS builder@127.0.0.1 "while [ ! -x /usr/local/bin/doas ]; do sleep 2; done"
            run_guest_test builder doas
        else
            mkdir -p "$WORK_DIR/install-media/etc" "$WORK_DIR/install-media/boot"
            VM_CACHE_BASENAME=$(basename "$VM_IMAGE_URL")
            if [ ! -f "/usr/local/pg-cache/${VM_CACHE_BASENAME}" ]; then
                log "Downloading FreeBSD installer ISO from $VM_IMAGE_URL"
                curl -fsSL "$VM_IMAGE_URL" -o "/usr/local/pg-cache/${VM_CACHE_BASENAME}"
            else
                log "Using cached FreeBSD installer ISO ${VM_CACHE_BASENAME}"
            fi
            if echo "$VM_IMAGE_URL" | grep -q "\.xz$"; then
                log "Decompressing FreeBSD installer ISO"
                xz -dc "/usr/local/pg-cache/${VM_CACHE_BASENAME}" > "$WORK_DIR/freebsd-installer.iso"
            else
                cp "/usr/local/pg-cache/${VM_CACHE_BASENAME}" "$WORK_DIR/freebsd-installer.iso"
            fi

            cat > "$WORK_DIR/install-media/etc/installerconfig" <<EOF
export nonInteractive=YES
PARTITIONS=DEFAULT
DISTRIBUTIONS="kernel.txz base.txz"

#!/bin/sh
sysrc hostname=embedded-postgres-freebsd-test
sysrc ifconfig_DEFAULT=DHCP
sysrc sshd_enable=YES
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'"'"'KEYEOF'"'"'
$(cat "$WORK_DIR/id_ed25519.pub")
KEYEOF
chmod 600 /root/.ssh/authorized_keys
cat > /boot.config <<'"'"'BOOTEOF'"'"'
-Dh
BOOTEOF
cat > /boot/loader.conf <<'"'"'LOADERCONFEOF'"'"'
console="comconsole,vidconsole"
boot_multicons="YES"
autoboot_delay="1"
LOADERCONFEOF
printf "\nPermitRootLogin yes\nPasswordAuthentication no\nChallengeResponseAuthentication no\n" >> /etc/ssh/sshd_config
EOF

            cat > "$WORK_DIR/install-media/boot.config" <<EOF
-Dh
EOF

            cat > "$WORK_DIR/install-media/boot/loader.conf" <<EOF
console="comconsole,vidconsole"
boot_multicons="YES"
autoboot_delay="1"
EOF

            log "Embedding unattended installer configuration into FreeBSD installer ISO"
            xorriso \
                -indev "$WORK_DIR/freebsd-installer.iso" \
                -outdev "$WORK_DIR/freebsd-installer-auto.iso" \
                -map "$WORK_DIR/install-media/etc/installerconfig" /etc/installerconfig \
                -map "$WORK_DIR/install-media/boot.config" /boot.config \
                -map "$WORK_DIR/install-media/boot/loader.conf" /boot/loader.conf \
                -boot_image any keep \
                -compliance no_emul_toc

            log "Creating target disk image of size $VM_DISK_SIZE"
            qemu-img create -q -f qcow2 "$WORK_DIR/freebsd-system.qcow2" "$VM_DISK_SIZE"

            cat > "$WORK_DIR/drive-serial.expect" <<EOF
#!/usr/bin/expect -f
log_user 0
set timeout -1
log_file -a "$WORK_DIR/serial.log"
spawn nc 127.0.0.1 $SERIAL_PORT
expect {
    -re {Console type \\[vt100\\]:[ ]*} {
        send "\\r"
        exp_continue
    }
    eof {
        exit 0
    }
}
EOF
            chmod +x "$WORK_DIR/drive-serial.expect"

            log "Starting FreeBSD installer guest with QEMU accel=$QEMU_ACCEL memory=${VM_MEMORY_MB}MB cpus=$VM_CPUS ssh_port=$SSH_PORT"
            qemu-system-x86_64 \
                -daemonize \
                -display none \
                -monitor none \
                -pidfile "$WORK_DIR/qemu.pid" \
                -machine "q35,accel=$QEMU_ACCEL" \
                -cpu "$QEMU_CPU" \
                -m "$VM_MEMORY_MB" \
                -smp "$VM_CPUS" \
                -boot once=d \
                -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
                -device e1000,netdev=net0 \
                -serial "tcp:127.0.0.1:${SERIAL_PORT},server,nowait" \
                -drive "if=virtio,format=qcow2,file=$WORK_DIR/freebsd-system.qcow2" \
                -cdrom "$WORK_DIR/freebsd-installer-auto.iso"

            "$WORK_DIR/drive-serial.expect" &
            echo $! > "$WORK_DIR/serial-driver.pid"

            wait_for_ssh root 360
            run_guest_test root ""
        fi

        log "FreeBSD smoke test completed"
    '
