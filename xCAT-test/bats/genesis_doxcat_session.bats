#!/usr/bin/env bats
#
# Drive xcat_doxcat_session() out of the el Genesis dracut cmdline hook with tmux shadowed.
# The hook cannot be sourced: it mounts filesystems, starts udev and ends in an endless loop.

load 'helpers/shell_source'

setup()
{
    EL_HOOK="$(require_repo_file 'xCAT-genesis-base/dracut_105/el/xcat-cmdline.sh')"
    TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
    export EL_HOOK TMUX_LOG
}

# $1 is 1 when the session doxcat already exists. The stub answers the way tmux 3.4 does.
run_session()
{
    local exists="$1" body
    body="$(extract_shell_function "$EL_HOOK" xcat_doxcat_session)" ||
        { echo "xcat_doxcat_session() not found in $EL_HOOK" >&2; return 99; }
    (
        eval "$body"
        tmux() {
            echo "$*" >> "$TMUX_LOG"
            case "$1" in
            attach-session)
                [ "$exists" = 1 ] && return 0
                echo "can't find session: doxcat" >&2
                return 1
                ;;
            new-session)
                if [ "$exists" = 1 ] && [ "$2" = -A ]; then
                    return 0
                fi
                echo "started ${*: -1}"
                ;;
            esac
        }
        xcat_doxcat_session
    ) 2>&1
}

@test "the first pass starts doxcat and writes no tmux error to the console" {
    run run_session 0
    [ "$status" -eq 0 ]
    [ "$output" = "started doxcat" ]
}

@test "a pass with the session present attaches and starts no second doxcat" {
    run run_session 1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
