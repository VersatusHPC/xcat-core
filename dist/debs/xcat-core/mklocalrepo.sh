. /etc/lsb-release
cd `dirname $0`
host_arch=`uname -m`
case "$host_arch" in
    ppc64le) host_arch="ppc64el" ;;
    riscv64) host_arch="riscv64" ;;
    *)       host_arch="amd64" ;;
esac
echo deb [arch=$host_arch] file://"`pwd`" $DISTRIB_CODENAME main > /etc/apt/sources.list.d/xcat-core.list
