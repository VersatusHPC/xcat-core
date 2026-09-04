fix(xcat-core): a match made elsewhere can name a KVM volume

The name of the volume of a node, and the bus of a file-backed disk, can come from a match made by a routine on the call path. A riscv64 node breaks on it. A leaked value that is neither scsi nor virtio gives the node an hd* volume, and the riscv64 virt machine has no IDE controller for that disk.

createstorage and build_diskstruct in xCAT-server/lib/xcat/plugins/kvm.pm read the model of the disk out of the vmstorage value with s/=(.*)//, then read $1. The substitution is allowed to fail, because most vmstorage values state no model, and a failed match leaves $1 as the last successful capture in the enclosing block. dohyp sets storagemodel to scsi for every node before mkvm runs, and a captured value takes priority over it.

Both routines now read $1 only when their own substitution matches. A vmstorage value that states a model, and vmstoragemodel, name the volume as before. default_storagemodel returns the scsi default that dohyp applies, so a test can drive that default instead of restating it.

xCAT-test/unit/kvm_createstorage_model.t drives createstorage and build_diskstruct in a scratch package, with a stub for the one routine that reaches libvirt. It runs each node twice, once with a capture left live in the calling block, because a case that leaves $1 empty passes against the defect. Five of its ten assertions fail without the fix.

Commits: 33e46bae8 test, fea3d0f3c fix, af0352b42 refactor
