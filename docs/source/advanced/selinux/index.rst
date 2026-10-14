SELinux
=======

xCAT runs with SELinux in enforcing mode on the management node and on a service
node. A compute node is supported on EL9. An EL10 compute node that boots a
diskless image must stay permissive; the reason is below.

What is measured
----------------

================================  ==========  =========================================
Machine                           Enforcing   Evidence
================================  ==========  =========================================
Management node, EL9 and EL10     yes         required cases pass, with a mislabelled
                                              control that fails the check
Service node, EL9, diskful        yes         boots in 25 s, 0 failed units, both
                                              hierarchy cases pass, 0 denials
Compute node, EL9, netboot        yes         0 ``Permission denied`` on the console
Compute node, EL10, netboot       **no**      wedges before the pivot
Compute node, EL10, diskful       untested    no run has reached it
Service node, EL10                untested    no EL10 service-node cell exists
================================  ==========  =========================================

Why an EL10 diskless compute node cannot run enforcing
------------------------------------------------------

The node unpacks its root into a tmpfs, and dracut loads the SELinux policy
before it pivots into that root. Every file in the initramfs still carries no
usable label at that moment, so each binary executed after the load is refused,
including the ones the policy-loading script itself calls. The node never
pivots, so ``auditd`` never starts and there is no AVC record anywhere. The
console is the only evidence.

Relabelling the root before the policy loads does not help. The policy declares
``fs_use_trans tmpfs``, so a tmpfs inode takes its label by transition at
creation and never from an extended attribute. A ``setfiles`` run over the
tmpfs root completes, reports success, and the policy load discards the result.

A policy module can make the node boot, but it must grant the init domain
execute on unlabelled files, which removes the protection the mode exists to
give. xCAT does not ship such a rule.

Set the node permissive with::

    chdef <node> selinux=permissive

Service node booleans
---------------------

A service node mounts ``/install`` and ``/tftpboot`` from the management node,
so those trees carry ``nfs_t`` and the file contexts of the management node do
not apply to them. Set::

    setsebool -P httpd_use_nfs on
    setsebool -P use_nfs_home_dirs on
    setsebool -P tftp_home_dir on

``updatenode`` synchronises files over ssh as ``rsync_t``, which needs::

    setsebool -P rsync_client on
    setsebool -P rsync_full_access on

Without the ``rsync`` booleans ``updatenode -F`` fails and the node is left in
``failed`` state.
