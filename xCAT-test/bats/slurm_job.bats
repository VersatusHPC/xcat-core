#!/usr/bin/env bats
#
# slurm_job.sh bounds the two Slurm waits of the OpenHPC cases. Without a bound, a compute node
# that never turns idle makes srun block until the case timeout stops the whole case.
# sinfo, sleep and srun are stubs: what matters is how long the functions wait and what they say.

bats_require_minimum_version 1.5.0

load 'helpers/shell_source'

NODE=cn01

setup()
{
    SCRIPT="$(repo_path 'xCAT-test/autotest/testcase/commoncmd/slurm_job.sh')"
    BIN="${BATS_TEST_TMPDIR}/bin"
    CALLS="${BATS_TEST_TMPDIR}/calls"
    mkdir -p "$BIN"
    : >"$CALLS"
    export CALLS
    export SLURM_IDLE_TRIES=4 SLURM_IDLE_SLEEP=0
}

# Replaces sinfo. Answers $1 for the first $2 calls, then idle. A negative count never says idle.
stub_sinfo()
{
    STATE="$1"
    NOT_IDLE_CALLS="$2"
    sinfo()
    {
        local n
        n=$(( $(read_file_or_empty "$CALLS" | wc -l) + 1 ))
        echo "sinfo $*" >>"$CALLS"
        if [ "$NOT_IDLE_CALLS" -lt 0 ] || [ "$n" -le "$NOT_IDLE_CALLS" ]; then
            echo "$STATE"
        else
            echo idle
        fi
    }
}

# Replaces srun. timeout starts an executable, so this stub is a file in PATH.
stub_srun()
{
    printf '#!/bin/bash\necho "srun $*" >>"$CALLS"\n%s\n' "$1" >"$BIN/srun"
    chmod +x "$BIN/srun"
    PATH="$BIN:$PATH"
}

@test "a node that turns idle after some tries is reported idle" {
    source "$SCRIPT"
    stub_sinfo 'down*' 2
    run wait_node_idle "$NODE"
    [ "$status" -eq 0 ]
    [ "$output" = idle ]
    [ "$(grep -c '^sinfo' "$CALLS")" -eq 3 ]
}

@test "a node that never turns idle fails after the last try and names its state" {
    source "$SCRIPT"
    stub_sinfo 'down*' -1
    run wait_node_idle "$NODE"
    [ "$status" -eq 1 ]
    [ "$(grep -c '^sinfo' "$CALLS")" -eq 4 ]
    [[ "$output" == *"Slurm reports $NODE as 'down*'"* ]]
    [[ "$output" != idle ]]
}

@test "an srun that hangs is stopped at SRUN_TIMEOUT" {
    source "$SCRIPT"
    stub_srun 'exec sleep 60'
    SRUN_TIMEOUT=1
    SECONDS=0
    run run_job compute
    [ "$status" -eq 124 ]
    [ "$SECONDS" -lt 30 ]
    [[ "$output" == *"srun did not finish in 1 sec"* ]]
}

@test "srun gives up when no node is free" {
    source "$SCRIPT"
    stub_srun "echo $NODE"
    run run_job compute
    [ "$status" -eq 0 ]
    [ "$output" = "$NODE" ]
    grep -q -- '--immediate=60 -N1 -p compute' "$CALLS"
}
