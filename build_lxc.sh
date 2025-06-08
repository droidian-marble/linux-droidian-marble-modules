#!/usr/bin/bash

yellow='\033[0;33m'
white='\033[0m'
red='\033[0;31m'
gre='\e[0;32m'

cd ${0%/*}

DEFCONFIG=marble_defconfig
IMAGE=./out/arch/arm64/boot/Image
OUTPUT_DIR=/outmelt
GKI_BUILD_TOOLS=/android-kernel/build

KMI_STRICT_MODE=true
USE_SLIM_LLVM=true

mkdir -p $OUTPUT_DIR
mkdir -p ${OUTPUT_DIR}/vendor_dlkm_modules

########## Parsing parameters ##########

use_defconfig=$DEFCONFIG
make_target=

########## Preparation Phase ##########

export KBUILD_BUILD_HOST="halhadus"
export KBUILD_BUILD_USER="halhadus"

CLANG_PATH=/usr/lib/llvm-android-12.0-r416183b/bin

export PATH=${CLANG_PATH}:${PATH}

export LOCALVERSION=-v3.8.1

make_flags="ARCH=arm64 LLVM=1 LLVM_IAS=1 O=out"
make_kcflags="-D__ANDROID_COMMON_KERNEL__ -O3"
make_kbuild_ldflags=
make_flags+=" CCACHE="

########## Make it ##########

make $make_flags KCFLAGS="$make_kcflags" KBUILD_LDFLAGS="$make_kbuild_ldflags" mrproper
make $make_flags KCFLAGS="$make_kcflags" KBUILD_LDFLAGS="$make_kbuild_ldflags" "$use_defconfig"

if [ "$(./scripts/config --file ./out/.config -s CFI_FORCE_SKIP_CHECK)" == "y" ]; then
	echo -e "${yellow}Warning: CFI checks is disabled! $white"
fi

$USE_SLIM_LLVM && ./scripts/config --file ./out/.config -d LLVM_POLLY

if ${KMI_STRICT_MODE}; then

	_gen_symbol_files_list() {
		(
			ROOT_DIR=.
			KERNEL_DIR=.
			source ./build.config.gki.aarch64 2>/dev/null
			echo $KMI_SYMBOL_LIST $ADDITIONAL_KMI_SYMBOL_LISTS
		)
	}

	TMP_ABI_SYMBOLLIST=/tmp/abi_symbollist
	TMP_ABI_SYMBOLLIST_RAW=/tmp/abi_symbollist.raw
	rm -f "$TMP_ABI_SYMBOLLIST"
	rm -f "$TMP_ABI_SYMBOLLIST_RAW"

	${GKI_BUILD_TOOLS}/copy_symbols.sh "$TMP_ABI_SYMBOLLIST" . $(_gen_symbol_files_list)
	cat "$TMP_ABI_SYMBOLLIST" | ${GKI_BUILD_TOOLS}/abi/flatten_symbol_list > "$TMP_ABI_SYMBOLLIST_RAW"

	./scripts/config --file ./out/.config \
	    -d UNUSED_SYMBOLS -e TRIM_UNUSED_KSYMS  \
	    --set-str UNUSED_KSYMS_WHITELIST "$TMP_ABI_SYMBOLLIST_RAW" \
	    -e UNUSED_KSYMS_WHITELIST_ONLY
fi

t_start=$(date +"%s")

make $make_flags KCFLAGS="$make_kcflags" KBUILD_LDFLAGS="$make_kbuild_ldflags" -j$(nproc --all) $make_target

if [ $? != 0 ]; then
	echo -e "$red << Failed to compile, fix the errors first >>$white"
	exit 1
fi

########## Processing products ##########

vendor_dlkm_need_modules='
drivers/staging/qcacld-3.0/qca6490.ko
drivers/net/wireless/cnss2/cnss2.ko
drivers/platform/msm/ipa_fmwk/ipa_fmwk.ko
drivers/platform/msm/mhi_dev/mhi_dev_drv.ko
drivers/usb/gadget/function/usb_f_gsi.ko
drivers/staging/binder_prio/binder_prio.ko
drivers/block/zram/zram.ko
mm/zsmalloc.ko
net/wireless/cfg80211.ko
net/mac80211/mac80211.ko
techpack/dataipa/drivers/platform/msm/gsi/gsim.ko
techpack/dataipa/drivers/platform/msm/ipa/ipa_clients/rndisipam.ko
techpack/dataipa/drivers/platform/msm/ipa/ipa_clients/ipa_clientsm.ko
techpack/dataipa/drivers/platform/msm/ipa/ipam.ko
techpack/dataipa/drivers/platform/msm/ipa/ipanetm.ko
techpack/datarmnet/core/rmnet_core.ko
techpack/datarmnet/core/rmnet_ctl.ko
techpack/datarmnet-ext/aps/rmnet_aps.ko
techpack/datarmnet-ext/offload/rmnet_offload.ko
techpack/datarmnet-ext/perf/rmnet_perf.ko
techpack/datarmnet-ext/perf_tether/rmnet_perf_tether.ko
techpack/datarmnet-ext/sch/rmnet_sch.ko
techpack/datarmnet-ext/shs/rmnet_shs.ko
techpack/datarmnet-ext/wlan/rmnet_wlan.ko
drivers/power/supply/qti_battery_charger_main.ko
'

rm ${OUTPUT_DIR}/*.ko 2>/dev/null
rm ${OUTPUT_DIR}/vendor_dlkm_modules/*.ko 2>/dev/null

for module in $vendor_dlkm_need_modules; do
	[ -f ./out/$module ] || {
		echo -e "${yellow}! ${module} not found! ${white}"
		continue
	}
	module_file_name=$(basename $module)
	case $module_file_name in
		"qca6490.ko")                  module_file_name="qca_cld3_qca6490.ko";;
		# "qti_battery_charger_main.ko") module_file_name="qti_battery_charger.ko";;
	esac
	echo "- Striping $module_file_name ..."
	llvm-strip -S ./out/$module -o ${OUTPUT_DIR}/vendor_dlkm_modules/${module_file_name}
done

t_end=$(date +"%s")
t_diff=$(($t_end - $t_start))

echo -e "$gre << Build completed in $(($t_diff / 60)) minutes and $(($t_diff % 60)) seconds >> \n $white"
