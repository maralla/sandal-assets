# Prebuilt sandal guest kernels

Prebuilt guest kernels for [sandal](https://github.com/maralla/sandal),
built from the kernel configs (`scripts/kernel.config`,
`scripts/kernel-x86.fragment`) at this tag by the `kernels` workflow.

| Asset | Description |
|-------|-------------|
| `vmlinux-sandal-x86_64` | Stripped ELF vmlinux with the PVH 32-bit entry note — booted directly by the VMM, no firmware, no bootloader |
| `vmlinux-sandal-aarch64` | arm64 `Image` |
| `SHA256SUMS` | SHA-256 checksums of the assets above |

## Consuming

sandal fetches the kernel for the host architecture with `make kernel`
(`scripts/fetch-kernel.sh`), which downloads from

```
https://github.com/maralla/sandal-assets/releases/latest/download/vmlinux-sandal-<arch>
```

and verifies the download against `SHA256SUMS` from the same release.

## Updating

The kernels are built from the configs at the tagged commit — the tag name
is a label, not a build input. To ship a new kernel version: bump the
version pinned in the configs, then push a `kernel-<version>` tag. To
retry a failed run, delete and re-push the tag; partially uploaded assets
are replaced.
