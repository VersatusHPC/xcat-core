#!/bin/bash
#
# ci/cluster-test.sh <os> <cluster>   (e.g. alma10 xcat01-mn)
#
# Runs on the xcat-master JNLP agent (the persistent top-level xCAT MN).
# FULL daily, no shortcuts. The hierarchical cluster is provisioned the EL8 way:
# a real default.conf (alma10-cluster.conf, sibling of this script) is applied by
# xcattest, which `chdef`s the SN/CN with full VM attributes; the daily bundle then
# provisions them via its own cases (setup_vm -> mkvm; SN_setup_case -> copycds +
# makedhcp/makedns/makeconservercf + install service node; reg_linux_*_hierarchy ->
# install the compute node diskless/squashfs/diskful through the SN).
#
#   1. (re)provision the cluster MN (xcat01-mn) with the target OS from the fresh el10 repo
#   2. install xCAT + xCAT-test on the MN and make it a functional xCAT master
#   3. stage the alma10-cluster.conf (default.conf) + the OS ISO onto the MN
#   4. run the FULL xCAT-test daily bundle: xcattest -f <conf> -b alma10_x86_daily.bundle
#   5. emit JUnit + raw results for Jenkins (junit/archiveArtifacts in the Jenkinsfile)
#
# Self-contained: installs its own tools and configures repos/keys; no manual host fixes.
# Note: no `-u` — sourcing /etc/profile.d/xcat.sh references unset vars.
set -eo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OS="${1:-alma10}"
CLUSTER="${2:-xcat01-mn}"

OSIMAGE="${XCAT_OSIMAGE:-alma10.1-x86_64-install-compute}"   # image for the MN-under-test (outer layer)
BUNDLE="${XCAT_BUNDLE:-${OS}_x86_daily.bundle}"
CONF_SRC="${XCAT_CLUSTER_CONF:-$SCRIPT_DIR/alma10-cluster.conf}"
SHARE="${XCAT_SHARE:-/opt/xcat-ci-shared}"
BRANCH="${XCAT_BRANCH:-feat/migrate-ci}"
ELDIR="${XCAT_ELDIR:-el10}"
REPO="$SHARE/build/${BRANCH}/dnf/${ELDIR}"
DEPREPO="${XCAT_DEPREPO:-$SHARE/xcat-dep/${ELDIR}/x86_64}"
MASTER_IP="${XCAT_MASTER_IP:-192.168.201.12}"   # this agent (top MN) on the cluster net
NODE_IP="${XCAT_NODE_IP:-192.168.201.20}"       # the MN-under-test (xcat01-mn)
VMHOST_SSH="${XCAT_VMHOST_SSH:-root@192.168.122.1}"  # rome01 (power-cycle + key install)
VMHOST="${XCAT_VMHOST:-192.168.201.1}"          # rome01 on the cluster net (libvirt host for sn/cn)
SHARE_SSH="${XCAT_SHARE_SSH:-root@192.168.122.1}"    # host that owns the NFS mount (agent can't mount it)
REPO_SRC="${XCAT_REPO_SRC:-${SHARE_SSH}:${REPO}/}"
DEP_SRC="${XCAT_DEP_SRC:-${SHARE_SSH}:${DEPREPO}/}"
RESULTS_DST="${XCAT_RESULTS_DST:-${SHARE_SSH}:${SHARE}/tests/${BRANCH}}"
ISO_SRC="${XCAT_ISO_SRC:-/install/jenkins/iso/AlmaLinux-10-latest-x86_64-dvd.iso}"  # on this agent
ISO_MN="/root/iso/$(basename "$ISO_SRC")"       # where the ISO lands on the MN (for $$ISO/copycds)
RUNID="${BUILD_NUMBER:-manual-$$}"
NSSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no"
SCP="scp -o BatchMode=yes -o StrictHostKeyChecking=no"
RSH=(-e "ssh -o BatchMode=yes -o StrictHostKeyChecking=no")

set +e; . /etc/profile.d/xcat.sh; set -e
command -v python3 >/dev/null 2>&1 || dnf -y install python3 >/dev/null 2>&1 || true
rm -rf reports && mkdir -p reports/junit reports/raw

echo "[cluster-test] FULL run: os=$OS cluster=$CLUSTER osimage=$OSIMAGE bundle=$BUNDLE conf=$CONF_SRC"
test -s "$CONF_SRC" || { echo "[cluster-test] FATAL: cluster conf not found: $CONF_SRC" >&2; exit 1; }

# 1. pull the fresh el10 core repo + el10 xcat-dep repo (via the mount-owning host) into the top
#    MN's HTTP tree, so the MN-under-test can install xCAT (core + deps: goconserver, xnba-undi,
#    syslinux-xcat, elilo-xcat, ipmitool-xcat, perl-IO-Stty, perl-Sys-Virt, ...).
mkdir -p /install/post/repos/xcat-core /install/post/repos/xcat-dep
rsync -a --delete "${RSH[@]}" "$REPO_SRC" /install/post/repos/xcat-core/
rsync -a --delete "${RSH[@]}" "$DEP_SRC" /install/post/repos/xcat-dep/

# 2. (re)provision the MN-under-test from scratch (always; no skip).
#    The MN is a transient kvm domain and this top MN's rpower off/reset is unreliable on the
#    el10 Sys::Virt here. So: if the domain is running, reboot it in place via the host (virsh
#    reset -> fresh PXE for reinstall); if it is down, (re)create+boot it via xCAT rpower on.
nodeset "$CLUSTER" osimage="$OSIMAGE"
makedhcp -n || true; makedhcp -a || true
if $NSSH "$VMHOST_SSH" "virsh -c qemu:///system domstate $CLUSTER 2>/dev/null" | grep -q running; then
  $NSSH "$VMHOST_SSH" "virsh -c qemu:///system reset $CLUSTER"
else
  rpower "$CLUSTER" on
fi

# 3. wait for the MN to be FULLY booted (~up to 45 min for a fresh install).
#    Not just "sshd answers": during early boot pam_nologin resets connections and breaks the
#    heavy SSH work below. Require boot complete (systemctl is-system-running running|degraded)
#    and no /run/nologin, then settle briefly.
UP=0
for i in $(seq 1 90); do
  if timeout 10 $NSSH "root@$NODE_IP" '! test -e /run/nologin && systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"' >/dev/null 2>&1; then UP=1; break; fi
  sleep 30
done
[ "$UP" = 1 ] || { echo "[cluster-test] FATAL: $CLUSTER did not fully boot" >&2; exit 1; }
sleep 10
echo "[cluster-test] $CLUSTER up: $($NSSH root@$NODE_IP 'cat /etc/os-release|grep PRETTY_NAME')"

# 4. stage the OS ISO onto the MN (the cluster conf's $$ISO; SN_setup_case/hierarchy run copycds)
if [ -f "$ISO_SRC" ]; then
  $NSSH "root@$NODE_IP" 'mkdir -p /root/iso'
  rsync -a "${RSH[@]}" "$ISO_SRC" "root@$NODE_IP:/root/iso/"
else
  echo "[cluster-test] FATAL: OS ISO not found on agent: $ISO_SRC (needed for copycds \$\$ISO)" >&2
  exit 1
fi

# 5. give the MN root SSH to the libvirt host (vmhost) so setup_vm's mkvm can build sn/cn
MN_PUBKEY=$($NSSH "root@$NODE_IP" 'test -f /root/.ssh/id_rsa.pub || ssh-keygen -q -t rsa -N "" -f /root/.ssh/id_rsa; cat /root/.ssh/id_rsa.pub')
$NSSH "$VMHOST_SSH" "mkdir -p /root/.ssh; grep -qF '$MN_PUBKEY' /root/.ssh/authorized_keys 2>/dev/null || echo '$MN_PUBKEY' >> /root/.ssh/authorized_keys"
$NSSH "root@$NODE_IP" "printf 'Host %s\n  StrictHostKeyChecking accept-new\n' '$VMHOST' > /root/.ssh/config; chmod 600 /root/.ssh/config"

# 6. make the MN a functional xCAT master for the inner cluster.
#    The sn/cn node definitions + their VMs + dns/dhcp/conserver are created by the bundle's
#    own cases: xcattest applies alma10-cluster.conf (chdef xcat01-sn/cn with vmhost/vmnics/ip),
#    setup_vm runs mkvm, and SN_setup_case / reg_linux_*_hierarchy run copycds + makedhcp +
#    makedns + makeconservercf + nodeset + install. So here we only stand up the master itself.
$NSSH "root@$NODE_IP" NODE_IP="$NODE_IP" MASTER_IP="$MASTER_IP" bash -s <<'NODE'
set -e
cat > /etc/yum.repos.d/xcat-core.repo <<EOF
[xcat-core]
name=xcat-core
baseurl=http://${MASTER_IP}/install/post/repos/xcat-core
enabled=1
gpgcheck=0
EOF
cat > /etc/yum.repos.d/xcat-dep.repo <<EOF
[xcat-dep]
name=xcat-dep
baseurl=http://${MASTER_IP}/install/post/repos/xcat-dep
enabled=1
gpgcheck=0
EOF
dnf -y install epel-release >/dev/null 2>&1 || true
dnf config-manager --set-enabled crb 2>/dev/null || dnf config-manager --enable crb 2>/dev/null || true
# xcat-core rpms are deterministically versioned (snap000000000000): the same NVR can hold
# different content across builds, so any cached copy must be purged or dnf hits a checksum
# mismatch against the fresh repodata.
dnf clean all || true
dnf -y install xCAT xCAT-test createrepo_c expect perl-Getopt-Long perl-Data-Dumper perl-Sys-Virt \
  || dnf -y install xCAT xCAT-test
set +e; . /etc/profile.d/xcat.sh; set -e
xcatconfig -i || true
# detect the cluster NIC (the one holding NODE_IP) so dhcpd serves sn/cn on it
MNNIC=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '$4 ~ ip"/"{print $2; exit}')
chdef -t site master=${NODE_IP} domain=xcat.versatushpc.com.br nameservers=${NODE_IP} \
  dhcpinterfaces="${MNNIC:-eth1}" forwarders=1.1.1.1 2>&1 | tail -1 || true
makenetworks || true
# root password for kickstart (CRYPT macro reads this); also set by the conf's [Table_passwd]
tabch key=system passwd.username=root passwd.password=cluster 2>/dev/null || \
  chtab key=system passwd.username=root passwd.password=cluster
echo "MN master ready:"; lsdef -t site -i master,domain,dhcpinterfaces 2>/dev/null | tail -4 || true
NODE

# 6b. stage the cluster conf (default.conf) on the MN, substituting @ISO@ with the staged ISO.
#     No `|| true`: if this fails the stage fails (no false pass).
CONF=/opt/xcat/share/xcat/tools/autotest/jenkins-cluster.conf
sed "s|@ISO@|${ISO_MN}|g" "$CONF_SRC" > /tmp/jenkins-cluster.conf
$NSSH "root@$NODE_IP" "mkdir -p /opt/xcat/share/xcat/tools/autotest"
$SCP /tmp/jenkins-cluster.conf "root@$NODE_IP:$CONF"
$NSSH "root@$NODE_IP" "test -s $CONF && grep -q '\[Object_node\]' $CONF && echo CONF_OK \$(wc -l < $CONF) lines"

# 7. run the FULL daily bundle on the MN-under-test (no shortcuts), through the cluster conf.
#    Plain `-f` (no :System) => xcattest chdef's the sn/cn from the conf, then runs the bundle
#    (setup_vm -> mkvm; SN_setup_case + reg_linux_*_hierarchy -> install the sn then the cn).
echo "[cluster-test] running FULL: xcattest -f $CONF -b ${BUNDLE}"
# tee xcattest stdout: it carries the "Miss attribute:" / "To run:" report that the
# result/ logs and JUnit pass-fail counters do NOT capture. The step-9 silent-skip
# guard scans this to catch a dropped required install case (see SN_setup_case).
$NSSH "root@$NODE_IP" \
  ". /etc/profile.d/xcat.sh; cd /opt/xcat/share/xcat/tools/autotest && rm -rf result/* && \
   /opt/xcat/bin/xcattest -f $CONF -b '${BUNDLE}'" 2>&1 | tee reports/raw/xcattest-console.log || true

# 7b. Kea diagnostics dump (non-fatal): make the EL10/Kea DHCP state visible in
#     the build log + archived artifacts so future Kea issues need no MN SSH.
echo "[cluster-test] dumping Kea DHCP diagnostics from the MN"
mkdir -p reports/raw
$NSSH "root@$NODE_IP" '
  echo "===== systemctl status kea-dhcp4 kea-dhcp-ddns =====";
  systemctl --no-pager status kea-dhcp4 kea-dhcp-ddns 2>&1;
  echo "===== systemctl is-active =====";
  systemctl is-active kea-dhcp4 kea-dhcp-ddns 2>&1;
  echo "===== ss -ulnp sport = :67 =====";
  ss -ulnp "sport = :67" 2>&1;
  echo "===== journalctl -u kea-dhcp4 -u kea-dhcp-ddns (last 200) =====";
  journalctl -u kea-dhcp4 -u kea-dhcp-ddns --no-pager -n 200 2>&1;
  echo "===== /etc/kea/kea-dhcp4.conf =====";
  cat /etc/kea/kea-dhcp4.conf 2>&1;
  echo "===== /etc/kea/kea-dhcp-ddns.conf =====";
  cat /etc/kea/kea-dhcp-ddns.conf 2>&1;
  echo "===== kea-dhcp4 -t =====";
  kea-dhcp4 -t /etc/kea/kea-dhcp4.conf 2>&1;
  echo "===== kea-dhcp-ddns -t =====";
  kea-dhcp-ddns -t /etc/kea/kea-dhcp-ddns.conf 2>&1;
' 2>&1 | tee reports/raw/kea-diagnostics.txt || true

# 8. collect raw results, convert to JUnit, push to the shared tests area
$SCP -r "root@$NODE_IP:/opt/xcat/share/xcat/tools/autotest/result/*" reports/raw/ 2>/dev/null || true
"$SCRIPT_DIR/xcattest-junit.sh" reports/raw "reports/junit/${OS}.xml" || true
$NSSH "$SHARE_SSH" "mkdir -p '${SHARE}/tests/${BRANCH}/${RUNID}'" 2>/dev/null || true
rsync -a "${RSH[@]}" reports/ "${RESULTS_DST}/${RUNID}/" 2>/dev/null || true
echo "[cluster-test] results -> ${RESULTS_DST}/${RUNID}/"

# 9. guards (no false pass): the bundle must actually have run cases, and none may fail.
TESTS=$(grep -oE 'tests="[0-9]+"' "reports/junit/${OS}.xml" 2>/dev/null | grep -oE '[0-9]+' | head -1)
TESTS="${TESTS:-0}"
echo "[cluster-test] xcattest reported ${TESTS} cases"

# 9a. guard against SILENT SKIPS of required install cases (run before the counters).
#     A case xcattest drops for a missing $$attribute (or any other reason) emits NO
#     ------END:: marker, so the pass/fail counters below are blind to it -- exactly how
#     the alma10 SN_setup_case / PYTHON_DEP_* gap let "the service node never installed"
#     masquerade as a partial run. Fail loudly and name the cause.
REQUIRED_CASES="${XCAT_REQUIRED_CASES:-SN_setup_case reg_linux_diskfull_installation_hierarchy}"
CONSOLE=reports/raw/xcattest-console.log
skip_fail=0
for rc in $REQUIRED_CASES; do
  if [ -f "$CONSOLE" ] && grep -qE "(^|[[:space:]])${rc}[[:space:]]+miss attribute" "$CONSOLE"; then
    attr=$(sed -nE "s/.*${rc}[[:space:]]+miss attribute[[:space:]]+([A-Za-z0-9_]+).*/\1/p" "$CONSOLE" | head -1)
    echo "[cluster-test] FAILURE: required case ${rc} was SKIPPED (miss attribute ${attr:-?}) -- node not provisioned; define it in the cluster conf [System]"
    skip_fail=1
  elif ! grep -rqE "END::${rc}::" reports/raw/ 2>/dev/null; then
    echo "[cluster-test] FAILURE: required case ${rc} produced no result (did not run) -- bundle/harness problem, not a pass"
    skip_fail=1
  fi
done
[ "$skip_fail" = 0 ] || exit 1

if [ "$TESTS" -eq 0 ]; then
  echo "[cluster-test] FAILURE: xcattest ran 0 cases (harness/setup problem, not a real pass)"; exit 1
fi
if grep -q 'failures="[1-9]' "reports/junit/${OS}.xml" 2>/dev/null; then
  echo "[cluster-test] some xcattest cases failed (see JUnit)"; exit 1
fi
echo "[cluster-test] all ${TESTS} reported cases passed"
