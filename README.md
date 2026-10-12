# sandal-assets

Prebuilt release assets for [sandal](https://github.com/maralla/sandal) —
currently the guest kernels.

## Guest kernels

sandal boots a Linux guest kernel per architecture, both published here as
release assets:

- `vmlinux-sandal-x86_64` — stripped ELF vmlinux built from `allnoconfig`
  + `scripts/kernel-x86.fragment` (a COMPLETE minimal config, not a delta),
  carrying the PVH 32-bit entry note: booted directly by the VMM, no
  firmware, no bootloader.
- `vmlinux-sandal-aarch64` — arm64 `Image` built from
  `scripts/kernel.config`.

### Building locally

```
scripts/build-kernel.sh x86_64            # native build (gcc, flex, bison)
scripts/build-kernel.sh aarch64           # native build (aarch64 Linux; what CI runs)
scripts/build-kernel.sh aarch64 HOST      # cross-build on HOST over SSH (macOS flow)
```

See the header of `scripts/build-kernel.sh` for details.

### Releasing

Releases are versioned by tag: `kernel-X.Y.Z` (starting at
`kernel-0.1.0`), not by the kernel version — the kernel version is
pinned in `scripts/kernel.config` / `scripts/kernel-x86.fragment` and
bumped there independently. Push a `kernel-X.Y.Z` tag: the
[`kernels`](.github/workflows/kernels.yml) workflow builds both
architectures on GitHub arm64/x86_64 runners and creates a release
with `vmlinux-sandal-<arch>` + `SHA256SUMS` assets.

`releases/latest` then points at the new release, and sandal's
`scripts/fetch-kernel.sh` (`make kernel`) follows it automatically.

## License

MIT — see [LICENSE](LICENSE).
