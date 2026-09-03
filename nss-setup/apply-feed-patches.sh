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

[ -d "$feed_dir/.git" ] || {
	error "NSS feed is not a git checkout: $feed_dir"
	exit 1
}

for patch in "$patch_dir"/*.patch; do
	[ -f "$patch" ] || continue

	if git -C "$feed_dir" apply --check "$patch" >/dev/null 2>&1; then
		git -C "$feed_dir" apply "$patch"
		info "applied $(basename "$patch")"
	elif git -C "$feed_dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
		info "already applied $(basename "$patch")"
	else
		error "cannot apply $(basename "$patch")"
		exit 1
	fi
done
