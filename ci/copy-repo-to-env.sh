#!/usr/bin/env bash
#
# ci/copy-repo-to-env.sh — Copy xcat-core + xcat-dep to MN, install xCAT
#
set -euo pipefail

STATE_DIR="/var/lib/xcat3-ci"
SSH_KEY="$STATE_DIR/ci-ssh-key"
XCAT_DEP_PATH="${XCAT_DEP_PATH:-/opt/xcat-dep}"
ARCH="$(uname -m)"
RELEASEVER=""
REPO_PATH=""
MN_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-path)      REPO_PATH="$2"; shift 2 ;;
        --mn-ip)          MN_IP="$2"; shift 2 ;;
        --releasever)     RELEASEVER="$2"; shift 2 ;;
        --xcat-dep-path)  XCAT_DEP_PATH="$2"; shift 2 ;;
        *)                echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$REPO_PATH" ]] && { echo "ERROR: --repo-path required" >&2; exit 1; }
[[ -z "$MN_IP" ]] && { echo "ERROR: --mn-ip required" >&2; exit 1; }
[[ -z "$RELEASEVER" ]] && RELEASEVER=$(rpm --eval '%{rhel}' 2>/dev/null || echo "9")

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [copy-repo] $*" >&2; }

ssh_cmd() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}

log "Waiting for cloud-init on MN..."
ssh_cmd root@"$MN_IP" 'timeout 300 bash -c "while [ ! -f /var/lib/cloud-init-done ]; do sleep 5; done"'

log "Copying xcat-core repo ($REPO_PATH) to MN"
ssh_cmd root@"$MN_IP" 'mkdir -p /opt/xcat-core-repo'
tar -C "$REPO_PATH" -cf - . | ssh_cmd root@"$MN_IP" 'tar -C /opt/xcat-core-repo -xf -'

DEP_DIR="$XCAT_DEP_PATH/el${RELEASEVER}/${ARCH}"
if [[ -d "$DEP_DIR" ]]; then
    log "Copying xcat-dep ($DEP_DIR) to MN"
    ssh_cmd root@"$MN_IP" 'mkdir -p /opt/xcat-dep'
    tar -C "$DEP_DIR" -cf - . | ssh_cmd root@"$MN_IP" 'tar -C /opt/xcat-dep -xf -'
else
    log "WARNING: xcat-dep not found at $DEP_DIR"
fi

log "Creating repo metadata on MN"
ssh_cmd root@"$MN_IP" bash << 'REMOTE'
set -euo pipefail
dnf install -y createrepo_c 2>&1 | tail -3
createrepo /opt/xcat-core-repo/
[[ -d /opt/xcat-dep ]] && createrepo /opt/xcat-dep/ || true
REMOTE

log "Configuring repos on MN"
ssh_cmd root@"$MN_IP" bash << 'REMOTE'
set -euo pipefail
cat > /etc/yum.repos.d/xcat-ci.repo << 'REPO'
[xcat-core-ci]
name=xCAT Core CI Build
baseurl=file:///opt/xcat-core-repo/
gpgcheck=0
enabled=1

[xcat-dep-ci]
name=xCAT Dependencies CI
baseurl=file:///opt/xcat-dep/
gpgcheck=0
enabled=1
REPO

dnf config-manager --set-enabled crb 2>/dev/null || true
dnf makecache || true
REMOTE

log "Installing xCAT packages"
ssh_cmd root@"$MN_IP" bash << 'REMOTE'
set -euo pipefail
dnf install -y --skip-broken perl-xCAT xCAT-server xCAT-client xCAT-test 2>&1 | tail -20

rpm -q perl-xCAT || { echo "FAIL: perl-xCAT not installed"; exit 1; }
rpm -q xCAT-client || { echo "FAIL: xCAT-client not installed"; exit 1; }
REMOTE

log "Configuring xCAT"
ssh_cmd root@"$MN_IP" bash -s "$MN_IP" << 'REMOTE'
set -euo pipefail
MN_IP="$1"
MN_SUBNET=$(echo "$MN_IP" | sed 's/\.[0-9]*$//')
export XCATROOT=/opt/xcat
export PATH="$XCATROOT/bin:$XCATROOT/sbin:$XCATROOT/share/xcat/tools:$PATH"
export MANPATH="${XCATROOT}/share/man:${MANPATH:-}"
export PERL5LIB="$XCATROOT/lib/perl:${PERL5LIB:-}"

if rpm -q xCAT-server > /dev/null 2>&1; then
    echo "Configuring xCAT site and network..."
    systemctl start xcatd || true
    sleep 5

    # Basic site config
    chtab key=timezone site.value="UTC" 2>/dev/null || true
    chtab key=domain site.value="xcat-ci.local" 2>/dev/null || true

    # Network definition for test subnet
    NET_NAME=$(echo "${MN_SUBNET}.0" | tr '.' '_')-255_255_255_0
    chdef -t network "$NET_NAME" \
        net="${MN_SUBNET}.0" mask=255.255.255.0 \
        gateway="$MN_IP" 2>/dev/null || true

    # Root password for compute nodes
    chtab key=system passwd.username=root passwd.password="xcat3ci" 2>/dev/null || true

    systemctl is-active xcatd || { echo "WARN: xcatd not running"; }
    echo "xCAT configured"
else
    echo "WARN: xCAT-server not installed, skipping xcatd config"
fi
REMOTE

log "MN setup complete"
