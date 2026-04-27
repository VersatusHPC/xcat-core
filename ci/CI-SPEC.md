# xCAT CI Specification

## Overview

Internal CI pipeline for VersatusHPC/xcat-core. Builds packages, then validates them in isolated VM test environments.

## Architecture

```
GitHub Actions (self-hosted runners)
├── Build jobs (8 matrix entries)
│   └── Output: package repository artifacts
└── Test Harness jobs (2 per arch, needs: build)
    └── Input: package repository artifacts
    └── Creates MN VM → installs xCAT → runs tests → teardown
```

## Runners

| Label | Host | Arch | OS |
|-------|------|------|----|
| `xcat-rhel-x86_64` | rome01 | x86_64 | RHEL 10.1 |
| `xcat-alma-ppc64le` | power | ppc64le | AlmaLinux 10.1 |

## Build Matrix

8 jobs: (EL9, EL10, Ubuntu-22.04, Ubuntu-24.04) × (x86_64, ppc64le)

| Type | Tool | Target auto-detection |
|------|------|-----------------------|
| RPM | `buildrpms.pl` + mock | `$DISTRO+epel-$VER-$ARCH` where DISTRO = rhel on RHEL, alma on AlmaLinux |
| DEB | `build-ubunturepo` in podman | Ubuntu container matching target version |

### Build decisions

- **Mock target prefix**: auto-detected from host `/etc/os-release` ID field. RHEL → `rhel`, AlmaLinux → `alma`, Rocky → `rocky`.
- **Release stamp**: `snapYYYYmmddHHMM` written to `Release` file before build.
- **Gitinfo**: `git rev-parse HEAD` written to `Gitinfo` file before build.
- **Workspace isolation**: each build job uses `/var/tmp/xcat3-ci/<distro>-<arch>/` to avoid conflicts.
- **Cleanup**: workspace deleted after each job (success or failure).

## Test Matrix (target: 24 combos)

### Dimensions

- **Arch**: x86_64, ppc64le
- **OS**: EL9, EL10, Ubuntu-22.04, Ubuntu-24.04
- **Boot**: xnba (BIOS), grub2 (UEFI) for x86_64; petitboot, grub2 for ppc64le
- **Deploy**: stateless (netboot), stateful (install)

Boot and deploy tested independently — if grub2 boots stateless, we assume it boots stateful too.

### Test Harness Types

#### `unit-smoke` (implemented)

Validates R1 + R2. Runs once per arch.

**R1: Unit tests**
- `xcattest -s ci_test` — 235 labeled test cases (DB ops, DNS, DHCP, xcatd)

**R2: make* smoke tests (BATS)**
- P2.1: `makehosts` → verify `/etc/hosts` contains defined nodes
- P2.2: `makedns -n` → verify named config generated
- P2.3: `makedhcp -n && makedhcp -a` → verify DHCP leases
- P2.4: `makeknownhosts` → exits 0
- P2.5: `makeconservercf` → exits 0
- P2.6: `makentp` → exits 0

BATS test file: `ci/tests/smoke-make-commands.bats`

#### `deploy-<os>-<boot>-<method>` (TODO)

Validates R3 + R4 + R5. Per combination in the 24-combo matrix.

**R3: Image generation**
- P3.1: `copycds <iso>` → osimage definitions created
- P3.2: stateless: `genimage` + `packimage` → rootimg.gz exists
- P3.3: stateful: kickstart/preseed template exists

**R4: Boot configuration**
- P4.1: `nodeset <cn> osimage=<osimage>` exits 0
- P4.2: xnba: boot config at `/tftpboot/xcat/xnba/nodes/<cn>`
- P4.3: grub2: boot config at `/tftpboot/boot/grub2/<cn>`
- P4.4: petitboot: boot config at `/tftpboot/petitboot/<cn>`

**R5: Deployment**
- P5.1: `rpower <cn> boot` exits 0
- P5.2: node reaches target state within timeout
- P5.3: SSH into CN succeeds
- P5.4: OS version matches expected
- P5.5: architecture matches expected

## Test Environment Requirements

### R6: Isolation

- P6.1: dedicated libvirt network per test run (not shared)
- P6.2: MN VM uses static IP on isolated network
- P6.3: CN VMs get IPs from xCAT-managed DHCP
- P6.4: all VMs tracked in `/var/lib/xcat3-ci/managed-vms.txt`
- P6.5: cleanup removes ALL test VMs, disks, networks on exit

### R7: Reproducibility

- P7.1: environment built from scratch each run
- P7.2: ISOs are pre-staged inputs (not downloaded)
- P7.3: xcat-dep is a pre-staged input
- P7.4: cloud base image is a pre-staged input
- P7.5: fully automated from CI trigger

## Workflow Steps (per test case)

```
1. Build xcat-core packages and repository          → build job
2. Build the testing environment (MN VM + network)   → ci/create-test-env.sh
3. Copy xcat-core repository to environment          → ci/copy-repo-to-env.sh
4. Copy/initialize the testing harness               → ci/init-harness.sh
5. Validate by running the harness                   → ci/run-harness.sh
6. Return success or failure                         → exit code
   Cleanup (always)                                  → ci/teardown-test-env.sh
```

## Prerequisites on Hosts

### Pre-staged inputs

| Input | Location | Purpose |
|-------|----------|---------|
| OS ISOs | `/opt/xcat-ci/isos/` | copycds for deployment tests |
| xcat-dep | `/opt/xcat-dep/el{9,10}/{x86_64,ppc64le}/` | runtime dependencies |
| Cloud image | `/var/lib/libvirt/images/Rocky-9-GenericCloud-*` | MN VM base |

### Software

| Package | Purpose |
|---------|---------|
| mock | RPM builds |
| podman | DEB builds (Ubuntu containers) |
| libvirt + qemu-kvm | VM management |
| genisoimage | cloud-init ISO creation |
| bats | BATS test runner for smoke tests |
| createrepo_c | RPM repo metadata |

## File Layout

```
ci/
├── CI-SPEC.md                    # this file
├── vm-test.sh                    # legacy quick smoke test (kept for build jobs)
├── create-test-env.sh            # step 2: MN VM + libvirt network
├── copy-repo-to-env.sh           # step 3: install xCAT in MN
├── init-harness.sh               # step 4: prepare harness
├── run-harness.sh                # step 5: execute validation
├── teardown-test-env.sh          # step 6: cleanup
└── tests/
    └── smoke-make-commands.bats  # R2 BATS tests
```

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-23 | Self-hosted runners on rome01 + power | Need bare-metal libvirt for VM tests |
| 2026-04-23 | Mock for RPM, podman for DEB | Match upstream build tooling |
| 2026-04-24 | Auto-detect mock target from host OS | rome01=RHEL, power=AlmaLinux need different chroot prefixes |
| 2026-04-24 | tar\|ssh instead of rsync for repo copy | rsync -e flag caused hostname parsing errors |
| 2026-04-24 | log() to stderr | stdout captured by $() — log lines corrupted IP variable |
| 2026-04-24 | Install components not metapackage | xCAT metapackage requires genesis-scripts for all arches |
| 2026-04-24 | xcat-dep extracted from unified tarballs | Temporary solution until proper xcat-dep repo exists |
| 2026-04-27 | Migrated to VersatusHPC/xcat-core | xCAT3 archived, xcat-core is new maintained fork |
| 2026-04-27 | Separate Build and Test jobs | Build only produces artifacts; Test consumes them |
| 2026-04-27 | BATS for smoke tests | Standard test framework, TAP output, clear per-test results |
| 2026-04-27 | test-harness: if !cancelled() | Run tests even if some build matrix entries fail |
