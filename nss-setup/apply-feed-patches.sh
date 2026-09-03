#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
feed_dir="$repo_root/feeds/nss_packages"
patch_dir="$repo_root/nss-setup/patches/nss_packages"

info() {
	printf 'INFO %s\n' "$*"
}

error() {
	printf 'ERROR %s\n' "$*" >&2
}

patch_is_applied() {
	case "${1##*/}" in
		0001-ipq5018-nss-driver-manual-bringup.patch)
			grep -Fq 'NSS_DRV_MANUAL_BRINGUP' "$feed_dir/qca-nss-drv/Config.in" &&
			grep -Fq 'manual_bringup' "$feed_dir/qca-nss-drv/files/qca-nss-drv.init"
			;;
		0002-ipq5018-ecm-safe-sysctls.patch)
			grep -Fq 'write_value_if_available' "$feed_dir/qca-nss-ecm/files/qca-nss-ecm.init" &&
			grep -Fq "option enable '0'" "$feed_dir/qca-nss-ecm/files/qca-nss-ecm.uci"
			;;
		0003-ipq5018-ecm-require-nss-driver.patch)
			grep -Fq 'NSS driver is not loaded; refusing to start ECM' "$feed_dir/qca-nss-ecm/files/qca-nss-ecm.init"
			;;
		0004-ipq5018-ecm-dsa-conduit-interface-resolution.patch)
			grep -Fq 'dsa_port_to_conduit' "$feed_dir/qca-nss-ecm/patches/0026-ipq5018-ecm-dsa-conduit-interface-resolution.patch"
			;;
		0005-ipq5018-ecm-debugfs-write-readback.patch)
			grep -Fq 'ECM node readback mismatch' "$feed_dir/qca-nss-ecm/files/qca-nss-ecm.init"
			;;
		0006-ipq5018-ecm-dsa-resolution-trace.patch)
			grep -Fq 'ECM-DSA: dev=' "$feed_dir/qca-nss-ecm/patches/0027-ipq5018-ecm-dsa-resolution-trace.patch"
			;;
		0007-ipq5018-ecm-rule-resolution-trace.patch)
			grep -Fq 'ECM-NSS: rule-submit' "$feed_dir/qca-nss-ecm/patches/0028-ipq5018-ecm-rule-resolution-trace.patch"
			;;
		*)
			return 1
			;;
	esac
}

[ -d "$feed_dir/.git" ] || {
	error "NSS feed is not a git checkout: $feed_dir"
	exit 1
}

for patch in "$patch_dir"/*.patch; do
	[ -f "$patch" ] || continue

	if git -C "$feed_dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
		info "already applied $(basename "$patch")"
	elif git -C "$feed_dir" apply --check "$patch" >/dev/null 2>&1; then
		git -C "$feed_dir" apply --whitespace=nowarn "$patch"
		info "applied $(basename "$patch")"
	elif patch_is_applied "$patch"; then
		info "already applied $(basename "$patch") (stacked patch detected)"
	else
		error "cannot apply $(basename "$patch")"
		exit 1
	fi
done
