OpenHPC and Slurm
=================

``mkopenhpc`` sets up a minimal Slurm cluster from an OpenHPC 3 repository. ``slurmctld`` runs on the management node and ``slurmd`` runs on the compute nodes. Slurm uses munge authentication and one default partition that holds every node.

Support
-------

* The management node and the compute nodes run EL 9 on x86_64.
* The compute nodes are diskful. A compute node can be behind a service node.
* Slurm runs on the management node and on the compute nodes, not on the service nodes.

``slurmdbd``, more than one partition, and diskless compute nodes are not supported.

Prepare the repository
----------------------

``mkopenhpc`` reads a local directory that holds an OpenHPC 3 repository with ``repodata``. The directory must also hold the dependencies that do not come from the BaseOS and AppStream repositories of the OS media, for example the EPEL and CRB packages that ``ohpc-slurm-server`` and ``ohpc-slurm-client`` require.

The compute nodes install ``munge`` from the AppStream repository of their osimage. Run ``copycds`` for the EL 9 media before you install the nodes.

One way to make the directory is to download the packages and their dependencies with ``dnf``, with the OpenHPC 3 ``EL_9`` repository and EPEL enabled, and then run ``createrepo_c`` on the directory: ::

    dnf download --resolve --alldeps --destdir /data/openhpc/3/EL_9 \
        ohpc-slurm-server ohpc-slurm-client munge
    createrepo_c /data/openhpc/3/EL_9

Set up Slurm
------------

Run ``mkopenhpc`` with the repository directory, a partition name and the compute nodes: ::

    mkopenhpc -r /data/openhpc/3/EL_9 -p batch compute

The default partition name is ``compute``. On the management node, ``mkopenhpc``:

#. Copies the repository to ``<installdir>/ohpc/3/x86_64``. The nodes read it over HTTP.
#. Installs ``ohpc-slurm-server`` and ``munge``.
#. Creates the munge key in ``/etc/xcat/ohpc/munge.key`` when the key does not exist.
#. Writes ``/etc/slurm/slurm.conf``.
#. Opens TCP port 6817 and the ``srun`` port range 60001-60100 when firewalld runs.
#. Starts ``munge`` and ``slurmctld``.

When a compute node is behind a service node, ``mkopenhpc`` copies the munge key, the repository and ``slurm.conf`` to that service node.

``mkopenhpc`` adds the ``confignodeslurm`` postscript to the ``postbootscripts`` of each compute node. The postscript runs at the next install of the node. To set up a node that is already installed, run: ::

    updatenode compute -P confignodeslurm

``confignodeslurm`` installs ``ohpc-slurm-client`` and ``munge``, gets the munge key from xcatd, installs ``slurm.conf``, opens TCP port 6818 when firewalld runs, and starts ``munge`` and ``slurmd``.

The munge key is not put under the install directory, because the HTTP server publishes that directory.

Verify
------

A compute node registers with ``slurmctld`` some seconds after ``slurmd`` starts. Then the node shows the state ``idle``: ::

    sinfo -N

Run a job on one node: ::

    srun -N1 -p batch hostname

The command prints the host name of the compute node.

See :doc:`mkopenhpc </guides/admin-guides/references/man8/mkopenhpc.8>` for the options.
