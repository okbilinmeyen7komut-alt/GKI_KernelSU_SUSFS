#!/bin/bash
# KM4n GKI cekirdek derlemesi: BDerleme (CT 10062) uzerinde self-hosted bash karsiligi.
# GitHub Actions'taki main.yml + build.yml + prepare.yml + composite action'larin
# (root-setup, susfs-setup, bbg, bbrv3, ptrace, build-kernel) bu host icin birebir
# cevirisidir; act Docker-in-LXC nesting sorunu yuzunden burada calismadigindan
# dogrudan bash ile yurutulur. BB-G-1328 RED tur 1 sonrasi: builtin 6c284e95 pini,
# KPM patch_linux adimi ve kaynak sinirlamalari (nice/ionice, /tmp'siz) eklendi.
#
# Varsayimlar:
# - /root/derleme/km4n-gki altinda zaten bu fork klonlanmis ve kernel/.repo (AOSP
#   repo manifest) senkronize edilmis olmali (ilk kurulum: bu betigin "repo init/sync"
#   adimi). Mevcutsa tekrar sync edilmez (idempotent).
# - Araclar (bazel, repo, git, gawk) BDerleme'de kurulu.
# - Calisma dizini tamamen /root/derleme/km4n-gki altinda kalir, /tmp kullanilmaz.
set -euo pipefail

WORK=/root/derleme/km4n-gki
KERNEL_DIR="$WORK/kernel"
KERNEL_PATCHES="$WORK/kernel_patches"
ANYKERNEL3="$WORK/AnyKernel3"
KPM_DIR="$WORK/kpm-patch"

# --- Sabitler (BB-G-1328 kok neden duzeltmesi) ---
ANDROID_VERSION="android15"
KERNEL_VERSION="6.6"
OS_PATCH_LEVEL="2025-02"
KERNEL_BRANCH="${ANDROID_VERSION}-${KERNEL_VERSION}-${OS_PATCH_LEVEL}"
# SukiSU-Ultra: main degil, builtin dali (SUSFS kancalari builtin'de).
# b20dee70 (main, 13 Eyl) yanlisti -> ld.lld: undefined symbol: ksu_handle_post_execveat_sucompat
SUKISU_ULTRA_COMMIT="6c284e957feaa9a388a9f1c37dc4ec80d95e434b"
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="gki-${ANDROID_VERSION}-${KERNEL_VERSION}"
SUSFS_COMMIT="a0f9c59e2243f8a5db955f4ad1686d5e0ad26e1a"   # susfs_commit_android15_6_6 pin (main.yml)
KPM_PATCH_VER="0.13.0"

NICE="nice -n 19 ionice -c3"
BAZEL_JOBS="--jobs=32"

echo "[1/9] Kernel kaynak agaci (repo init/sync, deprecated/ branch duzeltmesiyle)"
mkdir -p "$KERNEL_DIR"
cd "$KERNEL_DIR"
if [ ! -d .repo ]; then
  repo init -u https://android.googlesource.com/kernel/manifest -b "common-${KERNEL_BRANCH}" --depth=1
  KERNEL_COMMON_URL="https://android.googlesource.com/kernel/common"
  if ! git ls-remote --exit-code --heads "$KERNEL_COMMON_URL" "refs/heads/common-${KERNEL_BRANCH}" >/dev/null 2>&1; then
    if git ls-remote --exit-code --heads "$KERNEL_COMMON_URL" "refs/heads/deprecated/common-${KERNEL_BRANCH}" >/dev/null 2>&1; then
      echo "  [Fix] kernel/common ${KERNEL_BRANCH} deprecated/ altina tasinmis, manifest override ekleniyor"
      mkdir -p .repo/local_manifests
      cat > .repo/local_manifests/fix_common_deprecated.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remove-project name="kernel/common" />
  <project path="common" name="kernel/common"
           revision="deprecated/common-${KERNEL_BRANCH}"
           upstream="deprecated/common-${KERNEL_BRANCH}"
           dest-branch="deprecated/common-${KERNEL_BRANCH}" />
</manifest>
EOF
    fi
  fi
  $NICE repo sync -c -j4 --fail-fast
else
  echo "  .repo zaten var, atlaniyor (yeniden senkron icin: rm -rf $KERNEL_DIR/.repo)"
fi

echo "[2/9] SukiSU-Ultra builtin dali, sabit commit $SUKISU_ULTRA_COMMIT"
cd "$KERNEL_DIR"
if [ ! -d drivers/kernelsu ] && [ ! -d common/drivers/kernelsu ]; then
  if [ -d common/drivers ]; then DRIVERS_DIR="common/drivers"; else DRIVERS_DIR="drivers"; fi
  if [ ! -d SukiSU-Ultra ]; then
    git clone --no-checkout https://github.com/SukiSU-Ultra/SukiSU-Ultra.git SukiSU-Ultra
  fi
  git -C SukiSU-Ultra fetch --depth=1 origin "$SUKISU_ULTRA_COMMIT"
  git -C SukiSU-Ultra checkout --detach "$SUKISU_ULTRA_COMMIT"
  actual="$(git -C SukiSU-Ultra rev-parse HEAD)"
  [ "$actual" = "$SUKISU_ULTRA_COMMIT" ] || { echo "SukiSU-Ultra commit uyusmuyor: $actual" >&2; exit 1; }
  rel="$(realpath --relative-to="$DRIVERS_DIR" "$PWD/SukiSU-Ultra/kernel")"
  ln -sf "$rel" "$DRIVERS_DIR/kernelsu"
  grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$DRIVERS_DIR/Makefile" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRIVERS_DIR/Makefile"
  grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVERS_DIR/Kconfig" || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$DRIVERS_DIR/Kconfig"
else
  echo "  kernelsu symlink zaten var, atlaniyor"
fi

echo "[3/9] susfs4ksu patch (pin $SUSFS_COMMIT, dal $SUSFS_BRANCH)"
cd "$WORK"
if [ ! -d susfs4ksu/.git ]; then
  git clone -b "$SUSFS_BRANCH" "$SUSFS_REPO" susfs4ksu
fi
git -C susfs4ksu fetch -q origin
git -C susfs4ksu reset -q --hard "$SUSFS_COMMIT"
cd "$KERNEL_DIR/common"
if ! grep -q "SUSFS_VERSION" fs/susfs.c 2>/dev/null; then
  cp "$WORK/susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch" .
  patch -p1 -F 3 < "50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch"
  patch -p1 -F 3 < "$WORK/susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" || true
else
  echo "  susfs zaten uygulanmis, atlaniyor"
fi

echo "[4/9] Baseband-guard (mawk->gawk duzeltmesiyle)"
cd "$KERNEL_DIR"
if [ ! -d Baseband-guard ]; then
  # Debian/Trixie varsayilan awk=mawk, setup.sh gawk sozdizimi (gensub vb.) kullaniyor.
  # update-alternatives ile awk->gawk zorunlu, yoksa setup.sh sessizce hatali calisir.
  if ! command -v gawk >/dev/null 2>&1; then apt-get install -y gawk; fi
  update-alternatives --set awk /usr/bin/gawk 2>/dev/null || true
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 \
    https://raw.githubusercontent.com/vc-teahouse/Baseband-guard/main/setup.sh | bash
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' common/security/Kconfig
else
  echo "  Baseband-guard zaten kurulu, atlaniyor"
fi

echo "[5/9] BBRv3 (networking) patch - android15-6.6"
cd "$KERNEL_DIR/common"
# cwd fix: patch working-directory daima kernel/common olmali (onceki hata: yanlis cwd'den patch -p1 cagrildi)
if ! grep -q "CONFIG_TCP_CONG_BBR3" net/ipv4/Kconfig 2>/dev/null; then
  patch -p1 < "$KERNEL_PATCHES/common/bbrv3/0001-net-tcp-backport-BBRv3-to-${ANDROID_VERSION}-${KERNEL_VERSION}.patch" || true
fi

echo "[6/9] Ptrace uyumluluk yamasi - yalniz kernel < 5.16 icin (6.6 ATLANIR)"
cd "$KERNEL_DIR/common"
MIN_VERSION="5.16"
if [ "$(printf '%s\n' "$KERNEL_VERSION" "$MIN_VERSION" | sort -V | head -n1)" = "$KERNEL_VERSION" ] && [ "$KERNEL_VERSION" != "$MIN_VERSION" ]; then
  echo "  Patching ptrace!"
  patch -p1 -F 3 < "$KERNEL_PATCHES/gki_ptrace.patch"
else
  echo "  Kernel >= $MIN_VERSION, ptrace yamasi atlandi (onceki hata: yanlis uygulanmisti)"
fi

echo "[7/9] Kernel config: KPM + SukiSU builtin + susfs"
GKI_DEFCONFIG="$KERNEL_DIR/common/arch/arm64/configs/gki_defconfig"
for cfg in CONFIG_KSU=y CONFIG_KPM=y CONFIG_KSU_SUSFS=y CONFIG_KSU_SUSFS_SUS_PATH=y \
           CONFIG_KSU_SUSFS_SUS_MOUNT=y CONFIG_KSU_SUSFS_SUS_KSTAT=y CONFIG_KSU_SUSFS_SPOOF_UNAME=y \
           CONFIG_KSU_SUSFS_ENABLE_LOG=y CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y \
           CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y CONFIG_KSU_SUSFS_OPEN_REDIRECT=y \
           CONFIG_KSU_SUSFS_SUS_MAP=y CONFIG_TCP_CONG_BBR3=y CONFIG_BBG=y; do
  grep -qxF "$cfg" "$GKI_DEFCONFIG" || echo "$cfg" >> "$GKI_DEFCONFIG"
done

echo "[8/9] Bazel build (nice/ionice, --jobs=32, host boguculugu sinirli)"
cd "$KERNEL_DIR"
$NICE tools/bazel run --config=fast --lto=thin //common:kernel_aarch64_dist -- --destdir=dist $BAZEL_JOBS \
  || $NICE tools/bazel run --config=fast --lto=thin //common:kernel_aarch64 $BAZEL_JOBS

RAW_IMAGE="$(find "$KERNEL_DIR/out" -path '*kernel_aarch64/Image' -type f 2>/dev/null | head -1)"
[ -n "$RAW_IMAGE" ] || { echo "Image bulunamadi, build basarisiz" >&2; exit 1; }
echo "  Ham Image: $RAW_IMAGE ($(sha256sum "$RAW_IMAGE" | cut -d' ' -f1))"

echo "[9/9] KPM yamasi (patch_linux) + AnyKernel3 paketleme"
mkdir -p "$KPM_DIR/work"
cp "$RAW_IMAGE" "$KPM_DIR/work/Image"
if [ ! -f "$KPM_DIR/patch_linux-$KPM_PATCH_VER" ]; then
  curl -LSs -o "$KPM_DIR/patch_linux-$KPM_PATCH_VER" \
    "https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/$KPM_PATCH_VER/patch_linux"
fi
cp "$KPM_DIR/patch_linux-$KPM_PATCH_VER" "$KPM_DIR/work/patch_linux"
chmod 755 "$KPM_DIR/work/patch_linux"
( cd "$KPM_DIR/work" && ./patch_linux )
[ -f "$KPM_DIR/work/oImage" ] || { echo "KPM yamasi basarisiz: oImage yok" >&2; exit 1; }
mv "$KPM_DIR/work/Image" "$KPM_DIR/work/Image.orig"
mv "$KPM_DIR/work/oImage" "$KPM_DIR/work/Image"
echo "  KPM yamali Image: $(sha256sum "$KPM_DIR/work/Image" | cut -d' ' -f1)"

mkdir -p "$ANYKERNEL3"
cp "$KPM_DIR/work/Image" "$ANYKERNEL3/Image"
cd "$ANYKERNEL3"
ZIP_NAME="KM4n-${KERNEL_VERSION}.66-${ANDROID_VERSION}-${OS_PATCH_LEVEL}-SukiSU-Ultra-SUSFS-KPM-Wild.zip"
rm -f ./*.zip
zip -r "$ZIP_NAME" . -x '.git/*' -x '*.zip'

echo "Tamamlandi. Cikti: $KPM_DIR/work/Image (KPM yamali) + $ANYKERNEL3/*.zip"
echo "Kalici konuma kopyala: /root/burgaz-bilisim/telefon/km4n/root-paket/cekirdek/ (ct102, aktarim /root/bb-aktarim uzerinden)"
