
##################
mkhostbased-auth.8
##################


****
NAME
****


\ **mkhostbased-auth**\  - Set up SSH host-based authentication between the nodes of a noderange.


********
SYNOPSIS
********


\ **mkhostbased-auth**\  \ *noderange*\  [\ **-r | -**\ **-remove**\ ] [\ **-V | -**\ **-verbose**\ ]

\ **mkhostbased-auth**\  [\ **-h | -**\ **-help**\ ]


***********
DESCRIPTION
***********


\ **mkhostbased-auth**\  lets every user except root log in by SSH from one node of the noderange to another without a user key pair. This command is a technology preview in xCAT 2.21.

The nodes are split into trust scopes. A node in a zone belongs to the scope of that zone. A node in no zone belongs to the scope \ **default**\ . The nodes of a zone with \ **sshbetweennodes=no**\  are skipped.

For each scope, \ **mkhostbased-auth**\  writes \ **ssh_known_hosts**\  and \ **shosts.equiv**\  into \ *installdir*\ /postscripts/hostbased/\ *scope*\ /. \ **ssh_known_hosts**\  holds the host public keys from /etc/xcat/hostkeys (or /etc/xcat/hostkeys/\ *node*\ /) for the short name, the FQDN and the IP addresses of each node. \ **shosts.equiv**\  holds the same names and addresses. The command copies the files to the service nodes of the noderange, then runs the \ **confighostbasedauth**\  postscript on the nodes with \ **updatenode -P**\ .

\ **confighostbasedauth**\  installs the two files in /etc/ssh, sets \ **HostbasedAuthentication yes**\  for sshd and ssh and \ **EnableSSHKeysign yes**\  for ssh, installs \ **openssh-keysign**\  where the distribution ships \ **ssh-keysign**\  in its own package, and restarts sshd.

\ **mkhostbased-auth**\  adds \ **confighostbasedauth**\  \ *scope*\  to the \ **postbootscripts**\  of each node, so a reinstalled node gets the same setup.

When the management node runs in FIPS mode, ed25519 host keys are left out. DSA host keys are never published.

Supported on EL 9 and Ubuntu 24.04 x86_64 nodes.


********
SECURITY
********


\ **shosts.equiv**\  makes each node trust every other node of its scope for every user name. A user who is root on one node of the scope can log in as any other user on every node of the scope. Use a zone to limit a scope. OpenSSH ignores \ **shosts.equiv**\  for root, so root logins still need root's keys.


*******
OPTIONS
*******



- \ *noderange*\ 
 
 A set of comma delimited node names and/or group names. See the \ *noderange*\  man page for details on supported formats.
 


- \ **-r|-**\ **-remove**\ 
 
 Removes the setup from the nodes and removes \ **confighostbasedauth**\  from their \ **postbootscripts**\ .
 


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



1. To let the users of the compute group log in between its nodes:
 
 
 .. code-block:: perl
 
   mkhostbased-auth compute
 
 


- 2. To remove the setup:
 
 
 .. code-block:: perl
 
   mkhostbased-auth compute -r
 
 



*****
FILES
*****


/opt/xcat/sbin/mkhostbased-auth


********
SEE ALSO
********


makeknownhosts(8)|makeknownhosts.8, mkzone(1)|mkzone.1, updatenode(1)|updatenode.1

