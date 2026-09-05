#!/bin/sh
set -eu

# Experimental Wi-Fi NSS opt-in for IPQ5018 (Linksys MX2000).
#
# The MX2000 has 512 MB of physical RAM, so the safe host-side default is
# the 512M ath11k profile with pbuf '512mb'. The 1024 (1G) profile exists
# only as an experimental comparison option: it must be requested
# explicitly via --mem-profile 1024 and is never enabled by default.
#
# qcom,ath11k-fw-memory-mode is a WLAN firmware memory layout selector and
# is independent from the ATH11K_MEM_PROFILE_* host-side profile. The
# experimental image overrides it to <2> via the MX2000-specific overlay
# ipq5018-mx2000-nss-wifi.dtsi (the base DTS keeps mode 1).

mem_profile=512
config_file=.config
dts_file=target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-mx2000.dts
pbuf_file=package/kernel/mac80211/files/pbuf.uci
positional_args=0

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
			error '--mem-profile requires 256, 512 or 1024'
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
		case "$positional_args" in
		0)
			config_file=$1
			;;
		1)
			dts_file=$1
			;;
		2)
			pbuf_file=$1
			;;
		*)
			error "unexpected positional argument: $1"
			exit 2
			;;
		esac
		positional_args=$((positional_args + 1))
		;;
	esac
	shift
done

case "$mem_profile" in
256)
	config_profile=CONFIG_ATH11K_MEM_PROFILE_256M
	pbuf_profile=256mb
	;;
512)
	config_profile=CONFIG_ATH11K_MEM_PROFILE_512M
	pbuf_profile=512mb
	;;
1024|1g|1G)
	mem_profile=1024
	config_profile=CONFIG_ATH11K_MEM_PROFILE_1G
	pbuf_profile=1gb
	;;
*)
	error "unsupported memory profile: $mem_profile (use 256, 512 or 1024)"
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
unset_config CONFIG_ATH11K_MEM_PROFILE_256M
unset_config CONFIG_ATH11K_MEM_PROFILE_512M
unset_config CONFIG_ATH11K_MEM_PROFILE_1G
set_config "$config_profile" y
unset_config CONFIG_ATH11K_NSS_MESH_SUPPORT
unset_config CONFIG_PACKAGE_MAC80211_NSS_REDIRECT

sed -i -E \
	"s/^([[:space:]]*option[[:space:]]+memory_profile[[:space:]]+).*/\\1'${pbuf_profile}'/" \
	"$pbuf_file"

grep -Eq "^[[:space:]]*option[[:space:]]+memory_profile[[:space:]]+'${pbuf_profile}'[[:space:]]*$" "$pbuf_file" || {
	error "unable to set pbuf memory profile: $pbuf_profile"
	exit 1
}

if ! grep -Fqx '#include "ipq5018-nss-qcn6122.dtsi"' "$dts_file"; then
	sed -i '/^#include "ipq5018-nss.dtsi"$/a #include "ipq5018-nss-qcn6122.dtsi"' "$dts_file"
fi

if ! grep -Fqx '#include "ipq5018-mx2000-nss-wifi.dtsi"' "$dts_file"; then
	sed -i '/^#include "ipq5018-nss-qcn6122.dtsi"$/a #include "ipq5018-mx2000-nss-wifi.dtsi"' "$dts_file"
fi

info 'enabled experimental ath11k NSS support'
info 'ath11k parameters will load as nss_offload=1 frame_mode=2'
info "ath11k memory profile=${config_profile}; pbuf memory_profile=${pbuf_profile}"
if [ "$mem_profile" = 1024 ]; then
	info 'WARNING: 1G profile is experimental on the 512MB MX2000; prefer 512M'
fi
info 'QCN6122 NSS radio-priority overlay enabled after ipq5018-nss.dtsi'
info 'MX2000 Wi-Fi NSS overlay (fw-memory-mode=2) enabled'
info 'ECM remains disabled by the base seed'
