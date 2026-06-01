#!/bin/bash
#
# ci/build-rpm.sh <target> <arch>   (e.g. el10 x86_64)
#
# Builds all xcat-core RPMs (incl. xCATsn) on the dedicated xcat-build VM via
# buildrpms.pl, GPG-signs them, and publishes the signed dnf repo to the shared
# NFS area. The xcat-core working tree is read from $XCAT_SRC (the product repo
# checked out by the Jenkinsfile, e.g. $WORKSPACE/xcat-core); defaults to $PWD
# for local runs.
#
# This wraps the validated build-VM flow (see xcat-skills/xcat-core-build).
# Public package publishing is NOT done here (Pulp/Phase 6 owns that); the repo
# under /opt/xcat-ci-shared is a local test repo consumed by cluster-test.sh.
set -euo pipefail

TARGET="${1:-el10}"
ARCH="${2:-x86_64}"

case "$TARGET" in
  el10) MOCK="alma+epel-10-${ARCH}"; ELDIR="el10" ;;
  el9)  MOCK="alma+epel-9-${ARCH}";  ELDIR="el9"  ;;
  *) echo "build-rpm.sh: unknown target '$TARGET'" >&2; exit 2 ;;
esac

# Read the xcat-core checkout from XCAT_SRC (Jenkinsfile sets it to $WORKSPACE/xcat-core);
# fall back to the current directory for local invocations.
XCAT_SRC="${XCAT_SRC:-$PWD}"
cd "$XCAT_SRC"

BUILD_HOST="${XCAT_BUILD_HOST:-xcat-build}"                       # ssh alias for the build VM
SSH_CONFIG="${XCAT_SSH_CONFIG:-$HOME/.ssh/config}"
GPG_HOME="${XCAT_GPG_HOME:-/opt/xcat-ci-shared/keys/xcat-gpg-home}"
SHARE="${XCAT_SHARE:-/opt/xcat-ci-shared}"
BRANCH="${XCAT_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo feat/migrate-ci)}"
PUBDIR="$SHARE/build/${BRANCH}/dnf/${ELDIR}"
SSH=(ssh -F "$SSH_CONFIG" "$BUILD_HOST")

echo "[build-rpm] src=$XCAT_SRC target=$TARGET arch=$ARCH mock=$MOCK branch=$BRANCH -> $PUBDIR"

# workspace .git may be owned by a different uid (rsync'd in); allow git to use it
git config --global --add safe.directory "$XCAT_SRC" 2>/dev/null || true

# 1. deterministic build metadata (consumed by buildrpms.pl for SOURCE_DATE_EPOCH)
git rev-parse HEAD > Gitinfo
git log -1 --format=%ct HEAD > Gitepoch

# 2. sync working tree (tracked + the alma10/xCATsn untracked assets) to the build VM
{ git ls-files; \
  git ls-files --others --exclude-standard -- xCAT-server xCAT-test xCAT perl-xCAT xCATsn; } \
  | sort -u > /tmp/xcat-build-filelist.txt
rsync -a --files-from=/tmp/xcat-build-filelist.txt -e "ssh -F $SSH_CONFIG" ./ "$BUILD_HOST:/root/xcat-core/"
rsync -a -e "ssh -F $SSH_CONFIG" Gitinfo Gitepoch "$BUILD_HOST:/root/xcat-core/"

# 3. build + sign ALL packages (no --package => full @PACKAGES incl. xCATsn)
"${SSH[@]}" "cd /root/xcat-core && perl buildrpms.pl --target='$MOCK' --force --verbose \
    --gpg-sign --gpg-home '$GPG_HOME'"

# 4. publish the signed repo to the share (consumed by the cluster-test stage)
"${SSH[@]}" "mkdir -p '$PUBDIR' && rsync -a --delete /root/xcat-core/dist/'$MOCK'/rpms/ '$PUBDIR'/"

# 5. sanity: signatures + key present
"${SSH[@]}" "rpm -K '$PUBDIR'/xCAT-server-*.noarch.rpm && ls '$PUBDIR'/repodata/repomd.xml.asc"
echo "[build-rpm] published $(("${SSH[@]}" "ls '$PUBDIR'"/*.rpm 2>/dev/null | grep -vc '\.src\.rpm') ) binary rpms"
