
###########
mkopenhpc.8
###########


****
NAME
****


\ **mkopenhpc**\  - Set up the OpenHPC repository and a minimal Slurm cluster.


********
SYNOPSIS
********


\ **mkopenhpc**\  \ **-r**\  \ *repository_directory*\  [\ **-p**\  \ *partition*\ ] \ *noderange*\  [\ **-V | -**\ **-verbose**\ ]

\ **mkopenhpc**\  [\ **-h | -**\ **-help**\ ]


***********
DESCRIPTION
***********


\ **mkopenhpc**\  deploys Slurm from an OpenHPC 3 repository: \ **slurmctld**\  on the management node, \ **slurmd**\  on the nodes of the noderange, munge authentication, and one default partition with every node. Supported on an EL 9 x86_64 management node with EL 9 x86_64 diskful nodes.

\ **mkopenhpc**\  does these steps:


1. Copies the repository to \ *installdir*\ /ohpc/\ *major*\ /x86_64, which the nodes read over HTTP.



- 2. Installs \ **ohpc-slurm-server**\  and \ **munge**\  on the management node. Creates the munge key in /etc/xcat/ohpc/munge.key when it does not exist, writes /etc/slurm/slurm.conf, opens TCP port 6817 and the srun port range 60001-60100 when firewalld runs, and starts \ **munge**\  and \ **slurmctld**\ .



- 3. Copies the munge key, the repository and slurm.conf to the service nodes of the noderange.



- 4. Adds the \ **confignodeslurm**\  postscript to the \ **postbootscripts**\  of each node.



\ **confignodeslurm**\  runs at the next install of a node, or with \ **updatenode**\  \ *noderange*\  \ **-P confignodeslurm**\ . It installs \ **ohpc-slurm-client**\  and \ **munge**\  from its master, reads the munge key from xcatd, installs slurm.conf, opens TCP port 6818 when firewalld runs, and starts \ **munge**\  and \ **slurmd**\ .

The munge key never goes under the install directory, because the HTTP server publishes that directory.


*******
OPTIONS
*******



- \ **-r**\  \ *repository_directory*\ 
 
 A local directory that holds an OpenHPC repository (with \ **repodata**\ ), such as a mirror of OpenHPC/3/EL_9.
 


- \ **-p**\  \ *partition*\ 
 
 The name of the Slurm partition. The default is \ **compute**\ .
 


- \ *noderange*\ 
 
 The Slurm compute nodes. See the \ *noderange*\  man page for details on supported formats.
 


- \ **-V|-**\ **-verbose**\ 
 
 Verbose mode.
 


- \ **-h|-**\ **-help**\ 
 
 Display usage message.
 



************
RETURN VALUE
************


0 The command completed successfully.

1 An error has occurred.


********
EXAMPLES
********



1. To make the nodes of the compute group Slurm compute nodes in the partition batch:
 
 
 .. code-block:: perl
 
   mkopenhpc -r /data/openhpc/3/EL_9 -p batch compute
   updatenode compute -P confignodeslurm
   srun -N1 -p batch hostname
 
 



*****
FILES
*****


/opt/xcat/sbin/mkopenhpc


********
SEE ALSO
********


updatenode(1)|updatenode.1

