#!/bin/bash
#
# The Slurm steps of the OpenHPC cases, with a bound on each wait.
#
#   slurm_job.sh wait_idle <node>       wait until Slurm reports <node> idle
#   slurm_job.sh run_job <partition>    run hostname on one node of <partition>
#
# srun waits for a node with no limit. When the node is not idle, srun blocks until the case
# timeout kills the whole case, and the case reports nothing about the cause.

# Overridable so a test can drive the functions without waiting.
SLURM_IDLE_TRIES=${SLURM_IDLE_TRIES:-60}
SLURM_IDLE_SLEEP=${SLURM_IDLE_SLEEP:-5}
SRUN_TIMEOUT=${SRUN_TIMEOUT:-120}
SRUN_IMMEDIATE=${SRUN_IMMEDIATE:-60}

#--- wait_node_idle
# Descriptions: wait until Slurm reports the node idle.
#   slurmd registers some seconds after the node boots, so ask more than once.
# Arguments: $1 - the node
# Returns: 0 and prints "idle"; or 1 and prints the last state the node had
#---
wait_node_idle() {
    local node=$1
    local state=
    local i
    for (( i = 1; i <= SLURM_IDLE_TRIES; ++i )); do
        state=$(sinfo -h -o %T -n "$node")
        if [ "$state" = idle ]; then
            echo idle
            return 0
        fi
        if [ "$i" -lt "$SLURM_IDLE_TRIES" ]; then
            sleep "$SLURM_IDLE_SLEEP"
        fi
    done
    echo "Slurm reports $node as '$state' after $SLURM_IDLE_TRIES tries $SLURM_IDLE_SLEEP sec apart, not idle. srun is not started."
    return 1
}

#--- run_job
# Descriptions: run hostname on one node of the partition, with a time limit.
#   --immediate makes srun give up when no node is free. timeout stops an srun that still hangs.
# Arguments: $1 - the partition
# Returns: the srun exit code; 124 when timeout stopped srun
#---
run_job() {
    local partition=$1
    local rc
    timeout "$SRUN_TIMEOUT" srun --immediate="$SRUN_IMMEDIATE" -N1 -p "$partition" --chdir=/tmp hostname
    rc=$?
    if [ "$rc" -eq 124 ]; then
        echo "srun did not finish in $SRUN_TIMEOUT sec"
    fi
    return "$rc"
}

# Sourcing stops here, so a bats test can drive the functions.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

case "$1" in
    wait_idle) wait_node_idle "$2" ;;
    run_job)   run_job "$2" ;;
    *)
        echo "usage: $0 wait_idle <node> | run_job <partition>" >&2
        exit 2
        ;;
esac
