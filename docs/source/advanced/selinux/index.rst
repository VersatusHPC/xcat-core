SELinux
=======

xCAT supports SELinux in enforcing mode on the management node and on a service
node. Those are the two machines this version is measured on, and an xCAT
installation no longer turns SELinux off on them.

A compute node is a separate question. xCAT can provision one with SELinux
enabled, and it is not required to run enforcing. ``site.selinux`` and
``noderes.selinux`` select the mode, and xCAT lowers the mode of a node that
cannot boot with it.

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
Compute node, EL10, netboot       no          clamped to permissive, see below
Compute node, EL10, diskful       untested    no run has reached it
Service node, EL10                untested    no EL10 service-node cell exists
================================  ==========  =========================================

Selecting the mode
------------------

``site.selinux`` holds the default mode for the nodes of the cluster. The values
are ``enforcing``, ``permissive`` and ``disabled``, and an unset key means
``disabled``. ``xcatconfig -i`` records ``enforcing`` when the management node
is enforcing.

``noderes.selinux`` overrides it for a node or a group::

    chdef -t group -o compute selinux=permissive

xCAT resolves the mode of a node to ``disabled`` when the operating system has
no xCAT SELinux policy, which is every family outside Red Hat, Fedora and
openEuler, and when the node is statelite.

Why an EL10 diskless compute node is clamped
--------------------------------------------

EL10 dracut loads the SELinux policy at pre-pivot 50. The node unpacks its root
into a tmpfs, which carries no usable label at that moment, so each binary run
after the load is refused, including the ones the policy-loading script itself
calls. The node never pivots. ``auditd`` starts after the pivot, so there is no
AVC record anywhere and the serial console is the only evidence. An EL9 node
boots enforcing on the same xCAT version and the same boot path.

``nodeset`` therefore gives such a node ``permissive`` instead of ``enforcing``,
and says so. The node boots, labels its root and logs what it would have
denied.

A policy module of fifteen rules does make the node boot enforcing, and xCAT
does not ship it. Thirteen of those rules are ordinary: reads under
``/proc/sys``, a netlink socket, an unmount. Two grant the pre-pivot domain
execute on an unlabelled file, which on a diskless node is the whole root.
They are the price of a tmpfs root rather than a workaround for the hook order.

Labelling the root first does not remove them. The policy declares
``fs_use_trans tmpfs``, so a tmpfs inode takes its label by transition at
creation and never from an extended attribute. A ``setfiles`` run before the
policy load relabelled 26314 inodes and returned 0, and the policy load
discarded every one of them: the denials rose from 24 to 123. No hook order
changes this.

One route is left, and it is in the image, not in xCAT: load the policy after
the pivot, when the real root is in place. The distro script's own ``FIXME``
asks for it.

Service node mounts and booleans
--------------------------------

A service node mounts ``/install`` and ``/tftpboot`` from the management node.
NFS carries no per-file label, so xCAT adds a ``context=`` option to each mount
when SELinux is on: ``public_content_t`` for ``/install`` and ``tftpdir_t`` for
``/tftpboot``. The trees then carry the type the services expect, and the
``httpd_use_nfs``, ``use_nfs_home_dirs`` and ``tftp_home_dir`` booleans are not
needed.

Where a mount is made by hand, or an ``/etc/fstab`` entry predates this version,
the tree carries ``nfs_t`` instead and those three booleans are the fallback::

    setsebool -P httpd_use_nfs on
    setsebool -P use_nfs_home_dirs on
    setsebool -P tftp_home_dir on

``rsync`` enters the confined ``rsync_t`` domain only from a system service.
``xcatd`` runs as ``unconfined_service_t``, so ``updatenode -F`` and ``xdcp``
synchronise files unconfined and need no boolean. A site that drives the same
work from a unit or a cron job does, because that caller does transition::

    setsebool -P rsync_client on
    setsebool -P rsync_full_access on

The policy xCAT ships
---------------------

The ``xCAT-selinux`` package carries the ``xcat`` policy module and the file
contexts. ``xCAT-server`` and ``xCATsn`` require it on a Red Hat family
installation that has the targeted policy.

* ``/install`` is ``public_content_t``, so ``httpd`` serves it. Each ``rootimg``
  tree is left out of the relabel, because it keeps the labels of its own
  operating system.
* ``httpd`` reads and maps the ``/tftpboot`` files that ``xcat.conf`` serves.
* ``xcatws.cgi`` connects to the ``xcatd`` port.
* ``rsync`` reads ``/etc/shadow`` and writes a copy it created at mode 0000.
* ``useradd`` and ``groupadd`` read the ``rootimg`` ``/var/run`` symlink, which
  the rpm scriptlets of a ``genimage`` build need.

The package does not change the SELinux mode of any machine.

Reading denials
---------------

``ausearch`` without ``--input`` reported nothing on an AlmaLinux 10 node that
had records in the file ``auditd.conf`` names. Read the log directly, or pass
``--input``, before concluding a machine is clean.

The kernel also drops audit records printed before ``auditd`` starts, at
``printk_ratelimit_burst`` and with no notice. Boot with
``sysctl.kernel.printk_ratelimit=0`` to see that window whole. Any count taken
without it is a lower bound.
