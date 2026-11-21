#!/bin/bash
set -euo pipefail

DOCKER_OPTS=
VM_IMAGE_URL=
VM_MEMORY_MB=4096
VM_CPUS=4
VM_DISK_SIZE=16G
SSH_PORT=2222
SERIAL_PORT=4444
CACHE_DIR=
REPO_DIR=
BUNDLE_FILE=

while getopts "i:u:m:c:p:s:k:r:b:o:" opt; do
    case $opt in
    i) IMG_NAME=$OPTARG ;;
    u) VM_IMAGE_URL=$OPTARG ;;
    m) VM_MEMORY_MB=$OPTARG ;;
    c) VM_CPUS=$OPTARG ;;
    p) SSH_PORT=$OPTARG ;;
    s) VM_DISK_SIZE=$OPTARG ;;
    k) CACHE_DIR=$OPTARG ;;
    r) REPO_DIR=$OPTARG ;;
    b) BUNDLE_FILE=$OPTARG ;;
    o) DOCKER_OPTS=$OPTARG ;;
    \?) exit 1 ;;
    esac
done

if [ -z "${IMG_NAME:-}" ] ; then
  echo "Docker image parameter is required!" && exit 1;
fi
if [ -z "${VM_IMAGE_URL:-}" ] ; then
  echo "FreeBSD VM image URL parameter is required!" && exit 1;
fi
if [ -z "${REPO_DIR:-}" ] ; then
  echo "embedded-postgres repository path parameter is required!" && exit 1;
fi
if [ -z "${BUNDLE_FILE:-}" ] ; then
  echo "FreeBSD postgres bundle parameter is required!" && exit 1;
fi

PROVISION_MODE=
if echo "$VM_IMAGE_URL" | grep -q 'BASIC-CLOUDINIT'; then
  PROVISION_MODE=cloudinit
elif echo "$VM_IMAGE_URL" | grep -Eq '(disc1|dvd1)\.iso(\.xz)?$'; then
  PROVISION_MODE=installer
else
  echo "FreeBSD VM image URL must point to either a BASIC-CLOUDINIT image or a release disc1.iso/dvd1.iso installer image." && exit 1;
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB_DIR=$PWD
CACHE_DIR=${CACHE_DIR:-$PWD/.cache/freebsd-builder}
mkdir -p "$CACHE_DIR"

if [ ! -d "$REPO_DIR" ] ; then
  echo "embedded-postgres repository not found: $REPO_DIR" && exit 1;
fi
if [ ! -f "$BUNDLE_FILE" ] ; then
  if [ ! -f "$LIB_DIR/$BUNDLE_FILE" ] ; then
    echo "Bundle file not found: $BUNDLE_FILE" && exit 1;
  fi
  BUNDLE_HOST_PATH="$LIB_DIR/$BUNDLE_FILE"
else
  BUNDLE_HOST_PATH="$BUNDLE_FILE"
fi

REPO_HOST_PATH=$(cd "$REPO_DIR" && pwd)
BUNDLE_HOST_DIR=$(cd "$(dirname "$BUNDLE_HOST_PATH")" && pwd)
BUNDLE_HOST_BASENAME=$(basename "$BUNDLE_HOST_PATH")

docker run -i --rm \
    -v "${REPO_HOST_PATH}:/usr/local/src/embedded-postgres:ro" \
    -v "${BUNDLE_HOST_DIR}:/usr/local/pg-bundle:ro" \
    -v "${CACHE_DIR}:/usr/local/pg-cache" \
    -v "${SCRIPT_DIR}:/usr/local/pg-scripts:ro" \
    -e IMG_NAME="$IMG_NAME" \
    -e VM_IMAGE_URL="$VM_IMAGE_URL" \
    -e VM_MEMORY_MB="$VM_MEMORY_MB" \
    -e VM_CPUS="$VM_CPUS" \
    -e VM_DISK_SIZE="$VM_DISK_SIZE" \
    -e PROVISION_MODE="$PROVISION_MODE" \
    -e SSH_PORT="$SSH_PORT" \
    -e SERIAL_PORT="$SERIAL_PORT" \
    -e BUNDLE_HOST_BASENAME="$BUNDLE_HOST_BASENAME" \
    $DOCKER_OPTS "$IMG_NAME" /bin/bash -eu -c '
        log() {
            echo "[embedded-postgres-freebsd-test] $*"
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

        WORK_DIR=$(mktemp -d /tmp/embedded-postgres-freebsd-test.XXXXXX)
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

        VM_CACHE_BASENAME=$(basename "$VM_IMAGE_URL")
        if [ ! -f "/usr/local/pg-cache/${VM_CACHE_BASENAME}" ]; then
            if [ "$PROVISION_MODE" = cloudinit ]; then
                log "Downloading FreeBSD cloud image from $VM_IMAGE_URL"
            else
                log "Downloading FreeBSD installer ISO from $VM_IMAGE_URL"
            fi
            curl -fsSL "$VM_IMAGE_URL" -o "/usr/local/pg-cache/${VM_CACHE_BASENAME}"
        else
            if [ "$PROVISION_MODE" = cloudinit ]; then
                log "Using cached FreeBSD cloud image ${VM_CACHE_BASENAME}"
            else
                log "Using cached FreeBSD installer ISO ${VM_CACHE_BASENAME}"
            fi
        fi

        if [ "$PROVISION_MODE" = cloudinit ]; then
            mkdir -p "$WORK_DIR/seed"
            if echo "$VM_IMAGE_URL" | grep -q "\.xz$"; then
                log "Decompressing FreeBSD cloud image"
                xz -dc "/usr/local/pg-cache/${VM_CACHE_BASENAME}" > "$WORK_DIR/freebsd-base.qcow2"
            else
                cp "/usr/local/pg-cache/${VM_CACHE_BASENAME}" "$WORK_DIR/freebsd-base.qcow2"
            fi

            log "Creating writable overlay"
            qemu-img create -q -f qcow2 -F qcow2 -b "$WORK_DIR/freebsd-base.qcow2" "$WORK_DIR/freebsd-overlay.qcow2"

            cat > "$WORK_DIR/seed/meta-data" <<EOF
instance-id: embedded-postgres-test
local-hostname: embedded-postgres-freebsd-test
EOF

            cat > "$WORK_DIR/seed/user-data" <<EOF
#cloud-config
packages:
  - opendoas
users:
  - default
  - name: builder
    gecos: Embedded Postgres Tester
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

            log "Starting FreeBSD cloud guest with QEMU accel=$QEMU_ACCEL memory=${VM_MEMORY_MB}MB cpus=$VM_CPUS ssh_port=$SSH_PORT"
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

            wait_for_ssh builder 180
            log "Waiting for opendoas inside guest"
            ssh $SSH_OPTS builder@127.0.0.1 "while [ ! -x /usr/local/bin/doas ]; do sleep 2; done"

            log "Copying embedded-postgres repo, bundle and guest helper"
            tar -C /usr/local/src -cf - embedded-postgres | ssh $SSH_OPTS builder@127.0.0.1 "mkdir -p /tmp && tar -xf - -C /tmp"
            scp $SCP_OPTS "/usr/local/pg-bundle/${BUNDLE_HOST_BASENAME}" builder@127.0.0.1:/tmp/"${BUNDLE_HOST_BASENAME}"
            scp $SCP_OPTS /usr/local/pg-scripts/test-embedded-postgres-freebsd-guest.sh builder@127.0.0.1:/tmp/test-embedded-postgres-freebsd-guest.sh

            log "Running embedded-postgres examples inside FreeBSD guest"
            ssh $SSH_OPTS builder@127.0.0.1 "chmod +x /tmp/test-embedded-postgres-freebsd-guest.sh && doas env BUNDLE_FILE=/tmp/${BUNDLE_HOST_BASENAME} REPO_DIR=/tmp/embedded-postgres /tmp/test-embedded-postgres-freebsd-guest.sh"
        else
            mkdir -p "$WORK_DIR/install-media/etc" "$WORK_DIR/install-media/boot"
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
    -re {Mirror Selection|Select a site!} {
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

            log "Copying embedded-postgres repo, bundle and guest helper"
            tar -C /usr/local/src -cf - embedded-postgres | ssh $SSH_OPTS root@127.0.0.1 "mkdir -p /var/tmp && tar -xf - -C /var/tmp"
            scp $SCP_OPTS "/usr/local/pg-bundle/${BUNDLE_HOST_BASENAME}" root@127.0.0.1:/tmp/"${BUNDLE_HOST_BASENAME}"
            scp $SCP_OPTS /usr/local/pg-scripts/test-embedded-postgres-freebsd-guest.sh root@127.0.0.1:/tmp/test-embedded-postgres-freebsd-guest.sh

            log "Running embedded-postgres examples inside FreeBSD guest"
            ssh $SSH_OPTS root@127.0.0.1 "chmod +x /tmp/test-embedded-postgres-freebsd-guest.sh && env BUNDLE_FILE=/tmp/${BUNDLE_HOST_BASENAME} REPO_DIR=/var/tmp/embedded-postgres /tmp/test-embedded-postgres-freebsd-guest.sh"
        fi

        log "embedded-postgres FreeBSD example test completed"
    '
