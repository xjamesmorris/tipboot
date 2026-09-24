# Troubleshooting

## Fedora 44 prerequisites

```sh
sudo dnf install podman git make
podman info --format '{{.Host.Security.Rootless}}'
```

The command must print `true`; Tipboot rejects rootful Podman. On WSL, run
these commands inside the Fedora 44 distribution rather than from Windows
PowerShell. Keep the repository, cache, work, and output directories in the
WSL Linux filesystem (for example under `~/src` and `~/.cache`), not under
`/mnt/c`, for correct Linux ownership/SELinux behavior and substantially
better build I/O performance.

## TCG is selected despite `/dev/kvm`

This is expected on x86_64. `/dev/kvm` accelerates x86 guests there, not an
arm64 guest. The boot transcript and result metadata identify the accelerator.

## Patch application fails

Inspect `build.log`, `patches.sha256`, and the preserved source diagnostics in
the output directory. Tipboot stops at the first failed `git am`; it does not
silently skip patches or continue with a partial series.

## QEMU times out

Inspect `boot.log` for the last kernel message. Increase the limit for slow TCG
hosts:

```sh
scripts/tipboot --timeout 600 --output "$PWD/out/slow-host"
```

A timeout remains a failed smoke test even if the kernel printed substantial
boot progress.

## SELinux denies a mount

Tipboot labels its explicit cache, work, output, resolver scratch, and input
mounts. Inspect the host paths and labels with:

```sh
ls -ldZ "$HOME/.cache/tipboot" "$HOME/.cache/tipboot-work" "$PWD/out"
podman info --format '{{.Host.Security.Rootless}}'
```

Keep these paths owned by the invoking user and avoid network filesystems that
do not support Fedora SELinux labels. Do not work around a denial with
`--privileged` or global label disabling.

## Reproduce a prior run

Read the prior source URL and commit from `source.json`, and the image digest
from `provenance.json`, then use the same original patch input form:

```sh
scripts/tipboot \
    --source-url <recorded-source-url> \
    --commit <resolved-commit> \
    --image ghcr.io/xjamesmorris/tipboot@sha256:<digest> \
    --patch-dir /absolute/path/to/the-same-patches \
    --output "$PWD/out/reproduced"
```

Compare the recorded patch hashes and patched tree before interpreting boot
differences. Reusing a nonempty `--output` path creates a timestamped child
directory so the prior result remains intact.
