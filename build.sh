#!/bin/bash
set -euo pipefail

# Capture script directory before any cd
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Linux Kernel Build ==="
echo "Host: $(uname -n)"
echo "Date: $(date -u)"
echo "CPUs: $(nproc)"
echo "Arch: $(uname -m)"
echo ""

# Install build dependencies
echo ">>> Installing build dependencies..."
if command -v dnf &>/dev/null; then
    dnf install -y \
        gcc make flex bison bc perl hostname \
        elfutils-libelf-devel openssl-devel ncurses-devel \
        diffutils findutils xz cpio kmod \
        wget tar gzip 2>&1 | tail -5
elif command -v apt-get &>/dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        gcc make flex bison bc perl \
        libelf-dev libssl-dev libncurses-dev \
        diffutils findutils xz-utils cpio kmod \
        wget tar gzip 2>&1 | tail -5
fi
echo ">>> Dependencies installed"

# Determine latest stable kernel version from kernel.org
echo ">>> Fetching latest kernel version..."
KERNEL_VERSION=$(wget -qO- https://www.kernel.org/finger_banner | grep -oP 'The latest stable version of the Linux kernel is:\s+\K[\d.]+' | head -1)
if [ -z "$KERNEL_VERSION" ]; then
    # Fallback: parse from releases page
    KERNEL_VERSION=$(wget -qO- https://www.kernel.org/ | grep -oP 'linux-\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi
if [ -z "$KERNEL_VERSION" ]; then
    echo "ERROR: Could not determine latest kernel version"
    exit 1
fi

MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
echo ">>> Latest stable kernel: $KERNEL_VERSION (major=$MAJOR)"

# Download kernel source
TARBALL="linux-${KERNEL_VERSION}.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"
WORKDIR="/tmp/kernel-build"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo ">>> Downloading $URL ..."
wget -q --show-progress "$URL"
echo ">>> Extracting..."
tar xf "$TARBALL"
cd "linux-${KERNEL_VERSION}"

# Configure kernel
echo ">>> Running make defconfig..."
make defconfig 2>&1 | tail -3

echo ">>> Applying config fragment..."
if [ -f "$SCRIPT_DIR/config.fragment" ]; then
    scripts/kconfig/merge_config.sh -m .config "$SCRIPT_DIR/config.fragment" 2>&1 | tail -10
else
    echo "WARNING: config.fragment not found at $SCRIPT_DIR, using defconfig only"
fi

echo ">>> Running make olddefconfig..."
make olddefconfig 2>&1 | tail -3

# Build kernel
echo ">>> Building kernel with $(nproc) CPUs..."
SECONDS=0
make -j$(nproc) bzImage 2>&1 | tail -20
echo ">>> bzImage built in ${SECONDS}s"

echo ">>> Building modules..."
SECONDS=0
make -j$(nproc) modules 2>&1 | tail -20
echo ">>> Modules built in ${SECONDS}s"

# Install modules to staging dir
OUTDIR="/tmp/kernel-out"
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

echo ">>> Installing modules..."
make modules_install INSTALL_MOD_PATH="$OUTDIR" 2>&1 | tail -5

# Build initramfs with dracut if available
if command -v dracut &>/dev/null; then
    echo ">>> Building initramfs with dracut..."
    dracut --kver "$KERNEL_VERSION" \
        --modules "base kernel-modules" \
        --no-hostonly \
        --force \
        "$OUTDIR/initramfs.img" 2>&1 | tail -10
    echo ">>> initramfs built"
else
    echo ">>> dracut not available, building minimal initramfs with cpio..."
    INITDIR="$OUTDIR/initramfs-root"
    mkdir -p "$INITDIR"/{bin,dev,etc,lib,proc,sys,tmp}
    echo '#!/bin/sh' > "$INITDIR/init"
    echo 'mount -t proc proc /proc' >> "$INITDIR/init"
    echo 'mount -t sysfs sysfs /sys' >> "$INITDIR/init"
    echo 'echo "Kernel booted successfully"' >> "$INITDIR/init"
    echo 'exec /bin/sh' >> "$INITDIR/init"
    chmod +x "$INITDIR/init"
    (cd "$INITDIR" && find . | cpio -o -H newc | gzip > "$OUTDIR/initramfs.img") 2>&1
    echo ">>> Minimal initramfs built"
fi

# Copy artifacts to /output (mounted from host /data)
echo ">>> Copying artifacts to /output..."
cp arch/x86/boot/bzImage /output/ 2>/dev/null || cp arch/$(uname -m)/boot/bzImage /output/ || echo "bzImage path varies by arch"
cp "$OUTDIR/initramfs.img" /output/ 2>/dev/null || echo "No initramfs"
cp .config /output/kernel.config
cp System.map /output/ 2>/dev/null || echo "No System.map"

echo ""
echo "=== Artifacts ==="
ls -lh /output/bzImage /output/initramfs.img /output/kernel.config /output/System.map 2>/dev/null || ls -lh /output/
echo ""
echo "=== Kernel Build Complete ==="
echo "Version: $KERNEL_VERSION"
echo "Date: $(date -u)"
