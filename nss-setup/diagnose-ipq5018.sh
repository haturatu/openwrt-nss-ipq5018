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

read_first_line() {
	if [ -r "$1" ]; then
		head -n 1 "$1" 2>/dev/null || printf '%s' '-'
	else
		printf '%s' '-'
	fi
}

dump_module_parameters() {
	module_dir="$1"
	[ -d "$module_dir/parameters" ] || return 0

	for parameter in "$module_dir"/parameters/*; do
		[ -f "$parameter" ] || continue
		info "module-parameter=${parameter##*/} value=$(read_first_line "$parameter")"
	done
}

dump_ecm_counters() {
	ecm_dir=/sys/kernel/debug/ecm
	[ -d "$ecm_dir" ] || return 0

	find "$ecm_dir" -type f -print 2>/dev/null | sort | while IFS= read -r file; do
		name=${file##*/}
		case "$name" in
			*accelerated_count|*tcp_accelerated_count|*udp_accelerated_count|\
			*connection_count|*pending_count|*fail*|*nack*|*exception*|*backend*)
				relative=${file#"$ecm_dir"/}
				info "ecm-counter=$relative value=$(read_first_line "$file")"
				;;
		esac
	done
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

info 'NSS core state:'
if [ -d /sys/module/qca_nss_drv ]; then
	info 'module=qca_nss_drv state=loaded'
	dump_module_parameters /sys/module/qca_nss_drv
else
	warn 'module=qca_nss_drv state=not-loaded'
fi
for sysctl in /proc/sys/dev/nss/general/redirect; do
	[ -e "$sysctl" ] || continue
	info "sysctl=${sysctl#/proc/sys/} value=$(read_first_line "$sysctl")"
done

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
	ip link
	info 'network addresses:'
	ip addr show
else
	warn 'ip command unavailable'
fi

if [ -d /sys/kernel/debug/ecm ]; then
	info 'ecm-debugfs=present'
	info 'ECM debugfs files:'
	find /sys/kernel/debug/ecm -type f -print 2>/dev/null | sort
	info 'ECM counters:'
	dump_ecm_counters
else
	warn 'ecm-debugfs=absent'
fi

info 'relevant NSS clocks:'
if [ -r /sys/kernel/debug/clk/clk_summary ]; then
	grep -Ei 'ubi|nss|utcm|gmac' /sys/kernel/debug/clk/clk_summary || warn 'no relevant NSS clock lines'
else
	warn '/sys/kernel/debug/clk/clk_summary unavailable'
fi

info 'diagnostic collection complete'
