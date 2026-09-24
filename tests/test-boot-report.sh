#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/scripts/lib/boot-report.py
tmp=$(mktemp -d)
cleanup()
{
	rm -rf -- "$tmp"
}
trap cleanup EXIT

common=(
	--kernel-image Image
	--initramfs initramfs.cpio.gz
	--kernel-release 6.12.0-test
	--host-arch x86_64
	--acceleration tcg
	--cpu max
	--acceleration-reason test
	--qemu qemu-system-aarch64
	--qemu-version 'QEMU test'
	--timeout-seconds 60
	--marker 'TIPBOOT_OK kernel_release=6.12.0-test'
	--qemu-exit-code 0
)

run_finalize()
{
	local name=$1
	local expected_status=$2
	local expected_stage=$3
	local log=$tmp/$name.log
	local result=$tmp/$name.json
	local summary=$tmp/$name.txt
	shift 3
	printf '%s\n' "$@" > "$log"

	set +e
	python3 "$helper" finalize \
		--result "$result" \
		--summary "$summary" \
		--boot-log "$log" \
		"${common[@]}"
	status=$?
	set -e

	if [[ $expected_status == passed ]]; then
		[[ $status -eq 0 ]]
	else
		[[ $status -eq 1 ]]
	fi
	jq -e \
		--arg status "$expected_status" \
		--arg stage "$expected_stage" \
		'.status == $status and .stage == $stage' \
		"$result" >/dev/null
}

run_finalize pass passed boot \
	'booting' \
	'TIPBOOT_OK kernel_release=6.12.0-test' \
	'[    0.8] reboot: Power down'

run_finalize panic-before failed guest_panic_before_marker \
	'Kernel panic - not syncing: before marker' \
	'TIPBOOT_OK kernel_release=6.12.0-test' \
	'[    0.8] reboot: Power down'

run_finalize panic-after failed guest_panic_after_marker \
	'TIPBOOT_OK kernel_release=6.12.0-test' \
	'Kernel panic - not syncing: after marker' \
	'[    0.8] reboot: Power down'

run_finalize no-shutdown failed shutdown_missing \
	'TIPBOOT_OK kernel_release=6.12.0-test'
