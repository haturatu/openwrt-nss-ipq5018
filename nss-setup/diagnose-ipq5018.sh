#!/bin/sh

# Collect non-secret IPQ5018 NSS diagnostics.
# INFO/DEBUG go to stdout; WARN/ERROR go to stderr.

info() {
	printf 'INFO %s\n' "$*"
}

debug() {
	printf 'DEBUG %s\n' "$*"
}

warn() {
	printf 'WARN %s\n' "$*" >&2
}

error() {
	printf 'ERROR %s\n' "$*" >&2
}

read_text() {
	if [ -r "$1" ]; then
		tr '\000' ' ' < "$1"
	else
		printf '%s' '-'
	fi
}

read_cells() {
	if [ -r "$1" ]; then
		od -An -tx4 "$1" 2>/dev/null | tr '\n' ' '
	else
		printf '%s' '-'
	fi
}

if [ "$(id -u 2>/dev/null)" != 0 ]; then
	error 'run as root'
	exit 1
fi

dt=/sys/firmware/devicetree/base

info "model=$(read_text "$dt/model")"
info "compatible=$(read_text "$dt/compatible")"
info "kernel=$(uname -a)"
if [ -r /etc/openwrt_release ]; then
	# shellcheck disable=SC1091
	. /etc/openwrt_release
	info "release=${DISTRIB_RELEASE:-unknown} revision=${DISTRIB_REVISION:-unknown} target=${DISTRIB_TARGET:-unknown}"
fi

for node in soc@0/nss-common soc@0/nss@40000000 soc@0/dp1 soc@0/dp2; do
	if [ -d "$dt/$node" ]; then
		info "dt-node=$node present"
		for prop in compatible status qcom,id reg interrupts memory-region clocks clock-names qcom,load-addr; do
			if [ -r "$dt/$node/$prop" ]; then
				debug "dt=$node property=$prop value=$(read_cells "$dt/$node/$prop")"
			fi
		done
	else
		warn "dt-node=$node absent"
	fi
done

if [ -d "$dt/reserved-memory" ]; then
	for node in "$dt"/reserved-memory/*; do
		[ -d "$node" ] || continue
		name=${node##*/}
		info "reserved-memory=$name reg=$(read_cells "$node/reg")"
	done
else
	warn 'reserved-memory node absent'
fi

info 'loaded NSS/QCA modules:'
if [ -r /proc/modules ]; then
	grep -Ei '(^|,)(qca_nss|qca-nss|qca_ssdk|qca-ssdk|ecm)' /proc/modules || warn 'NSS core/ECM modules are not loaded'
else
	warn '/proc/modules unavailable'
fi

info 'NSS firmware files:'
firmware_found=0
for file in /lib/firmware/qca-nss*.bin; do
	[ -f "$file" ] || continue
	firmware_found=1
	ls -l "$file"
done
[ "$firmware_found" -eq 1 ] || warn 'qca-nss firmware is not installed'

info 'relevant kernel log:'
if command -v dmesg >/dev/null 2>&1; then
	dmesg | grep -Ei 'nss|ecm|ssdk|gmac|qca8k|firmware' || warn 'no relevant NSS log lines'
else
	warn 'dmesg unavailable'
fi

info 'relevant memory map:'
if [ -r /proc/iomem ]; then
	grep -Ei 'nss|eth|reserved|system ram' /proc/iomem || warn 'no relevant memory map lines'
else
	warn '/proc/iomem unavailable'
fi

info 'relevant interrupts:'
if [ -r /proc/interrupts ]; then
	grep -Ei 'nss|gmac|dp|edma' /proc/interrupts || warn 'no relevant interrupt lines'
else
	warn '/proc/interrupts unavailable'
fi

info 'network links:'
if command -v ip >/dev/null 2>&1; then
	ip -br link
else
	warn 'ip command unavailable'
fi

if [ -d /sys/kernel/debug/ecm ]; then
	info 'ecm-debugfs=present'
else
	warn 'ecm-debugfs=absent'
fi

info 'diagnostic collection complete'
