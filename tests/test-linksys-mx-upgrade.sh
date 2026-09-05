#!/bin/sh
set -eu

platform_sh=${1:-target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/platform.sh}
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

fail() {
	printf 'ERROR %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	[ "$1" = "$2" ] || fail "expected '$1', got '$2'"
}

grep -Fq "linksys_mx_pre_upgrade \"\$1\" || {" "$platform_sh" || \
	fail 'platform_do_upgrade does not stop when partition selection fails'

function_body=$(awk '
	/^linksys_mx_pre_upgrade\(\) \{/ { found=1 }
	/^platform_check_image\(\) \{/ { exit }
	found { print }
' "$platform_sh")
[ -n "$function_body" ] || fail 'unable to extract linksys_mx_pre_upgrade'
eval "$function_body"

fw_printenv() {
	[ "${1:-}" = '-n' ] || return 1
	case "${2:-}" in
	boot_part) printf '%s\n' "$TEST_BOOT_PART" ;;
	boot_part_ready) printf '%s\n' "$TEST_BOOT_PART_READY" ;;
	auto_recovery) printf '%s\n' "$TEST_AUTO_RECOVERY" ;;
	*) return 1 ;;
	esac
}

fw_setenv() {
	[ "${1:-}" = '-s' ] || return 1
	[ "${TEST_FW_SETENV_FAIL:-0}" = 0 ] || return 1

	if [ "${TEST_FW_SETENV_NO_BOOT_UPDATE:-0}" = 0 ]; then
		new_boot_part=$(sed -n 's/^boot_part //p' "$2")
		[ -z "$new_boot_part" ] || TEST_BOOT_PART=$new_boot_part
	fi
}

export LINKSYS_MX_SETENV_SCRIPT="$test_dir/fw_env_upgrade"
TEST_BOOT_PART=1
TEST_BOOT_PART_READY=3
TEST_AUTO_RECOVERY=yes
unset TEST_FW_SETENV_FAIL TEST_FW_SETENV_NO_BOOT_UPDATE

linksys_mx_pre_upgrade image.bin || fail 'valid partition switch was rejected'
assert_eq "$CI_KERNPART" alt_kernel
assert_eq "$CI_UBIPART" alt_rootfs
assert_eq "$TEST_BOOT_PART" 2

TEST_BOOT_PART=1
TEST_FW_SETENV_FAIL=1
if linksys_mx_pre_upgrade image.bin; then
	fail 'fw_setenv failure was not propagated'
fi
assert_eq "$TEST_BOOT_PART" 1

TEST_FW_SETENV_FAIL=0
TEST_FW_SETENV_NO_BOOT_UPDATE=1
if linksys_mx_pre_upgrade image.bin; then
	fail 'boot_part read-back mismatch was not rejected'
fi

TEST_FW_SETENV_NO_BOOT_UPDATE=0
TEST_BOOT_PART=7
if linksys_mx_pre_upgrade image.bin; then
	fail 'invalid boot_part was not rejected'
fi

printf 'INFO Linksys MX dual-partition upgrade checks passed\n'
