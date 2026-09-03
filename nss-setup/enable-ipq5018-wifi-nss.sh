#!/bin/sh
set -eu

config_file=${1:-.config}
dts_file=${2:-target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-mx2000.dts}

error() {
	printf 'ERROR %s\n' "$*" >&2
}

info() {
	printf 'INFO %s\n' "$*"
}

[ -f "$config_file" ] || {
	error "config file not found: $config_file"
	exit 1
}

[ -f "$dts_file" ] || {
	error "MX2000 DTS not found: $dts_file"
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
set_config CONFIG_ATH11K_MEM_PROFILE_512M y
unset_config CONFIG_ATH11K_MEM_PROFILE_1G
unset_config CONFIG_ATH11K_MEM_PROFILE_256M
unset_config CONFIG_ATH11K_NSS_MESH_SUPPORT
unset_config CONFIG_PACKAGE_MAC80211_NSS_REDIRECT

if ! grep -Fqx '#include "ipq5018-nss-qcn6122.dtsi"' "$dts_file"; then
	sed -i '/^#include "ipq5018-nss.dtsi"$/a #include "ipq5018-nss-qcn6122.dtsi"' "$dts_file"
fi

info 'enabled experimental ath11k NSS support'
info 'ath11k parameters will load as nss_offload=1 frame_mode=2'
info 'QCN6122 NSS radio-priority overlay enabled after ipq5018-nss.dtsi'
info 'ECM remains disabled by the base seed'
