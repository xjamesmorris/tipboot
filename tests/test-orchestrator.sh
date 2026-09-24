#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup()
{
	rm -rf -- "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/libexec" "$tmp/output" "$tmp/cache"

cat > "$tmp/libexec/build-kernel" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
while (($#)); do
	case "$1" in
	--output) output=$2; shift 2 ;;
	*) shift ;;
	esac
done
printf 'test-release\n' > "$output/kernelrelease"
printf '{"commit":"deadbeef","tree":"feedface"}\n' > "$output/source.json"
: > "$output/Image"
EOF

cat > "$tmp/libexec/build-initramfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
while (($#)); do
	case "$1" in
	--output) output=$2; shift 2 ;;
	*) shift ;;
	esac
done
: > "$output"
EOF

cat > "$tmp/libexec/boot-smoke" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
while (($#)); do
	case "$1" in
	--output) output=$2; shift 2 ;;
	*) shift ;;
	esac
done
printf '{"status":"passed","stage":"boot"}\n' > "$output/result.json"
printf 'PASS\n' > "$output/summary.txt"
EOF
chmod +x "$tmp/libexec/"*

TIPBOOT_LIBEXEC="$tmp/libexec" TIPBOOT_IMAGE_REF=localhost/tipboot:test \
	"$repo_root/scripts/run-tipboot" \
	--output "$tmp/output" \
	--cache "$tmp/cache" \
	--commit deadbeef

jq -e '.status == "passed"' "$tmp/output/result.json" >/dev/null
jq -e '.image_ref == "localhost/tipboot:test"' \
	"$tmp/output/provenance.json" >/dev/null

cat > "$tmp/libexec/build-kernel" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
chmod +x "$tmp/libexec/build-kernel"
rm -f "$tmp/output/result.json" "$tmp/output/summary.txt"

if TIPBOOT_LIBEXEC="$tmp/libexec" \
	"$repo_root/scripts/run-tipboot" \
	--output "$tmp/output" \
	--cache "$tmp/cache"; then
	echo "orchestrator accepted a failed build" >&2
	exit 1
else
	status=$?
	[[ $status -eq 23 ]]
fi
jq -e '.status == "failed" and .stage == "build" and .exit_code == 23' \
	"$tmp/output/result.json" >/dev/null
jq -e '.image_ref == "unknown"' "$tmp/output/provenance.json" >/dev/null
