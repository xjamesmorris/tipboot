# Tipboot

Tipboot is a disposable, rootless container for applying patchsets to Linus'
current Linux tree, building `arm64_defconfig`, and proving that the resulting
kernel reaches a minimal PID 1 under QEMU.

The published image contains build and emulation tools only. Kernel source,
patches, caches, logs, `Image`, and initramfs artifacts stay in explicit host
mounts and are never included in the image.

Tipboot resolves and fetches source in a short networked container. Patch
application, kernel build, initramfs creation, and QEMU boot then run in a
second container with no network and a read-only source-object cache.

## Acceleration

An arm64 guest cannot use KVM acceleration on an x86_64 host. Fedora 44 on the
current WSL and laptop hosts therefore uses QEMU TCG. Tipboot automatically
uses KVM only on an arm64 Linux host where `/dev/kvm` is usable.

## Quick start

Install rootless Podman on Fedora 44, clone this repository, and run:

```sh
podman info --format '{{.Host.Security.Rootless}}'
scripts/tipboot --output "$PWD/out/linus-tip"
```

The first command must print `true`.

Temporary source and object files use a disk-backed work directory (by default
next to the persistent cache), not RAM-backed `/tmp`. Override it with
`--work /path/to/fast-local-storage`.

Apply an ordered patch directory:

```sh
scripts/tipboot \
    --patch-dir /absolute/path/to/patches \
    --output "$PWD/out/patched"
```

Apply an mbox and pin the source commit:

```sh
scripts/tipboot \
    --commit <linux-commit-sha> \
    --mbox /absolute/path/to/series.mbox \
    --output "$PWD/out/repro"
```

The run passes only when patches apply, `arm64_defconfig` builds, QEMU starts,
the guest emits exactly one expected `TIPBOOT_OK` marker without an earlier
panic/oops, and the guest requests shutdown before the timeout.

If `--output` already contains a prior run, Tipboot creates a timestamped child
directory instead of overwriting evidence.

See [the design](docs/design.md) and
[troubleshooting guide](docs/troubleshooting.md) for the complete contract.

## Command reference

```text
--commit REF        Linus ref or exact commit; default master
--source-url URL    Alternate Linux Git repository
--patch-dir DIR     Lexically ordered top-level *.patch files
--mbox FILE         Mailbox applied after the patch directory
--output DIR        Result root; nonempty roots receive a new child directory
--cache DIR         Persistent verified Git object cache
--work DIR          Disk-backed temporary checkout/build root
--jobs N            Build jobs, 1-65536
--timeout SECONDS   QEMU timeout, 1-3600
--image IMAGE       Tool image tag or digest
--pull POLICY       always, newer, missing, or never
--keep-source       Copy the complete tracked patched tree to output/source
```

## Development

```sh
make validate
make image
make smoke-pinned
```

No code is committed until the applicable validation targets pass.

## License

Apache-2.0.
