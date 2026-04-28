#!/usr/bin/env bash
#
# ci/create-test-env.sh — Create an isolated xCAT test environment
#
# Creates a libvirt network + management node VM for xCAT testing.
# Prints MN_IP to stdout. All other output goes to stderr.
#
set -euo pipefail

STATE_DIR="/var/lib/xcat3-ci"
STATE_FILE="$STATE_DIR/managed-vms.txt"
CLOUD_IMG_DIR="/var/lib/libvirt/images"
ARCH="$(uname -m)"
SSH_KEY="$STATE_DIR/ci-ssh-key"

MN_MEMORY=8192
MN_VCPUS=4
MN_DISK_SIZE="100G"

RUN_ID=""
OS_FAMILY="el"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)    RUN_ID="$2"; shift 2 ;;
        --os-family) OS_FAMILY="$2"; shift 2 ;;
        *)           echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$RUN_ID" ]] && { echo "ERROR: --run-id required" >&2; exit 1; }

# Derive unique /24 subnet from run-id hash (10.X.Y.0/24 where X=200..254, Y=0..254)
HASH_VAL=$(echo "$RUN_ID" | md5sum | cut -c1-4)
OCTET2=$(( (16#${HASH_VAL:0:2} % 55) + 200 ))
OCTET3=$(( 16#${HASH_VAL:2:2} % 255 ))
NET_SUBNET="10.${OCTET2}.${OCTET3}"
MN_IP="${NET_SUBNET}.1"

NET_NAME="xcat-ci-${RUN_ID}"
MN_NAME="xcat-ci-mn-${RUN_ID}"
VM_DISK="${CLOUD_IMG_DIR}/${MN_NAME}.qcow2"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [create-env] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

state_init() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    chmod 666 "$STATE_FILE" 2>/dev/null || true
    if [[ ! -f "$SSH_KEY" ]]; then
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
        log "Generated CI SSH key at $SSH_KEY"
    fi
}

state_add() {
    echo "$1" >> "$STATE_FILE"
    log "Registered $1 in $STATE_FILE"
}

ensure_cloud_image() {
    local base_img
    if [[ "$OS_FAMILY" == "el" ]]; then
        if [[ "$ARCH" == "x86_64" ]]; then
            base_img="$CLOUD_IMG_DIR/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
        elif [[ "$ARCH" == "ppc64le" ]]; then
            base_img="$CLOUD_IMG_DIR/Rocky-9-GenericCloud-Base.latest.ppc64le.qcow2"
        else
            die "Unsupported architecture: $ARCH"
        fi
    elif [[ "$OS_FAMILY" == "ubuntu" ]]; then
        local ubuntu_arch
        [[ "$ARCH" == "x86_64" ]] && ubuntu_arch="amd64" || ubuntu_arch="ppc64el"
        base_img="$CLOUD_IMG_DIR/jammy-server-cloudimg-${ubuntu_arch}.img"
    else
        die "Unknown os-family: $OS_FAMILY"
    fi
    [[ -f "$base_img" ]] || die "Cloud image not found: $base_img — must be pre-staged"
    echo "$base_img"
}

create_network() {
    log "Creating libvirt network $NET_NAME"
    local net_xml BRIDGE_ID
    BRIDGE_ID=$(echo "$RUN_ID" | md5sum | cut -c1-6)
    net_xml=$(mktemp)
    cat > "$net_xml" << NETXML
<network>
  <name>${NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='xcibr${BRIDGE_ID}' stp='on' delay='0'/>
  <ip address='${NET_SUBNET}.254' netmask='255.255.255.0'>
  </ip>
</network>
NETXML
    virsh net-define "$net_xml" >&2
    virsh net-start "$NET_NAME" >&2
    rm -f "$net_xml"
    log "Network $NET_NAME created (${NET_SUBNET}.0/24, no DHCP — xCAT owns DHCP)"
}

create_mn_vm() {
    local base_img ci_dir ci_iso

    base_img=$(ensure_cloud_image)
    log "Creating MN disk from $base_img"
    qemu-img create -f qcow2 -b "$base_img" -F qcow2 "$VM_DISK" "$MN_DISK_SIZE" >&2

    ci_dir="$STATE_DIR/${MN_NAME}-ci"
    mkdir -p "$ci_dir"

    cat > "$ci_dir/user-data" << USERDATA
#cloud-config
hostname: ${MN_NAME}
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

$(if [[ "$OS_FAMILY" == "el" ]]; then
cat << 'EL_BLOCK'
packages:
  - epel-release

runcmd:
  - sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
  - setenforce 0 || true
  - dnf config-manager --set-enabled crb 2>/dev/null || true
  - touch /var/lib/cloud-init-done
EL_BLOCK
else
cat << 'UBUNTU_BLOCK'
runcmd:
  - touch /var/lib/cloud-init-done
UBUNTU_BLOCK
fi)
USERDATA

    cat > "$ci_dir/meta-data" << METADATA
instance-id: ${MN_NAME}
local-hostname: ${MN_NAME}
METADATA

    if [[ "$OS_FAMILY" == "ubuntu" ]]; then
        cat > "$ci_dir/network-config" << NETCFG
version: 2
ethernets:
  id0:
    match:
      name: "e*"
    addresses:
      - ${MN_IP}/24
    routes:
      - to: 0.0.0.0/0
        via: ${NET_SUBNET}.254
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
NETCFG
    else
        cat > "$ci_dir/network-config" << NETCFG
version: 2
ethernets:
  eth0:
    addresses:
      - ${MN_IP}/24
    routes:
      - to: 0.0.0.0/0
        via: ${NET_SUBNET}.254
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
NETCFG
    fi

    ci_iso="$STATE_DIR/${MN_NAME}-cidata.iso"
    if command -v genisoimage &>/dev/null; then
        genisoimage -output "$ci_iso" -volid cidata -joliet -rock \
            "$ci_dir/user-data" "$ci_dir/meta-data" "$ci_dir/network-config" 2>/dev/null
    elif command -v mkisofs &>/dev/null; then
        mkisofs -output "$ci_iso" -volid cidata -joliet -rock \
            "$ci_dir/user-data" "$ci_dir/meta-data" "$ci_dir/network-config" 2>/dev/null
    else
        die "No ISO creation tool found"
    fi

    local machine_type
    [[ "$ARCH" == "ppc64le" ]] && machine_type="pseries" || machine_type="q35"

    log "Creating MN VM $MN_NAME"
    virt-install \
        --connect qemu:///system \
        --name "$MN_NAME" \
        --memory "$MN_MEMORY" \
        --vcpus "$MN_VCPUS" \
        --cpu host-passthrough \
        --machine "$machine_type" \
        --import \
        --disk "$VM_DISK" \
        --disk "$ci_iso,device=cdrom" \
        --network network="$NET_NAME" \
        --osinfo name=$([[ "$OS_FAMILY" == "ubuntu" ]] && echo "ubuntu22.04" || echo "rocky9") \
        --noautoconsole \
        --noreboot >&2

    state_add "$MN_NAME"
    state_add "net:$NET_NAME"

    virsh start "$MN_NAME" >&2
    log "MN VM $MN_NAME started"
}

wait_for_ssh() {
    log "Waiting for MN SSH at $MN_IP (up to 300s)..."
    local elapsed=0
    while [[ $elapsed -lt 300 ]]; do
        if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
               -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
               root@"$MN_IP" 'true' 2>/dev/null; then
            log "MN SSH ready at $MN_IP"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    die "Timed out waiting for SSH on $MN_NAME at $MN_IP"
}

main() {
    state_init
    create_network
    create_mn_vm
    wait_for_ssh

    # Print MN_IP to stdout (only stdout output)
    echo "$MN_IP"
}

main "$@"
