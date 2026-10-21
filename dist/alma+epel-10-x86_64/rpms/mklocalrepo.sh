#!/bin/sh
cd `dirname $0`
REPOFILE=`basename xcat-*.repo`
if [[ $REPOFILE == "xcat-*.repo" ]]; then
    echo "ERROR: For xcat-dep, please execute $0 in the correct <os>/<arch> subdirectory"
    exit 1
fi
#
# default to RHEL yum, if doesn't exist try Zypper
#
DIRECTORY="/etc/yum.repos.d"
if [ ! -d "$DIRECTORY" ]; then
    DIRECTORY="/etc/zypp/repos.d"
fi
sed -e 's|baseurl=.*|baseurl=file://'"`pwd`"'|' $REPOFILE | sed -e 's|gpgkey=.*|gpgkey=file://'"`pwd`"'/repodata/repomd.xml.key|' > "$DIRECTORY/$REPOFILE"
if [ -f "$DIRECTORY/xCAT-core.repo" ]; then
    mv "$DIRECTORY/xCAT-core.repo" "$DIRECTORY/xCAT-core.repo.nouse"
fi
cd -
