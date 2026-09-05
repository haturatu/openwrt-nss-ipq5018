#!/bin/sh
set -eu

helper=${1:-nss-setup/enable-ipq5018-wifi-nss.sh}
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

fail() {
	printf 'ERROR %s\n' "$*" >&2
	exit 1
}

# Map the requested --mem-profile argument to the expected kernel config
# symbol and pbuf profile name. 1024 is the experimental 1G profile for
# the 512MB MX2000 and maps to CONFIG_ATH11K_MEM_PROFILE_1G / '1gb'.
expected_for() {
	case "$1" in
	256) printf 'CONFIG_ATH11K_MEM_PROFILE_256M 256mb' ;;
	512) printf 'CONFIG_ATH11K_MEM_PROFILE_512M 512mb' ;;
	1024|1g|1G) printf 'CONFIG_ATH11K_MEM_PROFILE_1G 1gb' ;;
	*) return 1 ;;
	esac
}

run_profile_test() {
	profile="$1"
	config="$test_dir/config-$profile"
	dts="$test_dir/dts-$profile"
	pbuf="$test_dir/pbuf-$profile"

	# shellcheck disable=SC2046: intentional word splitting of "CONFIG PBUF" pair
	set -- $(expected_for "$profile")
	want_config=$1
	want_pbuf=$2

	cp nss-setup/config-ipq5018.seed "$config"
	cp target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-mx2000.dts "$dts"
	cp package/kernel/mac80211/files/pbuf.uci "$pbuf"

	"$helper" --mem-profile "$profile" --pbuf-file "$pbuf" "$config" "$dts" >/dev/null

	grep -Eq "^${want_config}=y$" "$config" || \
		fail "missing ath11k profile ${want_config} for --mem-profile $profile"
	for other in CONFIG_ATH11K_MEM_PROFILE_256M \
		CONFIG_ATH11K_MEM_PROFILE_512M \
		CONFIG_ATH11K_MEM_PROFILE_1G; do
		if [ "$other" != "$want_config" ]; then
			grep -Fqx "# $other is not set" "$config" || \
				fail "$other was not disabled for --mem-profile $profile"
		fi
	done
	grep -Eq "^[[:space:]]*option[[:space:]]+memory_profile[[:space:]]+'${want_pbuf}'[[:space:]]*$" "$pbuf" || \
		fail "pbuf profile does not match ${want_pbuf} for --mem-profile $profile"
	grep -Fqx '#include "ipq5018-nss-qcn6122.dtsi"' "$dts" || \
		fail 'QCN6122 NSS overlay was not enabled'
	[ "$(grep -Fc '#include "ipq5018-nss-qcn6122.dtsi"' "$dts")" -eq 1 ] || \
		fail 'QCN6122 NSS overlay was duplicated'
	grep -Fqx '#include "ipq5018-mx2000-nss-wifi.dtsi"' "$dts" || \
		fail 'MX2000 Wi-Fi NSS overlay (fw-memory-mode=2) was not enabled'
	[ "$(grep -Fc '#include "ipq5018-mx2000-nss-wifi.dtsi"' "$dts")" -eq 1 ] || \
		fail 'MX2000 Wi-Fi NSS overlay was duplicated'
	# DTS uses last-wins for duplicate properties and the base MX2000
	# body sets fw-memory-mode = <1> after the header includes, so the
	# overlay include must come after the base body or mode 2 silently
	# loses (the built DTB would still report mode 1).
	last_mode_line=$(grep -n 'qcom,ath11k-fw-memory-mode' "$dts" | tail -n 1 | cut -d: -f1)
	overlay_line=$(grep -nF '#include "ipq5018-mx2000-nss-wifi.dtsi"' "$dts" | cut -d: -f1)
	[ "$overlay_line" -gt "$last_mode_line" ] || \
		fail 'MX2000 Wi-Fi NSS overlay must be included after the base DTS body (last-wins)'
}

run_profile_test 256
run_profile_test 512
run_profile_test 1024

# The MX2000-specific overlay must select firmware memory mode 2 on both
# radios (not just one). This is a WLAN firmware layout selector,
# independent from the host-side ATH11K_MEM_PROFILE_* choice.
[ "$(grep -Fc 'qcom,ath11k-fw-memory-mode = <2>;' \
	target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-mx2000-nss-wifi.dtsi)" -eq 2 ] || \
	fail 'MX2000 Wi-Fi NSS overlay must set fw-memory-mode 2 on both radios'

config="$test_dir/config-invalid"
dts="$test_dir/dts-invalid"
pbuf="$test_dir/pbuf-invalid"
cp nss-setup/config-ipq5018.seed "$config"
cp target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-mx2000.dts "$dts"
cp package/kernel/mac80211/files/pbuf.uci "$pbuf"
if "$helper" --mem-profile 999 --pbuf-file "$pbuf" "$config" "$dts" >/dev/null 2>&1; then
	fail 'unsupported memory profile was accepted'
fi

printf 'INFO IPQ5018 Wi-Fi NSS profile checks passed\n'
