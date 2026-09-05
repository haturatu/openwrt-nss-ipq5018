#!/bin/sh
set -eu

mem_profile=512
config_file=.config
dts_file=target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-mx2000.dts
pbuf_file=package/kernel/mac80211/files/pbuf.uci

error() {
	printf 'ERROR %s\n' "$*" >&2
}

info() {
	printf 'INFO %s\n' "$*"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--mem-profile=*)
		mem_profile=${1#*=}
		;;
	--mem-profile)
		[ "$#" -ge 2 ] || {
			error '--mem-profile requires 256 or 512'
			exit 2
		}
		mem_profile=$2
		shift
		;;
	--pbuf-file=*)
		pbuf_file=${1#*=}
		;;
	--pbuf-file)
		[ "$#" -ge 2 ] || {
			error '--pbuf-file requires a path'
			exit 2
		}
		pbuf_file=$2
		shift
		;;
	-*)
		error "unknown option: $1"
		exit 2
		;;
	*)
		if [ "$config_file" = .config ]; then
			config_file=$1
		elif [ "$dts_file" = target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-mx2000.dts ]; then
			dts_file=$1
		elif [ "$pbuf_file" = package/kernel/mac80211/files/pbuf.uci ]; then
			pbuf_file=$1
		else
			error "unexpected positional argument: $1"
			exit 2
		fi
		;;
	esac
	shift
done

case "$mem_profile" in
256|512)
		;;
*)
		error "unsupported memory profile: $mem_profile (use 256 or 512)"
		exit 2
		;;
esac

[ -f "$config_file" ] || {
	error "config file not found: $config_file"
	exit 1
}

[ -f "$dts_file" ] || {
	error "MX2000 DTS not found: $dts_file"
	exit 1
}

[ -f "$pbuf_file" ] || {
	error "pbuf config not found: $pbuf_file"
	exit 1
}

grep -Fq 'compatible = "linksys,mx2000"' "$dts_file" || {
	error "DTS is not the Linksys MX2000 profile: $dts_file"
	exit 1
}

set_config() {
	local name="$1" value="$2"

	sed -i \
		-e "/^${name}=.*$/d" \
		-e "/^# ${name} is not set$/d" \
		"$config_file"
	printf '%s=%s\n' "$name" "$value" >> "$config_file"
}

unset_config() {
	local name="$1"

	sed -i \
		-e "/^${name}=.*$/d" \
		-e "/^# ${name} is not set$/d" \
		"$config_file"
	printf '# %s is not set\n' "$name" >> "$config_file"
}

unset_config CONFIG_NSS_DRV_MANUAL_BRINGUP
set_config CONFIG_ATH11K_NSS_SUPPORT y
set_config CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE y
set_config CONFIG_NSS_DRV_WIFI_EXT_VDEV_ENABLE y
set_config CONFIG_PACKAGE_MAC80211_NSS_SUPPORT y
set_config "CONFIG_ATH11K_MEM_PROFILE_${mem_profile}M" y
unset_config CONFIG_ATH11K_MEM_PROFILE_1G
if [ "$mem_profile" = 512 ]; then
	unset_config CONFIG_ATH11K_MEM_PROFILE_256M
else
	unset_config CONFIG_ATH11K_MEM_PROFILE_512M
fi
unset_config CONFIG_ATH11K_NSS_MESH_SUPPORT
unset_config CONFIG_PACKAGE_MAC80211_NSS_REDIRECT

sed -i -E \
	"s/^([[:space:]]*option[[:space:]]+memory_profile[[:space:]]+).*/\\1'${mem_profile}mb'/" \
	"$pbuf_file"

grep -Eq "^[[:space:]]*option[[:space:]]+memory_profile[[:space:]]+'${mem_profile}mb'[[:space:]]*$" "$pbuf_file" || {
	error "unable to set pbuf memory profile: $mem_profile"
	exit 1
}

if ! grep -Fqx '#include "ipq5018-nss-qcn6122.dtsi"' "$dts_file"; then
	sed -i '/^#include "ipq5018-nss.dtsi"$/a #include "ipq5018-nss-qcn6122.dtsi"' "$dts_file"
fi

info 'enabled experimental ath11k NSS support'
info 'ath11k parameters will load as nss_offload=1 frame_mode=2'
info "ath11k memory profile=${mem_profile}M; pbuf memory_profile=${mem_profile}mb"
info 'QCN6122 NSS radio-priority overlay enabled after ipq5018-nss.dtsi'
info 'ECM remains disabled by the base seed'
