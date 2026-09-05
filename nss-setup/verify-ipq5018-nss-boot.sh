#!/bin/sh
set -u

wifi_nss=0
if [ "${1:-}" = "--wifi" ]; then
	wifi_nss=1
elif [ "${1:-}" != "" ]; then
	printf 'ERROR usage: %s [--wifi]\n' "$0" >&2
	exit 2
fi

errors=0

info() {
	printf 'INFO %s\n' "$*"
}

warn() {
	printf 'WARN %s\n' "$*" >&2
}

error() {
	printf 'ERROR %s\n' "$*" >&2
	errors=$((errors + 1))
}

check_dir() {
	local path="$1"

	[ -d "$path" ] || error "missing kernel module: ${path##*/}"
}

check_dmesg() {
	local pattern="$1" label="$2"

	if dmesg 2>/dev/null | grep -Eiq "$pattern"; then
		info "$label"
	else
		error "missing boot log: $label"
	fi
}

board=$(board_name 2>/dev/null || true)
case "$board" in
	linksys,mx2000)
		info "board=$board"
		;;
	*)
		warn "unexpected board=${board:-unknown}; continuing diagnostics"
		;;
esac

check_dir /sys/module/qca_nss_dp
check_dir /sys/module/qca_nss_drv

manual_bringup=$(uci -q get nss.general.manual_bringup 2>/dev/null || true)
[ "$manual_bringup" = 0 ] || error "NSS manual_bringup is '${manual_bringup:-unset}', expected 0"

check_dmesg 'NSS FW Version:|NSS core 0 booted successfully' 'NSS firmware/core booted'
check_dmesg 'nss-dp .*eth0: PHY Link up' 'NSS-DP eth0 link-up observed'

redirect=/proc/sys/dev/nss/general/redirect
if [ -r "$redirect" ]; then
	info "NSS redirect=$(cat "$redirect" 2>/dev/null)"
else
	error "missing NSS sysctl: dev.nss.general.redirect"
fi

if grep -Eiq 'nss[_-](queue|empty)|nss-dp' /proc/interrupts 2>/dev/null; then
	info 'NSS interrupt lines are registered'
else
	error 'NSS interrupt lines are missing'
fi

if [ -r /sys/class/net/eth0/carrier ]; then
	case "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" in
		1) info 'eth0 carrier is up' ;;
		*) warn 'eth0 carrier is down; connect the QCA8337 uplink before testing WAN' ;;
	esac
else
	error 'missing eth0 carrier state'
fi

if ubus call network.interface.wan status 2>/dev/null | grep -Fq '"up": true'; then
	info 'WAN interface is up'
else
	warn 'WAN interface is not up; DHCP/IPv6 validation is inconclusive'
fi

if [ "$wifi_nss" -eq 1 ]; then
	for parameter in nss_offload frame_mode; do
		parameter_file="/sys/module/ath11k/parameters/$parameter"
		[ -r "$parameter_file" ] || {
			error "missing ath11k parameter: $parameter"
			continue
		}
		value=$(cat "$parameter_file" 2>/dev/null)
		case "$parameter:$value" in
			nss_offload:1|frame_mode:2) info "ath11k $parameter=$value" ;;
			*) error "ath11k $parameter=$value; expected $([ "$parameter" = nss_offload ] && printf 1 || printf 2)" ;;
		esac
	done

	if [ -r /etc/config/pbuf ] && grep -Eq "option memory_profile[[:space:]]+'(auto|256|256mb|512|512mb|1gb)'" /etc/config/pbuf; then
		info "ath11k NSS pbuf profile=$(uci -q get pbuf.opt.memory_profile 2>/dev/null || printf unknown)"
	else
		warn 'pbuf memory_profile is not explicitly auto/512/1gb; inspect /etc/config/pbuf'
	fi

	check_dmesg 'ath11k .*NSS|WIFILI|nss_offload' 'ath11k NSS activity observed'
	check_dmesg 'FW memory mode:' 'ath11k firmware memory mode reported'
	check_dmesg 'hybrid bus BAR 0x[1-9a-f]|hybrid bus BAR 0x0*[1-9a-f]' \
		'QCN6122 hybrid bus BAR remapped to a non-zero address'
	if dmesg 2>/dev/null | grep -Eq 'hybrid bus BAR 0x0+ size'; then
		error 'QCN6122 hybrid bus BAR is zero; BAR/window fix is missing or ineffective'
	fi

	# Datapath success needs traffic: nss_offload=1 alone is not proof.
	# After associating a client, reo_reaped and rx_deliverd must grow.
	if command -v nss_stats >/dev/null 2>&1; then
		if nss_stats 2>/dev/null | grep -Ei 'reo_reaped|rx_deliverd' | grep -Eqv '[[:space:]]0([[:space:]]|$)'; then
			info 'NSS wifili datapath counters are incrementing (reo_reaped/rx_deliverd)'
		else
			warn 'no non-zero reo_reaped/rx_deliverd counters; associate a client and generate traffic, then re-run with --wifi'
		fi
	else
		warn 'nss_stats not found; verify reo_reaped/rx_deliverd manually after client traffic'
	fi
fi

if [ "$errors" -ne 0 ]; then
	printf 'ERROR IPQ5018 NSS boot validation failed (%s checks)\n' "$errors" >&2
	exit 1
fi

info 'IPQ5018 NSS boot validation passed'
