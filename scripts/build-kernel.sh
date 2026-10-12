#!/usr/bin/env bash
#
# build-kernel.sh — Build the sandal guest kernel for one architecture.
#
# Usage:
#   scripts/build-kernel.sh aarch64 HOST [KERNEL_VERSION]
#   scripts/build-kernel.sh aarch64 [KERNEL_VERSION]
#   scripts/build-kernel.sh x86_64 [KERNEL_VERSION]
#
# All forms write `vmlinux-sandal-<arch>` into the project root. The
# `kernel-*` tag workflow in this repository builds both architectures and
# publishes them as release assets; sandal fetches those with its
# `make kernel` (scripts/fetch-kernel.sh).
#
# aarch64 (alias: arm64)
#   Two build paths, both from scripts/kernel.config (a full generated
#   config for the pinned version):
#
#   - With HOST: cross-compiles on a remote Linux host over SSH — a macOS
#     machine cannot build an arm64 Linux kernel natively — then syncs the
#     resulting `Image` back. HOST is the SSH target; KERNEL_VERSION is
#     auto-detected from the "# Linux/arm64 <ver> Kernel Configuration"
#     header in scripts/kernel.config when omitted.
#
#   - Without HOST (aarch64 Linux only; this is what CI runs): builds
#     natively — the same configure + SP804 force-enable + `make Image`
#     steps as the SSH path, minus the cross toolchain. KERNEL_VERSION is
#     auto-detected the same way.
#
# x86_64 (aliases: x86, amd64)
#   Builds locally from allnoconfig + scripts/kernel-x86.fragment (a COMPLETE
#   minimal config, not a delta) and produces a stripped ELF vmlinux with the
#   PVH 32-bit entry note, booted directly by the VMM (no firmware, no
#   bootloader). Requires gcc, flex and bison. KERNEL_VERSION defaults to
#   7.2.10 (keep in sync with the fragment's base).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

info()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m==>\033[0m %s\n" "$*"; }
error() { printf "\033[1;31mERR\033[0m %s\n" "$*" >&2; }

usage() {
    cat <<'EOF'
Usage:
  scripts/build-kernel.sh aarch64 HOST [KERNEL_VERSION]   # cross-build on HOST over SSH
  scripts/build-kernel.sh aarch64 [KERNEL_VERSION]       # native build (aarch64 Linux)
  scripts/build-kernel.sh x86_64 [KERNEL_VERSION]        # native build

Output: vmlinux-sandal-<arch> in the project root (released as an asset
by the kernel-* tag workflow; sandal fetches it with make kernel).
EOF
}

ARCH="${1:-}"
case "$ARCH" in
    aarch64|arm64)    ARCH=aarch64 ;;
    x86_64|x86|amd64) ARCH=x86_64 ;;
    -h|--help|"")     usage; exit 0 ;;
    *) error "unknown architecture: $ARCH"; usage; exit 1 ;;
esac
shift

OUTPUT="$PROJECT_DIR/vmlinux-sandal-$ARCH"

# Shared helpers ──────────────────────────────────────────────────────────────

# The version pinned in scripts/kernel.config's header, unless overridden.
aarch64_kernel_version() {   # aarch64_kernel_version [OVERRIDE]
    local kver="${1:-}"
    if [ -z "$kver" ]; then
        kver="$(sed -n 's/^# Linux\/arm64 \([0-9.]*\) Kernel Configuration/\1/p' \
            "$SCRIPT_DIR/kernel.config")"
    fi
    if [ -z "$kver" ]; then
        error "could not detect kernel version from scripts/kernel.config"
        echo "Pass it explicitly: $0 aarch64 [HOST] 7.2.10" >&2
        exit 1
    fi
    printf '%s\n' "$kver"
}

require_tools() {   # require_tools TOOL...
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null || { error "$t is required"; exit 1; }
    done
}

# Download the kernel source tarball into DIR if the tree is not already
# there; sets KERNEL_SRC to the extracted tree.
KERNEL_SRC=""
ensure_kernel_source() {   # ensure_kernel_source VERSION DIR
    local kver="$1" dir="$2"
    local kmajor="${kver%%.*}"
    KERNEL_SRC="$dir/linux-$kver"
    [ -d "$KERNEL_SRC" ] && return 0
    mkdir -p "$dir"
    info "Downloading linux-$kver..."
    curl -fSL --progress-bar \
        "https://cdn.kernel.org/pub/linux/kernel/v${kmajor}.x/linux-$kver.tar.xz" \
        -o "$dir/linux-$kver.tar.xz"
    tar xf "$dir/linux-$kver.tar.xz" -C "$dir"
}

# aarch64 ────────────────────────────────────────────────────────────────────

build_aarch64_ssh() {   # build_aarch64_ssh HOST [KERNEL_VERSION]
    local host="$1"
    local kver
    kver="$(aarch64_kernel_version "${2:-}")"
    local kmajor="${kver%%.*}"

    local config="$SCRIPT_DIR/kernel.config"
    # Name kept from when this script lived in the sandal repository: the
    # remote source tree under this path is reused across builds, and a
    # fresh name would re-download ~150MB of kernel source.
    local remote_dir="~/sandal"

    info "Building kernel $kver for aarch64 on $host"

    # Step 1: Sync config to remote
    info "Syncing kernel config to $host:$remote_dir/"
    ssh "$host" "mkdir -p $remote_dir"
    rsync -az "$config" "$host:$remote_dir/kernel.config"

    # Step 2: Download kernel source on remote if not present
    info "Ensuring kernel source is available..."
    ssh "$host" "
        cd $remote_dir
        if [ ! -d linux-$kver ]; then
            echo 'Downloading linux-$kver...'
            curl -fSL --progress-bar \
                https://cdn.kernel.org/pub/linux/kernel/v${kmajor}.x/linux-$kver.tar.xz \
                -o linux-$kver.tar.xz
            tar xf linux-$kver.tar.xz
            echo 'Source extracted.'
        else
            echo 'Source already present.'
        fi
    "

    # Step 3: Configure and build
    info "Building kernel..."
    ssh "$host" "
        cd $remote_dir/linux-$kver
        cp ../kernel.config .config
        make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig 2>&1 | tail -1
        # Force-enable SP804 in case olddefconfig dropped it due to unmet deps
        # (HAVE_ARM_TIMER_SP804 no longer exists; ARM_TIMER_SP804=y is the
        # real gate and is verified to stick).
        if ! grep -q '^CONFIG_ARM_TIMER_SP804=y' .config; then
            echo 'Enabling CONFIG_ARM_TIMER_SP804...'
            scripts/config --enable ARM_TIMER_SP804
            make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig 2>&1 | tail -1
        fi
        make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j\$(nproc) Image 2>&1 | tail -3
    "

    # Step 4: Sync the Image back
    info "Syncing kernel to $OUTPUT"
    rsync -az "$host:$remote_dir/linux-$kver/arch/arm64/boot/Image" "$OUTPUT"

    ok "Kernel $kver built and saved to $(basename "$OUTPUT") ($(du -h "$OUTPUT" | cut -f1 | xargs))"
}

build_aarch64_native() {   # build_aarch64_native [KERNEL_VERSION]
    local kver
    kver="$(aarch64_kernel_version "${1:-}")"
    local build_dir="$PROJECT_DIR/kernel-build"

    [ "$(uname -m)" = aarch64 ] || {
        error "native aarch64 build requires an aarch64 Linux host (from macOS: $0 aarch64 HOST)"
        exit 1
    }
    require_tools gcc flex bison
    ensure_kernel_source "$kver" "$build_dir"

    info "Building kernel $kver for aarch64 (native)..."
    cd "$KERNEL_SRC"
    cp "$SCRIPT_DIR/kernel.config" .config
    make olddefconfig 2>&1 | tail -1
    # Force-enable SP804 in case olddefconfig dropped it due to unmet deps
    # (HAVE_ARM_TIMER_SP804 no longer exists; ARM_TIMER_SP804=y is the real
    # gate and is verified to stick).
    if ! grep -q '^CONFIG_ARM_TIMER_SP804=y' .config; then
        echo 'Enabling CONFIG_ARM_TIMER_SP804...'
        scripts/config --enable ARM_TIMER_SP804
        make olddefconfig 2>&1 | tail -1
    fi
    make -j"$(nproc)" Image 2>&1 | tail -3
    cp arch/arm64/boot/Image "$OUTPUT"

    ok "Kernel $kver built and saved to $(basename "$OUTPUT") ($(du -h "$OUTPUT" | cut -f1 | xargs))"
}

# x86_64 ─────────────────────────────────────────────────────────────────────

build_x86_64() {   # build_x86_64 [KERNEL_VERSION]
    local fragment="$SCRIPT_DIR/kernel-x86.fragment"
    local kver="${1:-7.2.10}"   # keep in sync with kernel-x86.fragment's base
    local build_dir="$PROJECT_DIR/kernel-build"

    require_tools gcc flex bison
    ensure_kernel_source "$kver" "$build_dir"

    info "Building kernel $kver for x86_64..."
    cd "$KERNEL_SRC"
    # Minimal base: allnoconfig instead of x86_64_defconfig. The defconfig
    # kernel (hundreds of drivers, ~43MB vmlinux) spends ~800ms booting; the
    # fragment below enables only what the sandal guest needs and boots in
    # tens of milliseconds. The fragment must therefore be a COMPLETE config
    # (architecture basics included), not a delta.
    make O=build allnoconfig 2>&1 | tail -1

    # Apply the fragment with scripts/config (never touches the source root; a
    # stray .config there makes O= builds refuse to run).
    while read -r line; do
        case "$line" in
            CONFIG_*=m) "$KERNEL_SRC/scripts/config" --file build/.config --module "${line%%=*}" ;;
            CONFIG_*=y) "$KERNEL_SRC/scripts/config" --file build/.config --enable "${line%%=*}" ;;
            "# CONFIG_"*" is not set")
                sym="${line#\# CONFIG_}"; sym="${sym%% is*}"
                "$KERNEL_SRC/scripts/config" --file build/.config --disable "$sym" ;;
        esac
    done < "$fragment"
    make O=build olddefconfig 2>&1 | tail -1
    make O=build -j"$(nproc)" vmlinux 2>&1 | tail -1
    strip build/vmlinux
    cp build/vmlinux "$OUTPUT"
    ok "Kernel $kver built and saved to $(basename "$OUTPUT") ($(du -h "$OUTPUT" | cut -f1 | xargs))"
}

# Dispatch ────────────────────────────────────────────────────────────────────

case "$ARCH" in
    aarch64)
        case "${1:-}" in
            "")
                # No argument: native build on aarch64 hosts, help elsewhere.
                if [ "$(uname -m)" = aarch64 ]; then
                    build_aarch64_native
                else
                    error "aarch64 needs a cross-build HOST (over SSH) or an aarch64 Linux host"
                    usage
                    exit 1
                fi
                ;;
            *[!0-9.]*)
                # Non-version argument: an SSH host.
                build_aarch64_ssh "${1:-}" "${2:-}"
                ;;
            *)
                # Version-shaped argument: native build with that version.
                build_aarch64_native "${1:-}"
                ;;
        esac
        ;;
    x86_64)
        build_x86_64 "$@"
        ;;
esac
