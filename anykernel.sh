### AnyKernel3 Ramdisk Mod Script
## Kernel-only updater for Poco X3 NFC / surya / karna.

properties() { '
kernel.string=StormBreaker v8 + KernelSU-Next + SUSFS
maintainer.string1=Local build
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=1
device.name1=surya
device.name2=karna
supported.versions=10
'; }

BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

# Preserve the phone's existing ramdisk, DTB and DTBO.
split_boot;
flash_boot;
