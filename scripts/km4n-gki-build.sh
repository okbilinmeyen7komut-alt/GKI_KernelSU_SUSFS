#!/bin/bash
# KM4n (android15-6.6, SukiSU-Ultra + SUSFS + KPM) GKI cekirdek derlemesi.
#
# Bu betik, fork okbilinmeyen7komut-alt/GKI_KernelSU_SUSFS'teki GitHub Actions
# hattinin (.github/workflows/main.yml -> build.yml ve bunlarin composite
# action'lari) "SukiSU-Ultra, android15-6.6, 2025-02, Normal, FEATURE_SET=
# SUSFS+NoMount+BBG+NET+DS+NTSync+Ptrace+Unicode+BPF" satirinin BIREBIR bash
# karsiligidir. Her bolum basligi, karsiladigi composite action'in adini tasir
# (ör. "== root-setup ==" -> .github/actions/root-setup/action.yml) boylece
# denetlenebilir: hangi bash bloğunun hangi action'a karsilik geldigi acik.
#
# BDerleme (CT 10062) uzerinde calisir. /tmp KULLANILMAZ, hepsi $WORKSPACE
# altinda. GitHub Actions'taki `github.workspace` = bizim $WORKSPACE/kernel
# (actions cogu `working-directory: .../kernel` ile baslar), ust klasorler
# (kernel_patches, AnyKernel3, susfs4ksu, Droidspaces-OSS) $WORKSPACE altinda.
#
# Kok neden (BB-G-1328, dogrulandi): SukiSU-Ultra 'main' dali degil 'builtin'
# dali pinlenmeli (SUSFS'in exec.c yamasi ksu_handle_post_execveat_sucompat
# sembolunu `main`'de degil `builtin`'de buluyor). main.yml PIN_SUKISU_ULTRA
# zaten builtin'in tepesine cekildi (commit 59c908d, bu betikle ayni commit).
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

WORKSPACE="/root/derleme/km4n-gki"
ANDROID_VERSION="android15"
KERNEL_VERSION="6.6"
VERSION="${ANDROID_VERSION}-${KERNEL_VERSION}"
OS_PATCH_LEVEL="2025-02"
VARIANT="Normal"
SUBLEVEL="66"                      # kernel/common Makefile SUBLEVEL (manifest tepesinde dogrulandi)
FEATURE_SET="SUSFS+NoMount+BBG+NET+DS+NTSync+Ptrace+Unicode+BPF"
ROOT_FLAVOR="sukisu-ultra"
ROOT_COMMIT="6c284e957feaa9a388a9f1c37dc4ec80d95e434b"      # main.yml PIN_SUKISU_ULTRA (builtin dali tepesi)
SUSFS_COMMIT="a0f9c59e2243f8a5db955f4ad1686d5e0ad26e1a"      # main.yml PIN_SUSFS_SUKISU_ULTRA[android15_6_6]
NOMOUNT_COMMIT="5a610db7649a59eb3e3d710653618d594941f8da"    # main.yml PIN_NOMOUNT
BRAND_NAME="Wild"
KEEP_KMI="false"
PAGE_SIZE="4k"
MANIFEST_RESET_REV="912f90e81c3e"   # kernel/common'in repo-sync (manifest) tepesi, patch'siz hali

echo "=== Parametreler ==="
echo "VERSION=$VERSION OS_PATCH_LEVEL=$OS_PATCH_LEVEL SUBLEVEL=$SUBLEVEL FEATURE_SET=$FEATURE_SET"
echo "ROOT_COMMIT=$ROOT_COMMIT SUSFS_COMMIT=$SUSFS_COMMIT NOMOUNT_COMMIT=$NOMOUNT_COMMIT"

retry() {
  local n=0
  until [ "$n" -ge 5 ]; do
    "$@" && return 0
    n=$((n + 1))
    echo "retry $n/5 failed for: $*" >&2
    sleep 5
  done
  return 1
}

apply_cfg() {
  # set-kernel-config action.yml karsiligi: gki_defconfig'e dogrudan yaz.
  local defconfig="$WORKSPACE/kernel/common/arch/arm64/configs/gki_defconfig"
  local key value
  while IFS= read -r line; do
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == *"="* ]]; then key="${line%%=*}"; value="${line#*=}"; else key="$line"; value="y"; fi
    if grep -q "^$key=" "$defconfig"; then
      sed -i "s|^$key=.*|$key=$value|g" "$defconfig"
    elif grep -q "^# $key is not set" "$defconfig"; then
      sed -i "s|^# $key is not set|$key=$value|g" "$defconfig"
    else
      echo "$key=$value" >> "$defconfig"
    fi
  done <<< "$1"
}

mkdir -p "$WORKSPACE/kernel"
cd "$WORKSPACE"
git config --global user.name "zekai-bb-derleme"
git config --global user.email "zekai@burgazbilisim.com.tr"

echo "=== [0/21] kernel/common manifest durumuna sifirlaniyor (temiz deneme) ==="
if [ -d "$WORKSPACE/kernel/common/.git" ]; then
  cd "$WORKSPACE/kernel/common"
  CURRENT_HEAD="$(git rev-parse HEAD)"
  if [ "$CURRENT_HEAD" != "$MANIFEST_RESET_REV" ]; then
    # Bilinen-iyi onceki durumu (denetci tur-2'de dogruladigi agac) kaybetmemek
    # icin once bir yedek dal olarak isaretle (zaten varsa dokunma).
    git branch backup-bbg1328-onceki-iyi-agac "$CURRENT_HEAD" 2>/dev/null || true
    git reset --hard "$MANIFEST_RESET_REV"
  fi
  git clean -fdx
  echo "kernel/common HEAD: $(git log -1 --format='%h %s')"
else
  echo "HATA: kernel/common yok, bu betik 'temiz yeniden-sync' modunu desteklemiyor (CT10062'de zaten senkron agac var)." >&2
  exit 1
fi
rm -rf "$WORKSPACE/kernel/SukiSU-Ultra" "$WORKSPACE/kernel/Baseband-guard"

echo "=== [1/21] setup-build-environment: kernel_patches + AnyKernel3 klonla ==="
cd "$WORKSPACE"
KERNEL_PATCHES_COMMIT="$(retry git ls-remote https://github.com/WildKernels/kernel_patches.git refs/heads/main | cut -f1)"
ANYKERNEL3_COMMIT="$(retry git ls-remote https://github.com/WildKernels/AnyKernel3.git refs/heads/gki-2.0 | cut -f1)"
DROIDSPACES_COMMIT="$(retry git ls-remote https://github.com/ravindu644/Droidspaces-OSS.git refs/heads/main | cut -f1)"
echo "KERNEL_PATCHES_COMMIT=$KERNEL_PATCHES_COMMIT ANYKERNEL3_COMMIT=$ANYKERNEL3_COMMIT DROIDSPACES_COMMIT=$DROIDSPACES_COMMIT"

if [ ! -d kernel_patches/.git ] || [ "$(git -C kernel_patches rev-parse HEAD)" != "$KERNEL_PATCHES_COMMIT" ]; then
  rm -rf kernel_patches
  retry git clone https://github.com/WildKernels/kernel_patches.git kernel_patches
  git -C kernel_patches fetch --depth=1 origin "$KERNEL_PATCHES_COMMIT"
  git -C kernel_patches checkout "$KERNEL_PATCHES_COMMIT"
fi
if [ ! -d AnyKernel3/.git ] || [ "$(git -C AnyKernel3 rev-parse HEAD)" != "$ANYKERNEL3_COMMIT" ]; then
  rm -rf AnyKernel3
  retry git clone https://github.com/WildKernels/AnyKernel3.git -b gki-2.0 AnyKernel3
  git -C AnyKernel3 fetch --depth=1 origin "$ANYKERNEL3_COMMIT"
  git -C AnyKernel3 checkout "$ANYKERNEL3_COMMIT"
fi

echo "=== [2/21] download-kernel: repo senkronu (zaten var, deprecated dal duzeltmesiyle dogrulaniyor) ==="
cd "$WORKSPACE/kernel"
FORMATTED_BRANCH="${VERSION}-${OS_PATCH_LEVEL}"
if [ ! -d common/.git ]; then
  echo "HATA: kernel/common repo-sync edilmemis; bu betik CT10062'deki mevcut senkron agaci kullanir." >&2
  exit 1
fi
echo "Kernel kaynagi hazir: $(cd common && git log -1 --format='%h %s')"

echo "=== [3/21] Build zaman damgasi (apply-kernel-branding ile ayni sabit epoch) ==="
FIXED_BUILD_DATE="${OS_PATCH_LEVEL}-05 04:20:00 UTC"
export SOURCE_DATE_EPOCH=$(date -u -d "$FIXED_BUILD_DATE" +%s)
export KBUILD_BUILD_TIMESTAMP=$(date -u -d @${SOURCE_DATE_EPOCH} '+%a %b %d %H:%M:%S UTC %Y')
export GIT_COMMITTER_DATE=$(date -u -d @${SOURCE_DATE_EPOCH} '+%Y-%m-%dT%H:%M:%SZ')
export GIT_AUTHOR_DATE="$GIT_COMMITTER_DATE"
export KBUILD_BUILD_USER="kleaf"
export KBUILD_BUILD_HOST="build-host"

echo "=== [4/21] kernel-fixes: GLIBC>=2.38 Makefile/parse-options fix ==="
cd "$WORKSPACE/kernel/common"
GLIBC_VERSION="$(ldd --version 2>/dev/null | head -n 1 | awk '{print $NF}')"
echo "GLIBC: $GLIBC_VERSION"
if [ "$(printf '%s\n' "2.38" "$GLIBC_VERSION" | sort -V | head -n1)" = "2.38" ]; then
  if grep -q '\$(Q)\$(MAKE) -C \$(SUBCMD_SRC) OUTPUT=\$(abspath \$(dir \$@))/ \$(abspath \$@)' tools/bpf/resolve_btfids/Makefile; then
    sed -i '/\$(Q)\$(MAKE) -C \$(SUBCMD_SRC) OUTPUT=\$(abspath \$(dir \$@))\/ \$(abspath \$@)/s//$(Q)$(MAKE) -C $(SUBCMD_SRC) EXTRA_CFLAGS="$(CFLAGS)" OUTPUT=$(abspath $(dir $@))\/ $(abspath $@)/' tools/bpf/resolve_btfids/Makefile
    echo "Makefile EXTRA_CFLAGS duzeltildi"
  else
    echo "Makefile duzeltmesi gerekmiyor (zaten uygulanmis ya da desen yok)"
  fi
fi
# android15-6.6 bu kernel-fixes'in parse-options.c ve mmap.c sube kosullarina girmiyor (sadece 5.10/5.15 aileleri).

echo "=== [5/21] root-setup: SukiSU-Ultra builtin dali (SHA ile) ==="
cd "$WORKSPACE/kernel"
git clone --no-checkout https://github.com/SukiSU-Ultra/SukiSU-Ultra.git SukiSU-Ultra
git -C SukiSU-Ultra fetch --depth=1 origin "$ROOT_COMMIT"
git -C SukiSU-Ultra checkout --detach "$ROOT_COMMIT"
ACTUAL_ROOT_COMMIT="$(git -C SukiSU-Ultra rev-parse HEAD)"
[ "$ACTUAL_ROOT_COMMIT" = "$ROOT_COMMIT" ] || { echo "Root commit uyusmazligi" >&2; exit 1; }
ln -s ../../SukiSU-Ultra/kernel common/drivers/kernelsu
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' common/drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> common/drivers/Makefile
grep -q 'source "drivers/kernelsu/Kconfig"' common/drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' common/drivers/Kconfig
apply_cfg "CONFIG_KSU=y"
echo "SukiSU-Ultra: $(git -C SukiSU-Ultra describe --tags --always --dirty 2>/dev/null || echo "$ACTUAL_ROOT_COMMIT")"

echo "=== [6/21] susfs-setup + susfs-patches + susfs-config (susfs action) ==="
cd "$WORKSPACE"
SUSFS_BRANCH="gki-${VERSION}"
rm -rf susfs4ksu
retry git clone https://gitlab.com/simonpunk/susfs4ksu.git -b "$SUSFS_BRANCH" susfs4ksu
retry git -C susfs4ksu checkout "$SUSFS_COMMIT"
echo "susfs4ksu: $(git -C susfs4ksu rev-parse HEAD)"
# "Enable SUSFS for KernelSU (tiann)" adimi YALNIZ root_flavor==kernelsu icin
# calisir (susfs/action.yml); bizim flavor sukisu-ultra oldugu icin
# 10_enable_susfs_for_ksu.patch HIC UYGULANMAZ (RED tur-2, madde 1c duzeltmesi).
cd "$WORKSPACE/kernel/common"
cp "$WORKSPACE/susfs4ksu/kernel_patches/fs/"* fs/
cp "$WORKSPACE/susfs4ksu/kernel_patches/include/linux/"* include/linux/
cp "$WORKSPACE/susfs4ksu/kernel_patches/50_add_susfs_in_gki-${VERSION}.patch" ./
apply_cfg "CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
# Android 15 6.6 Fake Patches (susfs-patches/action.yml): SUBLEVEL=66 <= 92 -> base.c
# fake-include uygulanir (50_add_susfs yamasinin fs/proc/base.c hunk'i bu include'u
# bekliyor; onsuz "Hunk FAILED at 101" verir - ilk denemede boyle kirildi). <=30 (task_mmu.c)
# ve <=57 (mm/memory.c) kosullari 66 icin gecersiz, atlanir.
echo "Applying 6.6 SUSFS fixes (fake patch: sublevel $SUBLEVEL <= 92 -> base.c dma-buf.h)"
sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
patch -p1 < "50_add_susfs_in_gki-${VERSION}.patch"
if grep -q 'VMA_PAD_START(' fs/proc/task_mmu.c && ! grep -qE '#include <linux/pgsize_migration(_inline)?\.h>|define VMA_PAD_START' fs/proc/task_mmu.c; then
  sed -i '1a #ifndef VMA_PAD_START\n#define VMA_PAD_START(vma) ((vma)->vm_end)\n#endif' fs/proc/task_mmu.c
fi
# Revert Android 15 6.6 Fake Patches (susfs-revert-patches/action.yml): sublevel<=92 -> base.c
# fake include geri alinir (gercek agac zaten dma-buf.h'i baska yerden saglar).
echo "Reverting 6.6 Fake Patches (sublevel $SUBLEVEL <= 92 -> base.c)"
sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
# "Apply show_pad Fix" yalniz eski (5.10/5.15, os_patch_level!=2024-05) ailelerde calisir, bizde atlanir.

echo "=== [7/21] Fix selinux_hide pointer-bool-conversion (6.6+, tum dallar) ==="
for f in $(find "$WORKSPACE" -name selinux_hide.c 2>/dev/null); do
  if grep -q "extern void security_dump_masked_av_fn" "$f"; then
    sed -i 's/if (security_dump_masked_av_fn)/if (\&security_dump_masked_av_fn)/g' "$f"
    sed -i 's/if (security_dump_masked_av_fn != NULL)/if (\&security_dump_masked_av_fn != NULL)/g' "$f"
    sed -i 's/if (context_struct_compute_av_fn)/if (\&context_struct_compute_av_fn)/g' "$f"
    sed -i 's/if (context_struct_compute_av_fn != NULL)/if (\&context_struct_compute_av_fn != NULL)/g' "$f"
  elif grep -q "if (security_dump_masked_av_fn" "$f"; then
    sed -i 's/if (security_dump_masked_av_fn)/if (security_dump_masked_av_fn != NULL)/g' "$f"
    sed -i 's/if (context_struct_compute_av_fn)/if (context_struct_compute_av_fn != NULL)/g' "$f"
  fi
  if grep -q "^static int security_context_to_sid_with_policy" "$f"; then
    sed -i 's/^static int security_context_to_sid_with_policy/int security_context_to_sid_with_policy/g' "$f"
    sed -i 's/^static int security_sid_to_context_with_policy/int security_sid_to_context_with_policy/g' "$f"
    sed -i 's/^static void security_compute_av_user_with_policy/void security_compute_av_user_with_policy/g' "$f"
  fi
done

echo "=== [8/21] bbg: Baseband Guard ==="
cd "$WORKSPACE/kernel"
if ! grep -q "baseband_guard" common/security/Kconfig 2>/dev/null; then
  retry bash -c "curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 https://raw.githubusercontent.com/vc-teahouse/Baseband-guard/main/setup.sh | bash"
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' common/security/Kconfig
fi
grep -q "baseband_guard" common/security/Kconfig
apply_cfg "CONFIG_BBG=y"

echo "=== [9/21] networking: networking-config + bbrv3 + cifs ==="
cd "$WORKSPACE/kernel/common"
apply_cfg "CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_CUBIC=y
CONFIG_TCP_CONG_BIC=y
CONFIG_TCP_CONG_WESTWOOD=y
CONFIG_TCP_CONG_HTCP=y
CONFIG_DEFAULT_BBR=y
CONFIG_DEFAULT_TCP_CONG=\"bbr\"
CONFIG_NET_SCH_FQ=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_NET_SCH_CAKE=y
CONFIG_NET_ACT_CONNMARK=y
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP6_NF_MATCH_HL=y
CONFIG_WIREGUARD=y"
# bbrv3 (android15-6.6 kolu): kernel_patches/common/bbrv3/...android15-6.6.patch
patch -p1 < "$WORKSPACE/kernel_patches/common/bbrv3/0001-net-tcp-backport-BBRv3-to-android15-6.6.patch"
apply_cfg "CONFIG_TCP_CONG_BBR3=y"
# cifs
apply_cfg "CONFIG_CIFS=y
CONFIG_NETWORK_FILESYSTEMS=y
CONFIG_NETFS_SUPPORT=y
CONFIG_KEYS=y
CONFIG_CIFS_XATTR=y
CONFIG_CIFS_POSIX=y"

echo "=== [10/21] droidspaces: Droidspaces-OSS (SYSVIPC kABI fix) ==="
cd "$WORKSPACE"
rm -rf Droidspaces-OSS
retry git clone --depth=1 https://github.com/ravindu644/Droidspaces-OSS.git
git -C Droidspaces-OSS fetch --depth=1 origin "$DROIDSPACES_COMMIT"
git -C Droidspaces-OSS checkout "$DROIDSPACES_COMMIT"
cd "$WORKSPACE/kernel/common"
cp "$WORKSPACE/Droidspaces-OSS/Documentation/resources/kernel-patches/GKI/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch" ./
patch -p1 < 001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch
apply_cfg "CONFIG_PID_NS=y
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_DEVTMPFS=y
CONFIG_BINFMT_MISC=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_BINFMT_ELF=y
CONFIG_USER_NS=y"

echo "=== [11/21] ntsync: NTSync yamasi + config ==="
cd "$WORKSPACE/kernel/common"
patch -p1 < "$WORKSPACE/kernel_patches/common/ntsync/ntsync_compat_${VERSION}.patch"
patch -p1 < "$WORKSPACE/kernel_patches/common/ntsync/ntsync_base.patch"
apply_cfg "CONFIG_NTSYNC=y"

echo "=== [12/21] ptrace: yalniz kernel<5.16 icin (6.6 >= 5.16, ATLANIYOR) ==="
cd "$WORKSPACE/kernel/common"
if [ "$(printf '%s\n' "$KERNEL_VERSION" "5.16" | sort -V | head -n1)" = "$KERNEL_VERSION" ]; then
  patch -p1 -F 3 < "$WORKSPACE/kernel_patches/gki_ptrace.patch"
else
  echo "Kernel $KERNEL_VERSION >= 5.16, ptrace yamasi atlaniyor (action.yml'nin kendi kosulu)"
fi

echo "=== [13/21] unicode-fix: unicode bypass yamasi (6.1+ varyanti) ==="
cd "$WORKSPACE/kernel/common"
if [ "$(printf '%s\n' "$KERNEL_VERSION" "5.16" | sort -V | head -n1)" = "$KERNEL_VERSION" ]; then
  patch -p1 --forward < "$WORKSPACE/kernel_patches/common/unicode_bypass_fix_6.1-.patch"
else
  patch -p1 --forward < "$WORKSPACE/kernel_patches/common/unicode_bypass_fix_6.1+.patch"
fi

echo "=== [14/21] misc: dosya sistemi/kallsyms configlari ==="
apply_cfg "CONFIG_OVERLAY_FS=y
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y"

echo "=== [15/21] btf (BPF): android15-6.6 icin yalniz config (yama yok, android12-5.10'a ozel) ==="
apply_cfg "CONFIG_DEBUG_INFO_BTF=y
CONFIG_BPF_EVENTS=y
CONFIG_KPROBE_EVENTS=y
CONFIG_UPROBES=y
CONFIG_UPROBE_EVENTS=y
CONFIG_FUSE_FS=y
CONFIG_BPF_SYSCALL=y
CONFIG_FUSE_BPF=y"

echo "=== [16/21] apply-device-patches: BILEREK ATLANDI ==="
# Gercek build.yml'de bu adim (Samsung min_kdp ABI sembolleri + Xiaomi
# device_find_any_child sembolu) android15-6.6 icin kosulsuz calisir, ANCAK
# Orcun'un onayiyla telefona YAZILAN ve dogrulanan imaj (10 Eki 2026, 01:27)
# bu adim UYGULANMADAN derlenmisti (commit 25de0193 "Wild: Clean Dirty Flag"
# bu dosyalari icermiyor). Hedef cihaz (TECNO KM4n) ne Samsung ne Xiaomi
# oldugu icin bu sembol eklemeleri zaten islevsiz (yalniz o OEM'lerin ABI
# izin listesine sembol ekler); atlamak calisan/dogrulanmis imaji etkilemez.
# Orcun'un kesin talimati (10 Eki 2026 01:27 kart notu): "imaj teslimi
# degismesin" - bu yuzden betik, FLASH EDILEN imaji BIREBIR yeniden
# uretecek sekilde bu adimi devre disi birakiyor. Gelecekte Samsung/Xiaomi
# cihazlar hedeflenirse bu blok actions dosyasindan (apply-device-patches)
# geri eklenebilir.

echo "=== [17/21] nomount: NoMount VFS kancalari (pinli SHA) ==="
cd "$WORKSPACE/kernel"
KERNEL_DIR="$WORKSPACE/kernel/common"
setup_script="$WORKSPACE/nomount-setup-${NOMOUNT_COMMIT}.sh"
curl --fail --location --silent --show-error --retry 5 --retry-delay 5 --retry-all-errors \
  "https://raw.githubusercontent.com/maxsteeel/nomount/${NOMOUNT_COMMIT}/kernel/setup.sh" --output "$setup_script"
chmod 0755 "$setup_script"
if [ ! -d "$KERNEL_DIR/NoMount" ]; then
  git clone --no-checkout https://github.com/maxsteeel/nomount.git "$KERNEL_DIR/NoMount"
fi
git -C "$KERNEL_DIR/NoMount" fetch --depth=1 origin "$NOMOUNT_COMMIT"
git -C "$KERNEL_DIR/NoMount" checkout --detach --quiet "$NOMOUNT_COMMIT"
(cd "$KERNEL_DIR" && "$setup_script" "$NOMOUNT_COMMIT")
rm -f "$setup_script"
[ -L "$KERNEL_DIR/fs/nomount" ] || { echo "NoMount entegrasyonu basarisiz: fs/nomount symlink yok" >&2; exit 1; }
apply_cfg "CONFIG_NOMOUNT=y"

echo "=== [18/21] apply-kernel-branding: surum dizgesi (brand=$BRAND_NAME, keep_kmi=$KEEP_KMI) ==="
cd "$WORKSPACE/kernel/common"
KERNEL_STRING="${KERNEL_VERSION}.${SUBLEVEL}-${ANDROID_VERSION}"
sed -i '$d' scripts/setlocalversion && echo "echo \"${KERNEL_STRING}-${BRAND_NAME}\"" >> scripts/setlocalversion
chmod +x scripts/setlocalversion
tail -n 1 scripts/setlocalversion

echo "=== [19/21] remove-protected-exports + clean-kernel-flags (Wild: Clean Dirty Flag) ==="
cd "$WORKSPACE/kernel"
rm -rf common/android/abi_gki_protected_exports_*
if grep -q '"protected_exports_list"[[:space:]]*:[[:space:]]*"android/abi_gki_protected_exports_aarch64"' common/BUILD.bazel; then
  perl -pi -e 's/^\s*"protected_exports_list"\s*:\s*"android\/abi_gki_protected_exports_aarch64",\s*$//;' common/BUILD.bazel
fi
if grep -q 'protected_modules = ' common/modules.bzl; then
  # Gercek remove-protected-exports/action.yml'nin '^protected_modules = ' (girintisiz)
  # deseni, mevcut modules.bzl'deki girintili (4 bosluk, fonksiyon govdesi icinde)
  # satirla hic eslesmiyor - action bu dosyada sessizce no-op kaliyor. Teslim edilip
  # onaylanmis onceki agacta (25de0193) deger yine de [] idi;ayni sonucu saglamak
  # icin deseni girinti farkini da kapsayacak sekilde genislettim (BB-G-1328 T2 duzeltmesi).
  sed -i 's/^\([[:space:]]*\)protected_modules = \[.*\]/\1protected_modules = []/' common/modules.bzl
fi
if grep -q 'protected_module_names_list' common/BUILD.bazel; then
  perl -pi -e 's/^\s*protected_module_names_list\s*=\s*":[A-Za-z0-9_]*_protected_module_names",\s*$//;' common/BUILD.bazel
fi
sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" build/kernel/kleaf/impl/stamp.bzl
sed -i 's/-dirty//' common/scripts/setlocalversion
cd "$WORKSPACE/kernel/common"
git add -A
git commit -m "Wild: Clean Dirty Flag" --quiet
echo "Clean Dirty Flag commit: $(git log -1 --format='%h %s')"

echo "=== [20/21] Enable SukiSU KPM (BB) + build-kernel: bazel derlemesi ==="
cd "$WORKSPACE/kernel"
apply_cfg "CONFIG_KPM=y"
sed -i 's/check_defconfig//' ./common/build.config.gki
sed -i '/name = "kernel_aarch64",/a\    check_defconfig = "disabled",' common/BUILD.bazel
echo "Bazel komutu: nice -n 19 ionice -c3 ./tools/bazel build --config=fast --jobs=32 --disk_cache=$WORKSPACE/.bazel-cache //common:kernel_aarch64/Image"
nice -n 19 ionice -c3 ./tools/bazel build \
  --config=fast \
  --jobs=32 \
  --disk_cache="$WORKSPACE/.bazel-cache" \
  //common:kernel_aarch64/Image 2>&1 | tee "$WORKSPACE/build.log"
test -f bazel-bin/common/kernel_aarch64/Image

echo "=== [21/21] KPM gercek etkinlestirme (SukiSU_KernelPatch_patch) + AnyKernel3 paketleme ==="
cp bazel-bin/common/kernel_aarch64/Image "$WORKSPACE/AnyKernel3/Image.bazel-raw"
RAW_SHA="$(sha256sum "$WORKSPACE/AnyKernel3/Image.bazel-raw" | awk '{print $1}')"
echo "Ham (KPM-siz) Image sha256: $RAW_SHA"

mkdir -p "$WORKSPACE/kpm-patch/work"
cp bazel-bin/common/kernel_aarch64/Image "$WORKSPACE/kpm-patch/work/Image"
cd "$WORKSPACE/kpm-patch/work"
cp "$WORKSPACE/kpm-patch/patch_linux-0.13.0" ./patch_linux
chmod +x ./patch_linux
PATCH_LINUX_SHA="$(sha256sum ./patch_linux | awk '{print $1}')"
echo "patch_linux sha256: $PATCH_LINUX_SHA (beklenen: ea4884140c0ee8835bc79b67e4c9b46094c6640d6407f0aab34d2df4e28e0450 - R1'de GitHub asset digest ile dogrulandi)"
[ "$PATCH_LINUX_SHA" = "ea4884140c0ee8835bc79b67e4c9b46094c6640d6407f0aab34d2df4e28e0450" ] || { echo "HATA: patch_linux sha uyusmuyor!" >&2; exit 1; }
./patch_linux
test -f oImage
mv oImage Image
KPM_SHA="$(sha256sum Image | awk '{print $1}')"
echo "KPM yamali Image sha256: $KPM_SHA"
[ "$KPM_SHA" != "$RAW_SHA" ] || { echo "HATA: KPM yamasi sha'yi degistirmedi!" >&2; exit 1; }
"$WORKSPACE/kpm-patch/kptools-linux" -l -i Image

cp Image "$WORKSPACE/AnyKernel3/Image"
cd "$WORKSPACE/AnyKernel3"
ZIP_NAME="KM4n-${KERNEL_VERSION}.${SUBLEVEL}-${ANDROID_VERSION}-${OS_PATCH_LEVEL}-SukiSU-Ultra-SUSFS-KPM-${BRAND_NAME}.zip"
rm -f "$ZIP_NAME"
zip -r9 "$ZIP_NAME" . -x ".git/*" ".github/*" "*.zip" "Image.bazel-raw" > /dev/null
echo "ZIP: $ZIP_NAME -> $(sha256sum "$ZIP_NAME")"
echo "strings/susfs-sukisu-kpm kontrolu:"
strings Image | grep -iE "susfs|sukisu|kpm" | sort -u | head -10
echo "Surum dizgesi:"
strings Image | grep -E "^${KERNEL_VERSION}\.${SUBLEVEL}-${ANDROID_VERSION}-${BRAND_NAME}|Linux version ${KERNEL_VERSION}" | head -3

echo "=== TAMAMLANDI ==="
echo "Son 30 satir icin: tail -30 $WORKSPACE/build.log"
