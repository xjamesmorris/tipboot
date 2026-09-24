#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup()
{
	rm -rf -- "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/bin" "$tmp/patches" "$tmp/output" "$tmp/cache"
mkdir -p "$tmp/work"
touch "$tmp/patches/0001-test.patch" "$tmp/series.mbox"
cat > "$tmp/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == info ]]; then
	printf 'true\n'
	exit 0
fi
if [[ ${1:-} == image && ${2:-} == inspect ]]; then
	case "$*" in
	*'{{.Id}}'*) printf 'sha256:test-image-id\n' ;;
	*'{{.Digest}}'*) printf 'sha256:test-image-digest\n' ;;
	*) exit 1 ;;
	esac
	exit 0
fi
if [[ " $* " == *" /usr/local/libexec/tipboot/build-kernel "* ]]; then
	for argument in "$@"; do
		case "$argument" in
		--volume=*:\/resolve:Z)
			resolve_dir=${argument#--volume=}
			resolve_dir=${resolve_dir%:/resolve:Z}
			mkdir -p "$resolve_dir/output"
			printf '0123456789abcdef0123456789abcdef01234567\n' \
				> "$resolve_dir/output/resolved-commit"
			exit 0
			;;
		esac
	done
	exit 1
fi
printf '%s\n' "$@" > "$TIPBOOT_TEST_ARGS"
EOF
chmod +x "$tmp/bin/podman"

PATH="$tmp/bin:$PATH" TIPBOOT_TEST_ARGS="$tmp/args" \
	"$repo_root/scripts/tipboot" \
	--commit deadbeef \
	--patch-dir "$tmp/patches" \
	--mbox "$tmp/series.mbox" \
	--output "$tmp/output" \
	--cache "$tmp/cache" \
	--work "$tmp/work" \
	--jobs 2 \
	--timeout 90 \
	--image localhost/tipboot:test \
	--pull never

grep -Fxq -- '--read-only' "$tmp/args"
grep -Fxq -- "--user=$(id -u):$(id -g)" "$tmp/args"
grep -Fxq -- '--cap-drop=all' "$tmp/args"
grep -Fxq -- '--security-opt=no-new-privileges' "$tmp/args"
grep -Fxq -- '--commit' "$tmp/args"
grep -Fxq -- '0123456789abcdef0123456789abcdef01234567' "$tmp/args"
grep -Fxq -- '--network=none' "$tmp/args"
grep -Fq -- "$tmp/cache:/cache:ro,Z" "$tmp/args"
grep -Fxq -- '--env=TIPBOOT_IMAGE_ID=sha256:test-image-id' "$tmp/args"
grep -Fxq -- '--env=TIPBOOT_IMAGE_DIGEST=sha256:test-image-digest' "$tmp/args"
grep -Fxq -- '--patch-dir' "$tmp/args"
grep -Fxq -- '/input/patches' "$tmp/args"
grep -Fxq -- '--mbox' "$tmp/args"
grep -Fxq -- '/input/series.mbox' "$tmp/args"
grep -Fq -- "$tmp/work:/work:Z" "$tmp/args"
if grep -Fxq -- '--privileged' "$tmp/args"; then
	echo "unexpected privileged container" >&2
	exit 1
fi

if PATH="$tmp/bin:$PATH" "$repo_root/scripts/tipboot" \
	--jobs 0 --output "$tmp/output" --cache "$tmp/cache" 2>/dev/null; then
	echo "accepted invalid --jobs value" >&2
	exit 1
fi

"$repo_root/scripts/tipboot" --help | grep -Fq 'QEMU TCG'

printf 'prior evidence\n' > "$tmp/output/prior.txt"
PATH="$tmp/bin:$PATH" TIPBOOT_TEST_ARGS="$tmp/args-rerun" \
	"$repo_root/scripts/tipboot" \
	--output "$tmp/output" \
	--cache "$tmp/cache" \
	--work "$tmp/work" \
	--image localhost/tipboot:test \
	--pull never
grep -Eq -- "$tmp/output/[0-9]{8}-[0-9]{6}-[0-9]+:/output:Z" \
	"$tmp/args-rerun"
