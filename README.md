# Poco X3 NFC kernel — GitHub Actions

Workflow untuk membangun **StormBreaker v8 (Linux 4.14.117)** untuk `surya/karna`, dengan:

- KernelSU-Next non-GKI SUSFS integration yang kompatibel dengan kernel 4.14;
- SUSFS non-GKI backport terbaru yang dipin;
- konfigurasi module sesuai foto;
- output `Image.gz-dtb` dan ZIP AnyKernel3.

## Status

Recipe ini dipush ke branch `stormbreaker-v8-ksunext-susfs`. Jalankan **Actions → Build Poco X3 NFC kernel → Run workflow** pada branch tersebut.

## Kenapa pin KernelSU-Next khusus?

KernelSU-Next resmi `v3.4.x` sudah tidak membawa source integration SUSFS non-GKI lama. Untuk kernel 4.14, build membutuhkan commit SUSFS-compatible `ba4422f...` (digunakan oleh proyek kernel non-GKI Surya/Ginkgo). Ini bukan pemakaian KSU jadul acak; ini adalah pin kompatibilitas agar KSU-Next + SUSFS benar-benar bisa masuk ke kernel 4.14.117.

SUSFS core dan inline hooks dipin dari `JackA1ltman/NonGKI_Kernel_Build_2nd` pada commit yang memuat patch 4.14 terbaru saat recipe dibuat.

## Cara memakai

```sh
git init
git add .
git commit -m "Add Poco X3 kernel GitHub Action"
git branch -M main
git remote add origin https://github.com/USERNAME/REPO.git
git push -u origin main
```

Jangan memasukkan token GitHub ke file atau chat. Jika repository private, Actions tetap dapat berjalan sesuai kuota akunmu.

## Hasil Action

Artifact berisi:

- `poco-x3-stormbreaker-v8-ksunext-susfs.zip` — ZIP AnyKernel3 kernel-only;
- file `.sha256`;
- `Image.gz-dtb` mentah;
- `.config` hasil akhir.

Workflow gagal jika patch SUSFS meninggalkan `.rej` atau Kconfig menghapus opsi penting.

## Konfigurasi module dari foto

Fragment [`config/surya-susfs.config`](config/surya-susfs.config) meminta:

```text
CONFIG_MODULES=y
CONFIG_MODULE_FORCE_LOAD=y
CONFIG_MODULE_UNLOAD=y
CONFIG_MODULE_FORCE_UNLOAD=y
# CONFIG_MODULE_SIG is not set
# CONFIG_MODULE_SIG_FORCE is not set
# CONFIG_MODULE_SIG_ALL is not set
```

Kconfig Linux menulis nilai `n` sebagai `# CONFIG_* is not set`; itu ekuivalen dengan `CONFIG_* = n`.

## Peringatan flashing

- Backup partisi `boot` terlebih dahulu dan siapkan recovery/fastboot untuk rollback.
- Unlock bootloader dan kecocokan ROM/vendor wajib diperiksa sendiri.
- ZIP ini mengganti kernel saja dan mempertahankan ramdisk/DTB/DTBO perangkat.
- Kernel custom dapat menyebabkan bootloop atau brick. Uji hanya pada perangkat milikmu.
- SUSFS adalah fitur tingkat kernel eksperimental; jangan gunakan untuk melewati keamanan atau aturan aplikasi pihak ketiga.
