#!/usr/bin/env bash
# Build script for surya-gaming-kernel (POCO X3 NFC / surya, Android 11)
# Runs inside GitHub Actions (ubuntu-latest). Safe to run locally on a Debian/Ubuntu
# x86_64 box too, as long as build deps from the workflow are installed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$HOME/kbuild}"
KERNEL_REPO="https://github.com/xiaomi-surya-devs/kernel_xiaomi_surya.git"
KERNEL_BRANCH="rethinking"
KERNEL_DIR="$WORK_DIR/kernel"
DEFCONFIG="surya_defconfig"
TC_DIR="$WORK_DIR/clang"
AK3_DIR="$WORK_DIR/AnyKernel3"
OUT_DIR="$ROOT_DIR/out"
ZIP_NAME="surya-gaming-kernel-$(date +%Y%m%d).zip"

log()  { echo -e "\n\033[1;32m[*] $*\033[0m"; }
warn() { echo -e "\n\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\n\033[1;31m[x] $*\033[0m"; exit 1; }

mkdir -p "$WORK_DIR" "$OUT_DIR"

# ---------------------------------------------------------------------------
log "Step 1/8: Cloning kernel source ($KERNEL_BRANCH)"
if [ ! -d "$KERNEL_DIR/.git" ]; then
  git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR" \
    || die "Failed to clone kernel source"
fi
cd "$KERNEL_DIR"

# ---------------------------------------------------------------------------
MEMKERNEL_MODE="${MEMKERNEL_MODE:-Y}"
case "$MEMKERNEL_MODE" in
  Y|N) ;;
  *) die "Invalid MEMKERNEL_MODE='$MEMKERNEL_MODE' (choose Y or N)" ;;
esac
log "Step 1.5/8: Integrating MemKernel (mode $MEMKERNEL_MODE)"
curl -fLSs --retry 3 --retry-delay 2 "https://raw.githubusercontent.com/Poko-Apps/MemKernel/main/kernel/setup.sh" | bash -s "$MEMKERNEL_MODE" \
  || die "MemKernel setup script failed"

# ---------------------------------------------------------------------------
log "Step 2/8: Cloning AOSP Clang toolchain"
if [ ! -d "$TC_DIR/bin" ]; then
  git clone --depth=1 -b 14 https://gitlab.com/ThankYouMario/android_prebuilts_clang-standalone.git "$TC_DIR" \
    || die "Failed to clone clang toolchain"
fi
export PATH="$TC_DIR/bin:$PATH"

log "Full toolchain bin/ listing:"
ls "$TC_DIR/bin"

export CC=clang
export CLANG_TRIPLE="aarch64-linux-gnu-"
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
export CROSS_COMPILE_COMPAT="$CROSS_COMPILE_ARM32"
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export READELF=llvm-readelf
export OBJSIZE=llvm-size
export STRIP=llvm-strip
for tool in ld.lld llvm-ar llvm-nm llvm-objcopy; do
  command -v "$tool" >/dev/null 2>&1 || warn "Expected LLVM tool '$tool' not found in toolchain PATH"
done

SHIM_DIR="$WORK_DIR/binutils-shim"
mkdir -p "$SHIM_DIR"
for prefix in aarch64-linux-gnu aarch64-linux-android arm-linux-gnueabi arm-linux-androideabi; do
  ln -sf "$(command -v ld.lld)"        "$SHIM_DIR/${prefix}-ld"
  ln -sf "$(command -v llvm-ar)"       "$SHIM_DIR/${prefix}-ar"
  ln -sf "$(command -v llvm-nm)"       "$SHIM_DIR/${prefix}-nm"
  ln -sf "$(command -v llvm-objcopy)"  "$SHIM_DIR/${prefix}-objcopy"
  ln -sf "$(command -v llvm-objdump)"  "$SHIM_DIR/${prefix}-objdump"
  ln -sf "$(command -v llvm-strip)"    "$SHIM_DIR/${prefix}-strip"
  ln -sf "$(command -v llvm-readelf)"  "$SHIM_DIR/${prefix}-readelf"
  ln -sf "$(command -v llvm-size)"     "$SHIM_DIR/${prefix}-size"
done
export PATH="$SHIM_DIR:$PATH"

MAKE_ARGS=(
  O=out ARCH=arm64 CC=clang
  CLANG_TRIPLE="$CLANG_TRIPLE"
  CROSS_COMPILE="$CROSS_COMPILE"
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32"
  CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT"
  LD="$LD" AR="$AR" NM="$NM" OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP"
  READELF="$READELF" OBJSIZE="$OBJSIZE" STRIP="$STRIP"
)


log "CROSS_COMPILE=$CROSS_COMPILE  CROSS_COMPILE_ARM32/COMPAT=$CROSS_COMPILE_ARM32  LD=$LD"

KSU_NEXT_REF="b933b1f728116a456fbebf27b6a8772a640cdf23"
log "Step 4/8: Integrating KernelSU-Next (non-GKI / legacy kprobe method), pinned to $KSU_NEXT_REF"
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s "$KSU_NEXT_REF" \
  || die "KernelSU-Next setup script failed"

KSU_DIR=""
for cand in "$KERNEL_DIR/KernelSU-Next" "$KERNEL_DIR/KernelSU"; do
  [ -d "$cand" ] && KSU_DIR="$cand" && break
done
[ -n "$KSU_DIR" ] || die "Could not locate KernelSU-Next source directory after setup"
log "KernelSU-Next source found at: $KSU_DIR"



cd "$KERNEL_DIR"
log "Step 5/7: Applying and validating kernel configuration"
DEFCONFIG_PATH="$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG"
[ -f "$DEFCONFIG_PATH" ] || die "defconfig not found at $DEFCONFIG_PATH"

make "${MAKE_ARGS[@]}" "$DEFCONFIG" || die "defconfig generation failed"
CONFIG_TOOL="$KERNEL_DIR/scripts/config"
CONFIG_FILE="$KERNEL_DIR/out/.config"
[ -x "$CONFIG_TOOL" ] || die "scripts/config is missing or not executable"

"$CONFIG_TOOL" --file "$CONFIG_FILE" --enable MODULES
"$CONFIG_TOOL" --file "$CONFIG_FILE" --enable MODULE_FORCE_LOAD
"$CONFIG_TOOL" --file "$CONFIG_FILE" --enable MODULE_UNLOAD
"$CONFIG_TOOL" --file "$CONFIG_FILE" --enable MODULE_FORCE_UNLOAD
"$CONFIG_TOOL" --file "$CONFIG_FILE" --disable MODULE_SIG
"$CONFIG_TOOL" --file "$CONFIG_FILE" --disable MODULE_SIG_FORCE
"$CONFIG_TOOL" --file "$CONFIG_FILE" --disable MODULE_SIG_ALL

# KernelSU-Next is enabled; SUSFS is intentionally not included in this build.
"$CONFIG_TOOL" --file "$CONFIG_FILE" --enable KSU
"$CONFIG_TOOL" --file "$CONFIG_FILE" --enable KPROBES
"$CONFIG_TOOL" --file "$CONFIG_FILE" --enable KPROBE_EVENTS
"$CONFIG_TOOL" --file "$CONFIG_FILE" --enable IOSCHED_ZEN
"$CONFIG_TOOL" --file "$CONFIG_FILE" --disable DEFAULT_CFQ
"$CONFIG_TOOL" --file "$CONFIG_FILE" --enable DEFAULT_ZEN

make "${MAKE_ARGS[@]}" olddefconfig || die "olddefconfig failed"

for option in MODULES MODULE_FORCE_LOAD MODULE_UNLOAD MODULE_FORCE_UNLOAD KSU; do
  grep -qx "CONFIG_${option}=y" "$CONFIG_FILE" || die "Required config CONFIG_${option}=y was not accepted"
done
grep -qx "# CONFIG_MODULE_SIG is not set" "$CONFIG_FILE" || die "CONFIG_MODULE_SIG must be disabled"
if grep -Eq '^CONFIG_MODULE_SIG_(FORCE|ALL)=y$' "$CONFIG_FILE"; then
  die "Module signature enforcement/signing must remain disabled"
fi
grep -qx 'CONFIG_DEFAULT_IOSCHED="zen"' "$CONFIG_FILE" || die "Zen was not selected as the default I/O scheduler"
log "KernelSU-Next, module settings and Zen config validated (SUSFS excluded)"

log "Step 6/7: Building kernel"
cd "$KERNEL_DIR"
mkdir -p out
MAKE_ARGS=(
  O=out ARCH=arm64 CC=clang
  CLANG_TRIPLE="$CLANG_TRIPLE"
  CROSS_COMPILE="$CROSS_COMPILE"
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32"
  CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT"
  LD="$LD" AR="$AR" NM="$NM" OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP"
  READELF="$READELF" OBJSIZE="$OBJSIZE" STRIP="$STRIP"
)
make "${MAKE_ARGS[@]}" CONFIG_DEBUG_SECTION_MISMATCH=y -j"$(nproc)" 2>&1 | tee "$OUT_DIR/build.log" || die "Kernel build failed, see build.log"

IMAGE="out/arch/arm64/boot/Image.gz"
DTB="out/arch/arm64/boot/dts/qcom/sdmmagpie.dtb"
DTBO="out/arch/arm64/boot/dtbo.img"
for f in "$IMAGE" "$DTB" "$DTBO"; do
  [ -f "$f" ] || die "Expected build output missing: $f (build likely failed partway, check build.log)"
done
log "Kernel compiled successfully"

log "Step 7/7: Packaging flashable ZIP (AnyKernel3)"
git clone -q --depth=1 -b surya https://github.com/ragy365/AnyKernel3.git "$AK3_DIR" \
  || die "Failed to clone AnyKernel3"

cp "$IMAGE" "$DTBO" "$AK3_DIR/"
cp "$DTB" "$AK3_DIR/dtb"

cd "$AK3_DIR"
zip -r9 "$OUT_DIR/$ZIP_NAME" . -x '.git*' 'README.md' '*placeholder' \
  || die "Zipping failed"

log "DONE. Flashable zip: $OUT_DIR/$ZIP_NAME"
log "Verified: KernelSU-Next enabled; SUSFS intentionally excluded."
