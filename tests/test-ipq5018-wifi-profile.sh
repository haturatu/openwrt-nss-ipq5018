#!/bin/sh
set -eu

helper=${1:-nss-setup/enable-ipq5018-wifi-nss.sh}
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

fail() {
	printf 'ERROR %s\n' "$*" >&2
	exit 1
}

run_profile_test() {
	profile="$1"
	config="$test_dir/config-$profile"
	dts="$test_dir/dts-$profile"
	pbuf="$test_dir/pbuf-$profile"

	cp nss-setup/config-ipq5018.seed "$config"
	cp target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-mx2000.dts "$dts"
	cp package/kernel/mac80211/files/pbuf.uci "$pbuf"

	"$helper" --mem-profile "$profile" --pbuf-file "$pbuf" "$config" "$dts" >/dev/null

	grep -Eq "^CONFIG_ATH11K_MEM_PROFILE_${profile}M=y$" "$config" || \
		fail "missing ath11k ${profile}M profile"
	if [ "$profile" = 256 ]; then
		grep -Fqx '# CONFIG_ATH11K_MEM_PROFILE_512M is not set' "$config" || \
			fail '512M profile was not disabled for 256M test'
	else
		grep -Fqx '# CONFIG_ATH11K_MEM_PROFILE_256M is not set' "$config" || \
			fail '256M profile was not disabled for 512M test'
	fi
	grep -Eq "^[[:space:]]*option[[:space:]]+memory_profile[[:space:]]+'${profile}mb'[[:space:]]*$" "$pbuf" || \
		fail "pbuf profile does not match ${profile}M"
	grep -Fqx '#include "ipq5018-nss-qcn6122.dtsi"' "$dts" || \
		fail 'QCN6122 NSS overlay was not enabled'
	[ "$(grep -Fc '#include "ipq5018-nss-qcn6122.dtsi"' "$dts")" -eq 1 ] || \
		fail 'QCN6122 NSS overlay was duplicated'
}

run_profile_test 256
run_profile_test 512

config="$test_dir/config-invalid"
dts="$test_dir/dts-invalid"
pbuf="$test_dir/pbuf-invalid"
cp nss-setup/config-ipq5018.seed "$config"
cp target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-mx2000.dts "$dts"
cp package/kernel/mac80211/files/pbuf.uci "$pbuf"
if "$helper" --mem-profile 1024 --pbuf-file "$pbuf" "$config" "$dts" >/dev/null 2>&1; then
	fail 'unsupported memory profile was accepted'
fi

printf 'INFO IPQ5018 Wi-Fi NSS profile checks passed\n'
