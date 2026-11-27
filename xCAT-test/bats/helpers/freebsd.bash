# Shared setup for the FreeBSD installer shell tests.

load 'helpers/shell_source'

freebsd_installer_dir()
{
    printf '%s\n' "${XCAT_FREEBSD_INSTALLER_DIR:-$(repo_path 'xCAT-server/share/xcat/install/freebsd')}"
}

# Write an executable stub. The body is read from standard input.
freebsd_stub()
{
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat >"$path"
    chmod 0755 "$path"
}
