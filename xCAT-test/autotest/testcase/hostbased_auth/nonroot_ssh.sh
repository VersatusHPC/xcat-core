#!/bin/bash
# Drive a non-root ssh login between two nodes, from the MN, for the hostbased_auth cases.
#
# The login must be able to succeed only through host-based authentication:
# - the user has no key pair, no authorized_keys and no ~/.shosts on either node;
# - root's private keys on the source node are moved aside, so ssh-keysign is the only
#   signer there;
# - the client offers hostbased and nothing else, in batch mode, so no password is asked;
# - the client ignores the user's known_hosts, so the target key must come from the global
#   /etc/ssh/ssh_known_hosts.
# Root's private keys on the target node stay in place. In a hierarchical cluster the target
# is the service node, and xdsh to the compute node uses those keys.
#
# The proof of a login is a token that "login" writes on the target node as root and reads
# back through the user's ssh session. A hostname would not do: the check would also match
# the name in the error text.
#
# Usage:
#   nonroot_ssh.sh setup <user> <from> <to>      create the user on both nodes, hide root's keys on <from>
#   nonroot_ssh.sh login <user> <from> <to>      ssh as <user> from <from> to <to>
#   nonroot_ssh.sh cleanup <user> <from> <to>    delete the user, put root's keys back on <from>
#   nonroot_ssh.sh keysign-avc <node>            look for SELinux denials of ssh-keysign on <node>
#
# Prints: HBA-SETUP-OK, HBA-LOGIN-OK or HBA-CLEANUP-OK on success. HBA-LOGIN-BAD when the
#         login did not return the token. HBA-AVC-NONE when the audit log of the last ten
#         minutes holds no AVC record for ssh-keysign or ssh, HBA-AVC-FOUND when it holds one.
# Exits:  0 on success, 1 on a failure, 2 on a usage error.

USER_UID=4711
HIDDEN=/root/.ssh/xcattest-hostbased-hidden

action=$1

# ausearch reads stdin, not the audit log, when stdin is not a terminal, and under xdsh it
# then finds nothing. --input-logs makes it read the log. The USER_LOGIN record of the xdsh
# login itself shows that the search reads the log. ausearch exits 1 both for "no match" and
# for an error, so only "<no matches>" with exit 1 is a clean log. The ssh client reads the
# host keys itself before it starts ssh-keysign, so a denial on that path can name ssh.
if [ "$action" = keysign-avc ]; then
    node=$2
    [ -n "$node" ] || { echo "usage: $0 keysign-avc <node>"; exit 2; }
    out=$(xdsh "$node" "ausearch --input-logs -m USER_LOGIN -ts recent >/dev/null 2>&1; echo HBA-AUDIT-READ=\$?; for c in ssh-keysign ssh; do ausearch --input-logs -m avc -c \$c -ts recent 2>&1; echo HBA-AVC-RC=\$?; done" 2>&1)
    echo "$out"
    if ! echo "$out" | grep -q 'HBA-AUDIT-READ=0$'; then
        echo "HBA-AVC-ERROR: ausearch finds no USER_LOGIN record on $node, so it does not read the audit log"
        exit 1
    fi
    if [ "$(echo "$out" | grep -c 'HBA-AVC-RC=1$')" = 2 ] && [ "$(echo "$out" | grep -cF '<no matches>')" = 2 ]; then
        echo HBA-AVC-NONE
        exit 0
    fi
    if echo "$out" | grep -q 'HBA-AVC-RC=0$'; then
        echo "HBA-AVC-FOUND: SELinux denied ssh-keysign or ssh on $node"
        exit 1
    fi
    echo "HBA-AVC-ERROR: ausearch gave no answer on $node"
    exit 1
fi

user=$2
from=$3
to=$4
if [ -z "$action" ] || [ -z "$user" ] || [ -z "$from" ] || [ -z "$to" ]; then
    echo "usage: $0 setup|login|cleanup <user> <from> <to> | keysign-avc <node>"
    exit 2
fi

case "$action" in
setup)
    xdsh "$from,$to" "getent passwd $user >/dev/null || useradd -m -u $USER_UID -s /bin/bash $user; rm -rf ~$user/.ssh ~$user/.shosts ~$user/.rhosts" || exit 1
    xdsh "$from" "mkdir -p $HIDDEN && for k in /root/.ssh/id_*; do [ -e \"\$k\" ] && mv -f \"\$k\" $HIDDEN/; done; ls /root/.ssh/" || exit 1
    xdsh "$from" "ls /root/.ssh/id_* 2>/dev/null" | grep -q . && { echo "root still has private keys on $from"; exit 1; }
    echo HBA-SETUP-OK
    ;;
login)
    tok="hba-$(date +%s)-$$-$RANDOM"
    xdsh "$to" "echo $tok > /tmp/xcattest-hostbased.token && chmod 644 /tmp/xcattest-hostbased.token" || exit 1
    out=$(xdsh "$from" "su - $user -c 'ssh -o BatchMode=yes -o PreferredAuthentications=hostbased -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 $to cat /tmp/xcattest-hostbased.token'" 2>&1)
    echo "$out"
    xdsh "$to" "rm -f /tmp/xcattest-hostbased.token" >/dev/null 2>&1
    if echo "$out" | grep -q -- "$tok"; then
        echo HBA-LOGIN-OK
        exit 0
    fi
    echo "HBA-LOGIN-BAD: $user could not log in from $from to $to by host-based authentication"
    exit 1
    ;;
cleanup)
    rc=0
    xdsh "$from" "[ -d $HIDDEN ] && mv -f $HIDDEN/* /root/.ssh/ 2>/dev/null; rmdir $HIDDEN 2>/dev/null; true" || rc=1
    xdsh "$from,$to" "getent passwd $user >/dev/null && userdel -r $user >/dev/null 2>&1; true" || rc=1
    [ "$rc" = 0 ] && echo HBA-CLEANUP-OK
    exit "$rc"
    ;;
*)
    echo "usage: $0 setup|login|cleanup <user> <from> <to>"
    exit 2
    ;;
esac
