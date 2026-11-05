#!/usr/bin/env bash
# StormBreaker v8 (POCO X3 NFC / surya, kernel 4.14.117) +
# KernelSU-Next v1.1.1 + SUSFS 1.4.2 + MemKernel.
# Dijalankan di GitHub Actions ubuntu-22.04.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$HOME/kbuild-sb}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/stormbreaker-project/kernel_xiaomi_surya.git}"
KERNEL_REF="${KERNEL_REF:-v8}"
DEFCONFIG="${DEFCONFIG:-surya-perf_defconfig}"
KSU_NEXT_REF="${KSU_NEXT_REF:-v1.1.1}"
MEMKERNEL_MODE="${MEMKERNEL_MODE:-Y}"

PATCH_DIR="$ROOT_DIR/patches/susfs"
KERNEL_DIR="$WORK_DIR/kernel"
TC_DIR="$WORK_DIR/clang"
AK3_DIR="$WORK_DIR/AnyKernel3"
OUT_DIR="$ROOT_DIR/out"
ZIP_NAME="StormBreaker-v8-surya-MemK${MEMKERNEL_MODE}-$(date +%Y%m%d).zip"

log()  { echo -e "\n\033[1;32m[*] $*\033[0m"; }
warn() { echo -e "\n\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\n\033[1;31m[x] $*\033[0m"; exit 1; }

mkdir -p "$WORK_DIR" "$OUT_DIR"

# ---------------------------------------------------------------- 1. source
log "1/9: Clone StormBreaker $KERNEL_REF"
if [ ! -d "$KERNEL_DIR/.git" ]; then
  git clone --depth=1 --single-branch -b "$KERNEL_REF" "$KERNEL_REPO" "$KERNEL_DIR" \
    || die "gagal clone kernel"
fi
cd "$KERNEL_DIR"
grep -m1 -A3 '^VERSION' Makefile | head -4

# ---------------------------------------------------------------- 2. clang
log "2/9: Siapkan Clang"
if [ ! -d "$TC_DIR/bin" ]; then
  git clone --depth=1 -b 14 https://gitlab.com/ThankYouMario/android_prebuilts_clang-standalone.git "$TC_DIR" \
    || die "gagal clone clang"
fi
export PATH="$TC_DIR/bin:$PATH"
export CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- \
       CROSS_COMPILE_ARM32=arm-linux-gnueabi- LD=ld.lld AR=llvm-ar NM=llvm-nm \
       OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf \
       OBJSIZE=llvm-size STRIP=llvm-strip

SHIM_DIR="$WORK_DIR/binutils-shim"; mkdir -p "$SHIM_DIR"
for prefix in aarch64-linux-gnu aarch64-linux-android arm-linux-gnueabi arm-linux-androideabi; do
  for t in ld ar nm objcopy objdump strip readelf size; do
    src="$(command -v llvm-$t 2>/dev/null || true)"
    [ -z "$src" ] && [ "$t" = ld ] && src="$(command -v ld.lld 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$SHIM_DIR/${prefix}-${t}"
  done
done
export PATH="$SHIM_DIR:$PATH"

# ---------------------------------------------------------------- 3. KSU-Next
log "3/9: Integrasi KernelSU-Next $KSU_NEXT_REF"
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" \
  | bash -s "$KSU_NEXT_REF" || die "KernelSU-Next setup gagal"

KSU_ROOT="$KERNEL_DIR/KernelSU-Next"
[ -d "$KSU_ROOT/kernel" ] || die "folder KernelSU-Next tidak ditemukan"
log "KSU source: $KSU_ROOT/kernel -> drivers/kernelsu"

# ---------------------------------------------------------------- 4. SUSFS
log "4/9: Integrasi SUSFS 1.4.2 (kernel + KSU)"
[ -f "$PATCH_DIR/50_add_susfs_in_kernel-4.14.patch" ] || die "patch SUSFS kernel hilang"
[ -f "$PATCH_DIR/10_enable_susfs_for_ksu-next.patch" ] || die "patch SUSFS ksu hilang"

# kernel-side: susfs.c + header + fs patch
cp "$PATCH_DIR/susfs.c" "$KERNEL_DIR/fs/"
cp "$PATCH_DIR/susfs.h" "$KERNEL_DIR/include/linux/"
cd "$KERNEL_DIR"
log "patch kernel SUSFS"
patch -p1 --batch --forward < "$PATCH_DIR/50_add_susfs_in_kernel-4.14.patch" \
  || die "patch kernel SUSFS gagal"
grep -q 'CONFIG_KSU_SUSFS' fs/Makefile || die "SUSFS tidak terpasang di fs/Makefile"

# ksu-side: patch KSU-Next (dari root repo KSU-Next)
log "patch KernelSU-Next untuk SUSFS"
cd "$KSU_ROOT"
patch -p1 --batch --forward < "$PATCH_DIR/10_enable_susfs_for_ksu-next.patch" \
  || die "patch KSU SUSFS gagal"
grep -q 'KSU_SUSFS' kernel/Kconfig || die "KSU_SUSFS tidak ada di Kconfig"

# ---------------------------------------------------------------- 5. MemKernel
log "5/9: Integrasi MemKernel (mode $MEMKERNEL_MODE)"
cd "$KERNEL_DIR"
curl -fLSs --retry 3 "https://raw.githubusercontent.com/Poko-Apps/MemKernel/main/kernel/setup.sh" \
  | bash -s "$MEMKERNEL_MODE" || die "MemKernel setup gagal"

# ---------------------------------------------------------------- 6. config
log "6/9: Konfigurasi (defconfig $DEFCONFIG + tuning ringan/gaming)"
MAKE_ARGS=(O=out ARCH=arm64 SUBARCH=arm64)
make "${MAKE_ARGS[@]}" "$DEFCONFIG" || die "defconfig gagal"

CFG="$KERNEL_DIR/out/.config"
sc() { "$KERNEL_DIR/scripts/config" --file "$CFG" "$@"; }

# root & module
sc --enable KSU
sc --enable KPROBES
sc --enable KPROBE_EVENTS
sc --enable MODULES
sc --disable MODULE_SIG
sc --disable MODULE_SIG_ALL
sc --disable MODULE_SIG_FORCE
# SUSFS (1.4.2: tanpa SUS_SU yang tidak kompatibel dengan KSU-Next v1.1.1)
for o in KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT \
         KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG; do
  sc --enable "$o"
done
# ringan & gaming
sc --enable TCP_CONG_BBR
sc --enable DEFAULT_BBR
sc --set-str DEFAULT_TCP_CONG "bbr"
sc --set-str ZRAM_DEFAULT_COMP_ALGORITHM "lz4"
sc --set-str LOCALVERSION "-StormBreaker-KSUNext-SUSFS"

make "${MAKE_ARGS[@]}" olddefconfig || die "olddefconfig gagal"

for opt in KSU KPROBES KSU_SUSFS ZRAM; do
  grep -qx "CONFIG_${opt}=y" "$CFG" || die "CONFIG_${opt} tidak diterima kernel"
done
log "config valid: KSU + SUSFS + ZRAM aktif"

# ---------------------------------------------------------------- 7. build
log "7/9: Compile kernel"
mkdir -p out
make "${MAKE_ARGS[@]}" -j"$(nproc)" CONFIG_DEBUG_SECTION_MISMATCH=y 2>&1 | tee "$OUT_DIR/build.log" \
  || die "build gagal, lihat build.log"

# ---------------------------------------------------------------- 8. output
log "8/9: Kumpulkan image"
BOOT="out/arch/arm64/boot"
ls -lh "$BOOT" | head -20 || true
IMG=""
for f in "$BOOT/Image.gz-dtb" "$BOOT/Image.gz" "$BOOT/Image"; do
  [ -f "$f" ] && IMG="$f" && break
done
[ -n "$IMG" ] || die "Image tidak ditemukan"
DTB="$(find "$BOOT/dts" -name '*.dtb' 2>/dev/null | head -1 || true)"
DTBO="$BOOT/dtbo.img"
log "Image: $IMG | dtb: ${DTB:-tidak ada} | dtbo: $([ -f "$DTBO" ] && echo ada || echo tidak ada)"

# ---------------------------------------------------------------- 9. package
log "9/9: Bungkus AnyKernel3"
git clone -q --depth=1 -b surya https://github.com/ragy365/AnyKernel3.git "$AK3_DIR" \
  || die "gagal clone AnyKernel3"
cp "$IMG" "$AK3_DIR/Image.gz"
[ -n "$DTB" ] && [ -f "$DTB" ] && cp "$DTB" "$AK3_DIR/dtb"
[ -f "$DTBO" ] && cp "$DTBO" "$AK3_DIR/dtbo.img"
( cd "$AK3_DIR" && zip -r9 "$OUT_DIR/$ZIP_NAME" . -x '.git*' 'README.md' '*placeholder' ) \
  || die "zip gagal"

log "SELESAI: $OUT_DIR/$ZIP_NAME"
