#!/usr/bin/env bash
# StormBreaker v8 (POCO X3 NFC / surya) + KernelSU-Next + SUSFS + MemKernel
# Dijalankan di GitHub Actions ubuntu-22.04.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$HOME/kbuild-sb}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/stormbreaker-project/kernel_xiaomi_surya.git}"
KERNEL_REF="${KERNEL_REF:-v8}"
DEFCONFIG="${DEFCONFIG:-surya-perf_defconfig}"
KSU_NEXT_REF="${KSU_NEXT_REF:-v3.4.2}"
SUSFS_REPO="${SUSFS_REPO:-https://github.com/ShirkNeko/susfs4ksu.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-kernel-4.14}"
MEMKERNEL_MODE="${MEMKERNEL_MODE:-Y}"

KERNEL_DIR="$WORK_DIR/kernel"
SUSFS_DIR="$WORK_DIR/susfs4ksu"
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
grep -m1 -A2 '^VERSION' Makefile

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
    src="$(command -v llvm-$t 2>/dev/null || command -v $( [ "$t" = ld ] && echo ld.lld || echo llvm-$t))"
    [ -n "$src" ] && ln -sf "$src" "$SHIM_DIR/${prefix}-${t}"
  done
done
export PATH="$SHIM_DIR:$PATH"

# ---------------------------------------------------------------- 3. KSU-Next
log "3/9: Integrasi KernelSU-Next $KSU_NEXT_REF"
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" \
  | bash -s "$KSU_NEXT_REF" || die "KernelSU-Next setup gagal"

KSU_DIR=""
for cand in "$KERNEL_DIR/KernelSU-Next" "$KERNEL_DIR/KernelSU"; do
  [ -d "$cand" ] && KSU_DIR="$cand" && break
done
[ -n "$KSU_DIR" ] || die "folder KernelSU-Next tidak ditemukan"
log "KSU source: $KSU_DIR"

# ---------------------------------------------------------------- 4. SUSFS
log "4/9: Integrasi SUSFS ($SUSFS_BRANCH)"
git clone -q --depth=1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" "$SUSFS_DIR" || die "gagal clone SUSFS"

cp "$SUSFS_DIR/kernel_patches/fs/susfs.c" "$KERNEL_DIR/fs/"
cp "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" "$KERNEL_DIR/include/linux/"
[ -f "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" ] && \
  cp "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/"

# Kernel 4.14 belum punya include/linux/bits.h (baru ada di 5.x); SUSFS cuma butuh BIT().
if [ ! -f "$KERNEL_DIR/include/linux/bits.h" ]; then
  log "tambah shim include/linux/bits.h (4.14)"
  cat > "$KERNEL_DIR/include/linux/bits.h" <<'EOF'
#ifndef _LINUX_BITS_H
#define _LINUX_BITS_H
#include <linux/bitops.h>
#ifndef BIT_ULL
#define BIT_ULL(nr) (1ULL << (nr))
#endif
#endif
EOF
fi

cd "$KERNEL_DIR"
log "patch kernel SUSFS"
patch -p1 --batch --forward --fuzz=3 < "$SUSFS_DIR/kernel_patches/50_add_susfs_in_kernel-4.14.patch" \
  || warn "ada hunk kernel SUSFS yang ditolak (.rej)"
find . -name '*.rej' -maxdepth 4 2>/dev/null | head -20 || true

log "patch KernelSU-Next untuk SUSFS"
cd "$KSU_DIR"
patch -p1 --batch --forward --fuzz=3 < "$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" \
  || warn "ada hunk KSU SUSFS yang ditolak (.rej)"
find . -name '*.rej' -maxdepth 3 2>/dev/null | head -20 || true

grep -q 'susfs' "$KERNEL_DIR/fs/Makefile" || die "SUSFS tidak terpasang di fs/Makefile"

# ---------------------------------------------------------------- 5. MemKernel
log "5/9: Integrasi MemKernel (mode $MEMKERNEL_MODE)"
cd "$KERNEL_DIR"
curl -fLSs --retry 3 "https://raw.githubusercontent.com/Poko-Apps/MemKernel/main/kernel/setup.sh" \
  | bash -s "$MEMKERNEL_MODE" || die "MemKernel setup gagal"

# ---------------------------------------------------------------- 6. config
log "6/9: Konfigurasi (defconfig $DEFCONFIG + tuning gaming)"
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
sc --enable THREAD_INFO_IN_TASK
# SUSFS
for o in KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT \
         KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
         KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP; do
  sc --enable "$o"
done
# ringan & gaming
sc --disable DEBUG_INFO
sc --disable DEBUG_KERNEL
sc --disable SLUB_DEBUG
sc --disable KASAN
sc --enable ZRAM
sc --enable ZRAM_LZ4_COMPRESS
sc --enable CRYPTO_LZ4
sc --enable LZ4_COMPRESS
sc --enable LZ4_DECOMPRESS
sc --enable TCP_CONG_BBR
sc --enable DEFAULT_BBR
sc --set-str DEFAULT_TCP_CONG "bbr"
sc --enable IOSCHED_ZEN
sc --disable DEFAULT_CFQ
sc --enable DEFAULT_ZEN
sc --enable CPU_FREQ_DEFAULT_GOV_SCHEDUTIL
sc --set-str DEFAULT_IOSCHED "zen"
sc --set-str LOCALVERSION "-StormBreaker-KSUNext"

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
