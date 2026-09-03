#!/bin/sh

# Validate ECM/NSS acceleration after a wired lan2 client has generated traffic.
# This script observes the router only; it does not generate traffic itself.

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

field_value() {
	printf '%s\n' "$1" | awk -v key="$2" '{
		for (i = 1; i <= NF; i++) {
			split($i, pair, "=")
			if (pair[1] == key) {
				print pair[2]
				exit
			}
		}
	}'
}

nonnegative() {
	case "$1" in
		''|*[!0-9-]*) return 1 ;;
		-*) return 1 ;;
		*) return 0 ;;
	esac
}

counter_value() {
	value=$(sed -n '1p' "$1" 2>/dev/null || true)
	if nonnegative "$value"; then
		printf '%s\n' "$value"
	else
		printf '0\n'
	fi
}

latest_trace() {
	pattern="$1"
	dmesg | grep -F "$pattern" | tail -n 1 || true
}

check_dsa_interface() {
	dev="$1"
	trace=$(latest_trace "ECM-DSA: dev=$dev ")
	if [ -z "$trace" ]; then
		error "missing ECM-DSA trace for $dev"
		return 1
	fi

	dsa_user=$(field_value "$trace" dsa_user)
	conduit=$(field_value "$trace" conduit)
	conduit_ifnum=$(field_value "$trace" conduit_ifnum)
	final_ifnum=$(field_value "$trace" final_ifnum)

	info "ecm-dsa dev=$dev dsa_user=${dsa_user:-unknown} conduit=${conduit:-unknown} conduit_ifnum=${conduit_ifnum:-unknown} final_ifnum=${final_ifnum:-unknown}"
	debug "ecm-dsa-trace=$trace"

	[ "$dsa_user" = 1 ] || {
		error "$dev is not reported as a DSA user netdev"
		return 1
	}
	[ "$conduit" = eth0 ] || {
		error "$dev conduit is not eth0"
		return 1
	}
	nonnegative "$conduit_ifnum" || {
		error "$dev conduit_ifnum is unresolved"
		return 1
	}
	nonnegative "$final_ifnum" || {
		error "$dev final_ifnum is unresolved"
		return 1
	}
}

check_rule_interfaces() {
	line=$(dmesg | grep 'ECM-NSS: rule-interface-check proto=4' | tail -n 1 || true)
	if [ -z "$line" ]; then
		error 'missing IPv4 ECM rule-interface-check trace'
		return 1
	fi

	from_ifnum=$(field_value "$line" from_ifnum)
	to_ifnum=$(field_value "$line" to_ifnum)
	info "ecm-rule-interface from_ifnum=${from_ifnum:-unknown} to_ifnum=${to_ifnum:-unknown}"
	debug "ecm-rule-trace=$line"

	nonnegative "$from_ifnum" || {
		error 'IPv4 ECM from_ifnum is unresolved'
		return 1
	}
	nonnegative "$to_ifnum" || {
		error 'IPv4 ECM to_ifnum is unresolved'
		return 1
	}
}

check_carrier() {
	dev="$1"
	carrier_file="/sys/class/net/$dev/carrier"
	if [ ! -r "$carrier_file" ]; then
		warn "$dev carrier state is unavailable"
		return 0
	fi

	carrier=$(sed -n '1p' "$carrier_file" 2>/dev/null || true)
	info "carrier dev=$dev value=${carrier:-unknown}"
	[ "$carrier" = 1 ] || warn "$dev has no active carrier; connect the wired test client before validation"
}

if [ "$(id -u 2>/dev/null)" != 0 ]; then
	error 'run as root on the MX2000 router'
	exit 1
fi

board=$(board_name 2>/dev/null || true)
[ "$board" = linksys,mx2000 ] || {
	error "expected linksys,mx2000, got ${board:-unknown}"
	exit 1
}

[ -d /sys/kernel/debug/ecm ] || {
	error 'ECM debugfs is unavailable; start qca-nss-ecm first'
	exit 1
}
[ -d /sys/module/qca_nss_drv ] || {
	error 'qca_nss_drv is not loaded'
	exit 1
}

for dev in lan2 wan; do
	[ -d "/sys/class/net/$dev" ] || {
		error "missing DSA user netdev $dev"
		exit 1
	}
	check_carrier "$dev"
done

if check_dsa_interface lan2; then
	lan_result=0
else
	lan_result=1
fi
if check_dsa_interface wan; then
	wan_result=0
else
	wan_result=1
fi
if check_rule_interfaces; then
	rule_result=0
else
	rule_result=1
fi

ipv4_accelerated=$(find /sys/kernel/debug/ecm/ecm_nss_ipv4 -type f -name accelerated_count -print -quit 2>/dev/null || true)
ipv4_tcp_accelerated=$(find /sys/kernel/debug/ecm/ecm_nss_ipv4 -type f -name tcp_accelerated_count -print -quit 2>/dev/null || true)
if [ -z "$ipv4_accelerated" ]; then
	error 'IPv4 ECM accelerated_count is unavailable'
	ipv4_result=1
else
	ipv4_count=$(counter_value "$ipv4_accelerated")
	ipv4_tcp_count=0
	[ -z "$ipv4_tcp_accelerated" ] || ipv4_tcp_count=$(counter_value "$ipv4_tcp_accelerated")
	info "ecm-ipv4 accelerated_count=$ipv4_count tcp_accelerated_count=$ipv4_tcp_count"
	if [ "$ipv4_count" -gt 0 ] || [ "$ipv4_tcp_count" -gt 0 ]; then
		ipv4_result=0
	else
		error 'no IPv4 ECM acceleration observed; run a sustained LAN-to-WAN flow from wired lan2'
		ipv4_result=1
	fi
fi

if [ "$lan_result" -eq 0 ] && [ "$wan_result" -eq 0 ] && [ "$rule_result" -eq 0 ] && [ "$ipv4_result" -eq 0 ]; then
	info 'wired MX2000 ECM acceleration validation passed'
	exit 0
fi

error 'wired MX2000 ECM acceleration validation failed'
exit 1
