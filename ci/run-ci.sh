#!/usr/bin/env bash
#
# ci/run-ci.sh — Build and test xCAT inside a target VM
#
# Usage: ci/run-ci.sh --target el9|el10|ubuntu-22.04|ubuntu-24.04 --run-id <id>
#
# Creates a VM matching the target OS, builds xCAT packages inside it,
# installs them, starts xcatd, and runs xcattest -s ci_test.
# Exits nonzero if ANY step fails.
#
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
STATE_DIR="/var/lib/xcat3-ci"
STATE_FILE="$STATE_DIR/managed-vms.txt"
CLOUD_IMG_DIR="/var/lib/libvirt/images"
ARCH="$(uname -m)"
SSH_KEY="$STATE_DIR/ci-ssh-key"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR=""
REUSE_VM=0
SKIP_BUILD=0
KEEP_VM=0

TARGET=""
RUN_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)       TARGET="$2"; shift 2 ;;
        --run-id)       RUN_ID="$2"; shift 2 ;;
        --artifact-dir) ARTIFACT_DIR="$2"; shift 2 ;;
        --reuse-vm)     REUSE_VM=1; shift ;;
        --skip-build)   SKIP_BUILD=1; shift ;;
        --keep-vm)      KEEP_VM=1; shift ;;
        *)              echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$TARGET" ]] && { echo "ERROR: --target required" >&2; exit 1; }
[[ -z "$RUN_ID" ]] && { echo "ERROR: --run-id required" >&2; exit 1; }

VM_NAME="xcat-ci-${RUN_ID}"
VM_DISK="${CLOUD_IMG_DIR}/${VM_NAME}.qcow2"
NET_NAME="xcat-ci-net-${RUN_ID}"

# Derive unique subnet from run-id
HASH_VAL=$(echo "$RUN_ID" | md5sum | cut -c1-4)
OCTET2=$(( (16#${HASH_VAL:0:2} % 55) + 200 ))
OCTET3=$(( 16#${HASH_VAL:2:2} % 255 ))
NET_SUBNET="10.${OCTET2}.${OCTET3}"
VM_IP="${NET_SUBNET}.1"

# ── Helpers ──────────────────────────────────────────────────────────────────
log() { echo "$(date '+%H:%M:%S') [ci] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

ssh_vm() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}

vm_exists() {
    local name="${1:-$VM_NAME}"
    virsh dominfo "$name" &>/dev/null
}

net_exists() {
    local name="${1:-$NET_NAME}"
    virsh net-info "$name" &>/dev/null
}

state_init() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    chmod 666 "$STATE_FILE" 2>/dev/null || true
    [[ -f "$SSH_KEY" ]] || ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
    prune_state
}

state_add() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >> "$STATE_FILE"
}

prune_state() {
    local tmp
    tmp=$(mktemp)
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if [[ "$entry" == net:* ]]; then
            net_exists "${entry#net:}" && echo "$entry" >> "$tmp"
        elif virsh dominfo "$entry" &>/dev/null; then
            echo "$entry" >> "$tmp"
        fi
    done < "$STATE_FILE"
    mv "$tmp" "$STATE_FILE"
}

cleanup() {
    log "Cleaning up $VM_NAME"
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
    virsh net-destroy "$NET_NAME" 2>/dev/null || true
    virsh net-undefine "$NET_NAME" 2>/dev/null || true
    rm -rf "$STATE_DIR/${VM_NAME}-ci" "$STATE_DIR/${VM_NAME}-cidata.iso"
    local tmp; tmp=$(mktemp)
    grep -vxF "$VM_NAME" "$STATE_FILE" 2>/dev/null | grep -vxF "net:$NET_NAME" > "$tmp" || true
    mv "$tmp" "$STATE_FILE"
}

log_optimizations() {
    local active=()
    [[ $REUSE_VM -eq 1 ]] && active+=("O1:reuse-vm")
    [[ $SKIP_BUILD -eq 1 ]] && active+=("O2:skip-build")
    [[ $KEEP_VM -eq 1 ]] && active+=("keep-vm")
    if [[ ${#active[@]} -eq 0 ]]; then
        log "OPTIMIZATIONS ACTIVE: none"
    else
        log "OPTIMIZATIONS ACTIVE: ${active[*]}"
    fi
}

# ── Resolve cloud image ─────────────────────────────────────────────────────
resolve_image() {
    local img os_family
    case "$TARGET" in
        el9)
            os_family="el"
            [[ "$ARCH" == "x86_64" ]] && img="Rocky-9-GenericCloud-Base.latest.x86_64.qcow2" \
                                       || img="Rocky-9-GenericCloud-Base.latest.ppc64le.qcow2"
            ;;
        el10)
            os_family="el"
            [[ "$ARCH" == "x86_64" ]] && img="AlmaLinux-10-GenericCloud-x86_64.qcow2" \
                                       || img="AlmaLinux-10-GenericCloud-ppc64le.qcow2"
            ;;
        ubuntu-22.04)
            os_family="ubuntu"
            [[ "$ARCH" == "x86_64" ]] && img="jammy-server-cloudimg-amd64.img" \
                                       || img="jammy-server-cloudimg-ppc64el.img"
            ;;
        ubuntu-24.04)
            os_family="ubuntu"
            [[ "$ARCH" == "x86_64" ]] && img="noble-server-cloudimg-amd64.img" \
                                       || img="noble-server-cloudimg-ppc64el.img"
            ;;
        ubuntu-26.04)
            os_family="ubuntu"
            [[ "$ARCH" == "x86_64" ]] && img="resolute-server-cloudimg-amd64.img" \
                                       || img="resolute-server-cloudimg-ppc64el.img"
            ;;
        *) die "Unknown target: $TARGET" ;;
    esac
    [[ -f "$CLOUD_IMG_DIR/$img" ]] || die "Cloud image not found: $CLOUD_IMG_DIR/$img"
    echo "$CLOUD_IMG_DIR/$img"
}

# ── Create VM ────────────────────────────────────────────────────────────────
create_vm() {
    local base_img="$1"
    local ci_dir="$STATE_DIR/${VM_NAME}-ci"
    mkdir -p "$ci_dir"

    # Determine OS family
    local os_family="el"
    [[ "$TARGET" == ubuntu-* ]] && os_family="ubuntu"

    # Cloud-init user-data
    cat > "$ci_dir/user-data" << USERDATA
#cloud-config
hostname: ${VM_NAME}
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: root
      password: xcat3ci
      type: text
ssh_authorized_keys:
  - $(cat "${SSH_KEY}.pub")
runcmd:
  - touch /var/lib/cloud-init-done
USERDATA

    cat > "$ci_dir/meta-data" << MD
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
MD

    # Network config — EL uses eth0, Ubuntu uses wildcard match
    if [[ "$os_family" == "ubuntu" ]]; then
        cat > "$ci_dir/network-config" << NC
version: 2
ethernets:
  id0:
    match:
      name: "e*"
    addresses: [${VM_IP}/24]
    routes: [{to: 0.0.0.0/0, via: ${NET_SUBNET}.254}]
    nameservers: {addresses: [1.1.1.1, 8.8.8.8]}
NC
    else
        cat > "$ci_dir/network-config" << NC
version: 2
ethernets:
  eth0:
    addresses: [${VM_IP}/24]
    routes: [{to: 0.0.0.0/0, via: ${NET_SUBNET}.254}]
    nameservers: {addresses: [1.1.1.1, 8.8.8.8]}
NC
    fi

    # Cloud-init ISO
    local ci_iso="$STATE_DIR/${VM_NAME}-cidata.iso"
    genisoimage -output "$ci_iso" -volid cidata -joliet -rock \
        "$ci_dir/user-data" "$ci_dir/meta-data" "$ci_dir/network-config" 2>/dev/null

    # Libvirt network
    local bridge_id; bridge_id=$(echo "$RUN_ID" | md5sum | cut -c1-6)
    local net_xml; net_xml=$(mktemp)
    cat > "$net_xml" << NX
<network>
  <name>${NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='xcibr${bridge_id}' stp='on' delay='0'/>
  <ip address='${NET_SUBNET}.254' netmask='255.255.255.0'/>
</network>
NX
    virsh net-define "$net_xml" >&2
    virsh net-start "$NET_NAME" >&2
    rm -f "$net_xml"

    # Create disk + VM
    qemu-img create -f qcow2 -b "$base_img" -F qcow2 "$VM_DISK" 100G >&2
    local machine_type; [[ "$ARCH" == "ppc64le" ]] && machine_type="pseries" || machine_type="q35"
    local osinfo
    if [[ "$os_family" == "ubuntu" ]]; then
        local ver="${TARGET#ubuntu-}"
        osinfo="ubuntu${ver}"
    else
        osinfo="rocky9"
    fi

    virt-install --connect qemu:///system --name "$VM_NAME" \
        --memory 8192 --vcpus 4 --cpu host-passthrough \
        --machine "$machine_type" --import \
        --disk "$VM_DISK" --disk "$ci_iso,device=cdrom" \
        --network network="$NET_NAME" --osinfo name="$osinfo" \
        --noautoconsole --noreboot >&2

    state_add "$VM_NAME"
    state_add "net:$NET_NAME"
    virsh start "$VM_NAME" >&2
    log "VM $VM_NAME started at $VM_IP"
}

# ── Wait for SSH + cloud-init ────────────────────────────────────────────────
wait_ready() {
    log "Waiting for SSH at $VM_IP..."
    local elapsed=0
    while [[ $elapsed -lt 600 ]]; do
        if ssh_vm -o ConnectTimeout=5 -o BatchMode=yes root@"$VM_IP" 'true' 2>/dev/null; then
            log "SSH ready"
            break
        fi
        sleep 10; elapsed=$((elapsed + 10))
    done
    [[ $elapsed -lt 600 ]] || die "SSH timeout"

    log "Waiting for cloud-init to finish..."
    ssh_vm root@"$VM_IP" 'cloud-init status --wait 2>/dev/null || timeout 600 bash -c "while [ ! -f /var/lib/cloud-init-done ]; do sleep 5; done"'
    log "VM ready"
}

# ── Install build dependencies ───────────────────────────────────────────────
install_deps() {
    log "Installing build dependencies"
    if [[ "$TARGET" == el* ]]; then
        ssh_vm root@"$VM_IP" bash << 'DEPS'
set -euo pipefail
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config 2>/dev/null || true
setenforce 0 2>/dev/null || true
# Use fastestmirror and increase timeout for slow mirrors
echo "fastestmirror=1" >> /etc/dnf/dnf.conf
echo "timeout=120" >> /etc/dnf/dnf.conf
echo "retries=5" >> /etc/dnf/dnf.conf
dnf install -y epel-release
dnf config-manager --set-enabled crb 2>/dev/null || true
dnf install -y mock createrepo_c rpm-build git initscripts \
    perl perl-core perl-generators \
    perl-File-Slurper perl-Parallel-ForkManager \
    perl-Pod-Usage perl-autodie perl-Carp
usermod -aG mock root
echo "EL deps installed"
DEPS
    else
        ssh_vm root@"$VM_IP" bash << 'DEPS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>&1
apt-get install -y -qq git reprepro devscripts debhelper quilt \
    libsoap-lite-perl libdbi-perl libjson-perl libcgi-pm-perl perl 2>&1
echo "Ubuntu deps installed"
DEPS
    fi
}

# ── Copy source ──────────────────────────────────────────────────────────────
copy_source() {
    log "Copying source to VM"
    ssh_vm root@"$VM_IP" 'rm -rf /root/xcat-core && mkdir -p /root/xcat-core'
    tar -C "$REPO_ROOT" \
        --exclude-vcs \
        --exclude artifacts \
        -cf - . \
        | ssh_vm root@"$VM_IP" 'tar --no-same-owner -C /root/xcat-core -xf - && chown -R root:root /root/xcat-core'
    # Create a minimal git repo so build scripts (modifyUtils, build-ubunturepo) work
    ssh_vm root@"$VM_IP" '
        set -e
        rm -rf /root/xcat-core/.git
        git -C /root/xcat-core init -q
        git -C /root/xcat-core add -A
        git -C /root/xcat-core -c user.email=ci@xcat -c user.name=CI commit -q -m "ci build"
    '
}

# ── Build ────────────────────────────────────────────────────────────────────
build_packages() {
    log "Building packages for $TARGET"
    if [[ "$TARGET" == el* ]]; then
        local elver="${TARGET#el}"
        local distro
        ssh_vm root@"$VM_IP" bash -s "$elver" << 'BUILD_RPM'
set -euo pipefail
ELVER="$1"
cd /root/xcat-core
DISTRO=$(. /etc/os-release && echo "$ID")
case "$DISTRO" in almalinux) DISTRO="alma";; rocky) DISTRO="rocky";; esac
ARCH=$(uname -m)
TARGET="${DISTRO}+epel-${ELVER}-${ARCH}"

git rev-parse HEAD > Gitinfo 2>/dev/null || echo "unknown" > Gitinfo
echo "snap$(date +%Y%m%d%H%M)" > Release
mkdir -p ~/rpmbuild/SOURCES

echo "Building target: $TARGET"
perl buildrpms.pl --target "$TARGET" --force
createrepo "dist/$TARGET/rpms/"
echo "Build complete: $(find dist/$TARGET/rpms -name '*.rpm' | wc -l) RPMs"
BUILD_RPM
    else
        ssh_vm root@"$VM_IP" bash << 'BUILD_DEB'
set -euo pipefail
cd /root/xcat-core
git rev-parse HEAD > Gitinfo 2>/dev/null || echo "unknown" > Gitinfo
echo "snap$(date +%Y%m%d%H%M)" > Release

echo "Building Ubuntu debs..."
DISTS="jammy noble resolute" ./build-ubunturepo -c UP=0 BUILDALL=1 GPGSIGN=0 DEST=/root/xcat-debs
echo "Build complete"
ls /root/xcat-debs/debs/*.deb 2>/dev/null | wc -l
BUILD_DEB
    fi
}

# ── Initialize xCAT ─────────────────────────────────────────────────────────
init_xcat() {
    log "Running xcatconfig -i for management-node initialization"
    ssh_vm root@"$VM_IP" bash << 'XCATCONFIG'
set -euo pipefail
export XCATROOT=/opt/xcat
export PATH="$XCATROOT/bin:$XCATROOT/sbin:$PATH"
export PERL5LIB="$XCATROOT/lib/perl:${PERL5LIB:-}"
$XCATROOT/sbin/xcatconfig -i
test -f /root/.xcat/client-cred.pem
echo "xcatconfig init complete"
XCATCONFIG

    log "Initializing xCAT database"
    ssh_vm root@"$VM_IP" bash << 'XCATDB'
set -euo pipefail
export XCATROOT=/opt/xcat
export PATH="$XCATROOT/bin:$XCATROOT/sbin:$PATH"
export PERL5LIB="$XCATROOT/lib/perl"
XCAT_DOMAIN="cluster.net"
MASTER_IP=$(hostname -I | awk '{print $1}')
mkdir -p /etc/xcat
$XCATROOT/sbin/chtab key=xcatdport site.value=3001
$XCATROOT/sbin/chtab key=xcatiport site.value=3002
$XCATROOT/sbin/chtab key=master site.value="$MASTER_IP"
$XCATROOT/sbin/chtab key=domain site.value="$XCAT_DOMAIN"
$XCATROOT/sbin/chtab key=installdir site.value=/install
$XCATROOT/sbin/chtab key=tftpdir site.value=/tftpboot
while IFS= read -r netname; do
    [[ -n "$netname" ]] || continue
    $XCATROOT/sbin/chdef -t network -o "$netname" domain="$XCAT_DOMAIN" >/dev/null
done < <($XCATROOT/sbin/lsdef -t network 2>/dev/null | awk 'NF { print $1 }')
echo "xCAT DB initialized"
XCATDB
}

# ── Install ──────────────────────────────────────────────────────────────────
install_packages() {
    log "Installing xCAT packages"
    if [[ "$TARGET" == el* ]]; then
        local elver="${TARGET#el}"
        local dep_root="/opt/xcat-dep/el${elver}"
        if [[ -d "$dep_root" ]]; then
            log "Copying xcat-dep tree from $dep_root to VM"
            ssh_vm root@"$VM_IP" 'mkdir -p /opt/xcat-dep'
            tar -C "$dep_root" -cf - . | ssh_vm root@"$VM_IP" 'tar -C /opt/xcat-dep -xf -'
        else
            log "WARNING: xcat-dep not found at $dep_root"
        fi
        if [[ "$elver" -ge 10 ]] \
            && ! compgen -G "$dep_root/$ARCH/goconserver-*.rpm" > /dev/null; then
            local fallback_dep_root="/opt/xcat-dep/el9/$ARCH"
            if compgen -G "$fallback_dep_root/goconserver-*.rpm" > /dev/null; then
                local rpm
                for rpm in "$fallback_dep_root"/goconserver-*.rpm; do
                    log "Copying fallback $(basename "$rpm") from $fallback_dep_root to VM"
                    cat "$rpm" | ssh_vm root@"$VM_IP" "cat > /opt/xcat-dep/$ARCH/$(basename "$rpm")"
                done
            else
                log "WARNING: No fallback goconserver RPM found under $fallback_dep_root"
            fi
        fi

        ssh_vm root@"$VM_IP" bash -s "$elver" << 'INSTALL_RPM'
set -euo pipefail
ELVER="$1"
cd /root/xcat-core
DISTRO=$(. /etc/os-release && echo "$ID")
case "$DISTRO" in almalinux) DISTRO="alma";; rocky) DISTRO="rocky";; esac
ARCH=$(uname -m)
TARGET="${DISTRO}+epel-${ELVER}-${ARCH}"

# Refresh same-arch xcat-dep metadata so any staged fallback RPMs are visible.
if [[ -d "/opt/xcat-dep/$ARCH" ]]; then
    createrepo_c "/opt/xcat-dep/$ARCH" 2>&1
fi

cat > /etc/yum.repos.d/xcat-local.repo << REPO
[xcat-core-local]
name=xCAT Core Local Build
baseurl=file:///root/xcat-core/dist/$TARGET/rpms/
gpgcheck=0
enabled=1

[xcat-dep-local]
name=xCAT Dependencies ($ARCH)
baseurl=file:///opt/xcat-dep/$ARCH/
gpgcheck=0
enabled=1
REPO
dnf makecache

dnf install -y xCAT xCAT-test

rpm -q xCAT || { echo "FAIL: xCAT not installed"; exit 1; }
rpm -q xCAT-server || { echo "FAIL: xCAT-server not installed"; exit 1; }
rpm -q xCAT-test || { echo "FAIL: xCAT-test not installed"; exit 1; }
rpm -q perl-xCAT || { echo "FAIL: perl-xCAT not installed"; exit 1; }
echo "All xCAT packages installed"
INSTALL_RPM

        init_xcat
    else
        local codename
        case "$TARGET" in
            ubuntu-22.04) codename=jammy ;;
            ubuntu-24.04) codename=noble ;;
            ubuntu-26.04) codename=resolute ;;
            *) die "Unknown Ubuntu target: $TARGET" ;;
        esac

        local dep_root="/opt/xcat-dep/apt"
        if [[ -d "$dep_root" ]]; then
            log "Copying xcat-dep APT repo to VM"
            ssh_vm root@"$VM_IP" 'mkdir -p /opt/xcat-dep/apt'
            tar -C "$dep_root" -cf - . | ssh_vm root@"$VM_IP" 'tar -C /opt/xcat-dep/apt -xf -'
        else
            log "WARNING: xcat-dep APT repo not found at $dep_root"
        fi

        ssh_vm root@"$VM_IP" bash -s "$codename" << 'INSTALL_DEB'
set -eu
export DEBIAN_FRONTEND=noninteractive
CODENAME="$1"

ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)

# Configure xcat-dep from local repo (copied from host)
echo "deb [arch=$ARCH trusted=yes] file:///opt/xcat-dep/apt $CODENAME main" \
    > /etc/apt/sources.list.d/xcat-dep.list

# Configure local xcat-core repo
REPO_DIR=$(find /root/xcat-debs -name "mklocalrepo.sh" -printf '%h\n' 2>/dev/null | head -1)
if [[ -n "$REPO_DIR" ]]; then
    cd "$REPO_DIR"
    echo "deb [arch=$ARCH trusted=yes] file://$(pwd) $CODENAME main" \
        > /etc/apt/sources.list.d/xcat-core.list
fi

apt-get update -qq 2>&1
apt-get install -y xcat xcat-test 2>&1

echo "Installed xCAT packages:"
dpkg -l 2>/dev/null | grep -i xcat || echo "(none found)"
dpkg -s xcat >/dev/null 2>&1 || { echo "FAIL: xcat not installed"; exit 1; }
dpkg -s perl-xcat >/dev/null 2>&1 || { echo "FAIL: perl-xcat not installed"; exit 1; }
dpkg -s xcat-server >/dev/null 2>&1 || { echo "FAIL: xcat-server not installed"; exit 1; }
dpkg -s xcat-test >/dev/null 2>&1 || { echo "FAIL: xcat-test not installed"; exit 1; }
echo "All xCAT packages installed"
INSTALL_DEB

        init_xcat
    fi
}

# ── Test ─────────────────────────────────────────────────────────────────────
run_tests() {
    log "Running tests"
    ssh_vm root@"$VM_IP" bash << 'TEST'
set -euo pipefail
export XCATROOT=/opt/xcat
export PATH="$XCATROOT/bin:$XCATROOT/sbin:$XCATROOT/share/xcat/tools:$PATH"
export PERL5LIB="$XCATROOT/lib/perl:${PERL5LIB:-}"

# Start xcatd
if command -v xcatd &>/dev/null || [[ -f /etc/init.d/xcatd ]]; then
    systemctl start xcatd || service xcatd start || {
        echo "FAIL: xcatd failed to start"
        systemctl status xcatd --no-pager 2>/dev/null || true
        journalctl -u xcatd --no-pager -n 30 2>/dev/null || true
        exit 1
    }
    echo "Waiting for xcatd..."
    for i in $(seq 1 24); do
        lsdef -t site -o clustersite -i master -c &>/dev/null && break
        sleep 5
    done
    if ! lsdef -t site -o clustersite -i master -c >/dev/null 2>&1; then
        echo "FAIL: xcatd not responding after 120s"
        lsdef -t site -o clustersite -i master -c 2>&1 || true
        lsxcatd -d 2>&1 || true
        systemctl status xcatd --no-pager 2>/dev/null || true
        journalctl -u xcatd --no-pager -n 30 2>/dev/null || true
        exit 1
    fi
    echo "PASS: xcatd responding"
else
    echo "FAIL: xcatd command/service not available"
    exit 1
fi
TEST

    # Seed DNS/DDNS key material so makedhcp -n works with Kea on EL10+
    # Skip on Ubuntu — bind9 may not be installed
    if [[ "$TARGET" == el* ]]; then
        log "Seeding DNS configuration"
        ssh_vm root@"$VM_IP" bash << 'SEEDNS'
set -euo pipefail
export XCATROOT=/opt/xcat
export PATH="$XCATROOT/bin:$XCATROOT/sbin:$XCATROOT/share/xcat/tools:$PATH"
export PERL5LIB="$XCATROOT/lib/perl:${PERL5LIB:-}"
makedns -n
echo "PASS: makedns -n"
SEEDNS
    else
        log "Skipping makedns -n on Ubuntu"
    fi

    # Run xcattest in separate SSH call (long heredocs get truncated)
    log "Running xcattest -s ci_test"
    ssh_vm root@"$VM_IP" bash << 'XCATTEST'
set -euo pipefail
export XCATROOT=/opt/xcat
export PATH="$XCATROOT/bin:$XCATROOT/sbin:$XCATROOT/share/xcat/tools:$PATH"
export PERL5LIB="$XCATROOT/lib/perl:${PERL5LIB:-}"
echo "xcattest location: $(which xcattest 2>&1)"
xcattest -s ci_test
echo "PASS: xcattest -s ci_test"
XCATTEST
}

# ── Extract artifacts ────────────────────────────────────────────────────────
extract_artifacts() {
    [[ -z "$ARTIFACT_DIR" ]] && return
    log "Extracting artifacts to $ARTIFACT_DIR"
    mkdir -p "$ARTIFACT_DIR"
    if [[ "$TARGET" == el* ]]; then
        local count
        count=$(ssh_vm root@"$VM_IP" 'find /root/xcat-core/dist -name "*.rpm" ! -name "*.src.rpm" | wc -l')
        log "Found $count RPMs in VM"
        if [[ "$count" -gt 0 ]]; then
            ssh_vm root@"$VM_IP" 'cd /root/xcat-core && find dist -name "*.rpm" ! -name "*.src.rpm" -print0 | tar --null -T - -cf -' \
                | tar -C "$ARTIFACT_DIR" -xf -
        fi
    else
        local count
        count=$(ssh_vm root@"$VM_IP" 'find /root/xcat-debs -name "*.deb" | wc -l')
        log "Found $count debs in VM"
        if [[ "$count" -gt 0 ]]; then
            ssh_vm root@"$VM_IP" 'cd /root && find xcat-debs -name "*.deb" -print0 | tar --null -T - -cf -' \
                | tar -C "$ARTIFACT_DIR" -xf -
        fi
    fi
    log "Artifacts extracted: $(find "$ARTIFACT_DIR" -type f | wc -l) files"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    state_init
    log_optimizations
    if [[ $REUSE_VM -eq 0 ]]; then
        # Pre-cleanup: remove leftovers from previous runs with same run-id
        cleanup 2>/dev/null || true
    fi
    [[ $KEEP_VM -eq 0 ]] && trap cleanup EXIT

    local base_img
    base_img=$(resolve_image)
    log "Target=$TARGET Arch=$ARCH Image=$(basename "$base_img")"

    if [[ $REUSE_VM -eq 1 ]] && vm_exists; then
        log "Reusing existing VM $VM_NAME"
        if ! net_exists; then
            log "Existing VM found but network missing, recreating run resources"
            cleanup 2>/dev/null || true
            create_vm "$base_img"
        else
            state_add "$VM_NAME"
            state_add "net:$NET_NAME"
            virsh start "$VM_NAME" 2>/dev/null || true
        fi
    else
        create_vm "$base_img"
    fi
    wait_ready
    install_deps
    if [[ $SKIP_BUILD -eq 0 ]]; then
        copy_source
        build_packages
    else
        log "Skipping source copy and package build"
    fi
    install_packages
    run_tests
    extract_artifacts

    log "ALL STEPS PASSED for $TARGET $ARCH"
}

main "$@"
