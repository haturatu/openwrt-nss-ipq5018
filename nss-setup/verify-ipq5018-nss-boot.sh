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

	# The experimental overlay selects firmware memory mode 2 on both
	# radios (internal 2.4 GHz + QCN6122 5 GHz). One line is not enough:
	# both radios must report mode 2, otherwise only half of the
	# experiment is active.
	fw_mode2_count=$(dmesg 2>/dev/null | grep -Ec 'FW memory mode: 2' || true)
	if [ "$fw_mode2_count" -ge 2 ]; then
		info "ath11k firmware memory mode 2 reported by ${fw_mode2_count} radios"
	else
		error "only ${fw_mode2_count} radio(s) report FW memory mode 2; expected 2 (both radios)"
	fi

	# The QCN6122 hybrid BAR must be remapped to a non-zero address with
	# a non-zero size. A zero address makes the NSS datapath use a bare
	# offset into the wrong fabric window; a zero size breaks the remap.
	if dmesg 2>/dev/null | grep -Eq 'hybrid bus BAR 0x0*[1-9a-f][0-9a-f]* size 0x0*[1-9a-f]'; then
		info 'QCN6122 hybrid bus BAR remapped (non-zero address and size)'
	elif dmesg 2>/dev/null | grep -Eq 'hybrid bus BAR 0x'; then
		error 'QCN6122 hybrid bus BAR address or size is zero; BAR/window fix is missing or ineffective'
	else
		error 'missing boot log: QCN6122 hybrid bus BAR remap'
	fi

	# Datapath success must be proven on the QCN6122 5 GHz radio itself:
	# an internal-radio-only offload must NOT pass. Read the wifili
	# debugfs counters directly (nss_stats hides zero counters via the
	# non_zero_stats filter) and require both reo_reaped and rx_deliverd
	# to be non-zero inside the QCN6122 SoC section.
	wifili_stats_file=/sys/kernel/debug/qca-nss-drv/stats/wifili
	if [ -r "$wifili_stats_file" ]; then
		qcn_stats=$(awk '/QCN6122/ { in_qcn = 1; next }
			in_qcn && /<</ && !/PDEV/ { exit }
			in_qcn { print }' "$wifili_stats_file")
		qcn_reo=$(printf '%s\n' "$qcn_stats" | awk '$1 ~ /^wifili\[[0-9]+\]_reo_reaped$/ { s += $3 } END { print s + 0 }')
		qcn_rxd=$(printf '%s\n' "$qcn_stats" | awk '$1 ~ /^wifili\[[0-9]+\]_rx_deliverd$/ { s += $3 } END { print s + 0 }')
		if [ "$qcn_reo" -gt 0 ] && [ "$qcn_rxd" -gt 0 ]; then
			info "QCN6122 NSS datapath alive (reo_reaped=${qcn_reo} rx_deliverd=${qcn_rxd})"
		else
			# Idle counters are only meaningful with associated
			# 5 GHz clients, so count stations on the QCN6122
			# phy (identified via its device-tree compatible,
			# not by hardcoded addresses or phy numbers).
			qcn_sta=0
			for phy in /sys/class/ieee80211/phy*; do
				[ -d "$phy" ] || continue
				tr '\0' ' ' < "$phy/device/of_node/compatible" 2>/dev/null | grep -Fq 'qcom,qcn6122-wifi' || continue
				phy_idx=${phy##*phy}
				for netdev in /sys/class/net/*; do
					[ -f "$netdev/phy80211/index" ] || continue
					if [ "$(cat "$netdev/phy80211/index" 2>/dev/null)" = "$phy_idx" ]; then
						nsta=$(iw dev "${netdev##*/}" station dump 2>/dev/null | grep -Ec '^Station ' || true)
						qcn_sta=$((qcn_sta + nsta))
					fi
				done
			done
			if [ "$qcn_sta" -gt 0 ]; then
				error "QCN6122 has ${qcn_sta} associated station(s) but NSS datapath is idle (reo_reaped=${qcn_reo} rx_deliverd=${qcn_rxd})"
			else
				warn 'QCN6122 NSS datapath idle and no 5 GHz stations; associate a client, generate traffic, then re-run with --wifi'
			fi
		fi
	else
		warn 'wifili NSS stats not readable; verify QCN6122 reo_reaped/rx_deliverd manually after client traffic'
	fi
fi

if [ "$errors" -ne 0 ]; then
	printf 'ERROR IPQ5018 NSS boot validation failed (%s checks)\n' "$errors" >&2
	exit 1
fi

info 'IPQ5018 NSS boot validation passed'
