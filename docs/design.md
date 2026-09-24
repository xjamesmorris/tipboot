# Design

## Trust and isolation model

Tipboot treats kernel source and patch inputs as untrusted build inputs. The
host wrapper starts a rootless Podman container with all capabilities dropped,
`no-new-privileges`, a read-only root filesystem, bounded PIDs, private
temporary filesystems, and only the requested input, cache, and output mounts.
It does not mount the container engine socket, the host root, or the user's
home directory.

Only the resolver container has outbound network access, and it never consumes
patch inputs or runs kernel build logic. The patch, build, initramfs, and QEMU
container runs with `--network=none` and a read-only Git object cache.
Repository hooks are disabled. Build products are not executed on the host;
the only generated executable is arm64 code run inside the QEMU guest.

## Pipeline

1. Resolve the requested Linus ref in a fresh verification context and record
   its exact commit.
2. Create a clean source checkout from the verified, read-only persistent Git
   object cache in the network-isolated container.
3. Hash and apply lexical `*.patch` files and then the optional mbox using
   `git am --3way`.
4. Record patched HEAD and tree IDs.
5. Run `ARCH=arm64 LLVM=1 defconfig` and build `Image` out of tree.
6. Compile a freestanding arm64 `/init` and create a deterministic `newc`
   initramfs.
7. Boot QEMU's generic arm64 `virt` machine with no network or display.
8. Validate serial output, shutdown, timeout, and panic/oops conditions.

## Result contract

Each run that reaches the build container writes durable files under one
output directory. If a requested directory contains anything, the host wrapper
creates a timestamped child rather than overwriting it:

```text
result.json
summary.txt
provenance.json
source.json
source.txt
patches.sha256
.config
config
kernelrelease
build.log
boot.log
Image
initramfs.cpio.gz
```

`source.json` identifies the resolved source and patched Git objects.
`provenance.json` adds the tool image reference, immutable image digest when
the registry supplies one, local image ID, and run timestamp.
`result.json` records the terminal stage and machine-readable outcome.
With `--keep-source`, `source/` contains the complete tracked patched tree.
Patch failures additionally retain `FAILED`, source diagnostics, diffs, and
the failed mailbox when available. Failures before the build container starts,
such as an image pull or source-resolution failure, are reported directly and
may not create result files.

## Reproducibility

`master` is a moving convenience ref. A run becomes reproducible through the
resolved commit, patch hashes, patched tree, configuration, tool versions, and
image digest recorded in its output. Use the same `--source-url`, patch input
form, recorded commit and patch hashes, and an image digest for a deliberate
rerun. Locally built images may have only an immutable image ID rather than a
registry digest.

## KVM and TCG

KVM virtualizes a guest matching the host architecture. An x86_64 host must
therefore emulate arm64 with TCG even when `/dev/kvm` exists. On arm64,
Tipboot probes QEMU KVM support and device access before selecting
`-accel kvm -cpu host`; failures fall back explicitly to TCG.
