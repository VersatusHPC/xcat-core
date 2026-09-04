Task Type
=========

xCAT ships two Genesis images. The legacy image runs every task on this page.
The OpenEmbedded image runs only the commands that it carries, and refuses a
task that it must download at boot. ``mknb <arch>`` installs the OpenEmbedded
image when the management node has it for that architecture. ``riscv64`` has
the OpenEmbedded image only.

xCAT supports following types of task which could be set in the chain:

* runcmd ::

    runcmd=<cmd>

Currently only the ``bmcsetup`` command is officially supplied by xCAT to run to configure the bmc of the compute node. You can find the ``bmcsetup`` in /opt/xcat/share/xcat/netboot/genesis/<arch>/fs/bin/. You also could create your command in this directory and adding it to be run by ``runcmd=<you cmd>``. ::

    runcmd=bmcsetup

.. note:: The command ``mknb <arch>`` is needed before reboot the node.

.. note:: That directory belongs to the legacy Genesis image. The OpenEmbedded
   Genesis image runs the commands in ``/usr/libexec/xcat/genesis/actions``, and
   it carries ``bmcsetup`` only. To add a command to that image, package the
   command in the image or in a signed Genesis system extension.

* runimage ::

    runimage=<URL>

**URL** is a string which can be run by ``wget`` to download the image from the URL. The example could be: ::

    runimage=http://<IP of xCAT Management Node>/<dir>/image.tgz

The ``image.tgz`` **must** have the following properties:
  * Created using the ``tar zcvf`` command
  * The tarball must include a ``runme.sh`` script to initiate the execution of the runimage

To create your own image, reference :ref:`creating image for runimage <create_image_for_runimage>`.

**Tip**: You could try to run ``wget http://<IP of xCAT Management Node>/<dir>/image.tgz`` manually to make sure the path has been set correctly.

.. note:: ``runimage`` needs the legacy Genesis image. The OpenEmbedded Genesis
   image refuses the task, so ``nodeset`` refuses ``runimage`` for a node whose
   architecture boots that image. Use ``runcmd`` with a command that the image
   carries.

* osimage ::

   osimage=<image name>

This task is used to specify the image that should be deployed onto the compute node.

* shell

Causes the genesis kernel to create a shell for the administrator to log in and execute commands.

* standby

Causes the genesis kernel to go into standby and wait for tasks from the chain. ...

