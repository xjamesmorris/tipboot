#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup()
{
	rm -rf -- "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/bin" "$tmp/patches" "$tmp/cache" "$tmp/work" "$tmp/output"

cat > "$tmp/bin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --version ]]; then
	printf 'GNU Make fixture\n'
	exit 0
fi

output=
target=
for argument in "$@"; do
	case "$argument" in
	O=*) output=${argument#O=} ;;
	defconfig|Image|kernelrelease) target=$argument ;;
	esac
done

case "$target" in
defconfig)
	mkdir -p "$output"
	printf 'CONFIG_ARM64=y\n' > "$output/.config"
	;;
Image)
	mkdir -p "$output/arch/arm64/boot"
	printf 'fixture image\n' > "$output/arch/arm64/boot/Image"
	;;
kernelrelease)
	printf '6.12.0-tipboot-fixture\n'
	;;
*)
	printf 'unexpected make invocation: %s\n' "$*" >&2
	exit 1
	;;
esac
EOF
chmod +x "$tmp/bin/make"

git init -q -b master "$tmp/linux"
git -C "$tmp/linux" config user.name 'Tipboot Test'
git -C "$tmp/linux" config user.email tipboot-test@localhost
printf 'base\n' > "$tmp/linux/fixture.txt"
git -C "$tmp/linux" add fixture.txt
git -C "$tmp/linux" commit -q -m base
base_commit=$(git -C "$tmp/linux" rev-parse HEAD)

git -C "$tmp/linux" switch -q -c patch-series
printf 'patch-one\n' >> "$tmp/linux/fixture.txt"
git -C "$tmp/linux" commit -q -am 'fixture: patch one'
first_patch_commit=$(git -C "$tmp/linux" rev-parse HEAD)
git -C "$tmp/linux" format-patch -q -1 --stdout "$first_patch_commit" \
	> "$tmp/patches/0001-patch-one.patch"

printf 'patch-two\n' >> "$tmp/linux/fixture.txt"
git -C "$tmp/linux" commit -q -am 'fixture: patch two'
expected_tree=$(git -C "$tmp/linux" rev-parse 'HEAD^{tree}')
git -C "$tmp/linux" format-patch -q -1 --stdout HEAD \
	> "$tmp/series.mbox"
git -C "$tmp/linux" switch -q master

PATH="$tmp/bin:$PATH" "$repo_root/scripts/build-kernel" \
	--source-url "$tmp/linux" \
	--commit "$base_commit" \
	--patch-dir "$tmp/patches" \
	--mbox "$tmp/series.mbox" \
	--work "$tmp/work" \
	--output "$tmp/output" \
	--cache "$tmp/cache" \
	--jobs 2

jq -e --arg commit "$base_commit" --arg tree "$expected_tree" '
	.state == "complete"
	and .commit == $commit
	and .tree == $tree
	and (.patches | length) == 2
	and .build.kernelrelease == "6.12.0-tipboot-fixture"
' "$tmp/output/source.json" >/dev/null
[[ $(wc -l < "$tmp/output/patches.sha256") -eq 2 ]]
grep -Fxq 'CONFIG_ARM64=y' "$tmp/output/config"
grep -Fxq '6.12.0-tipboot-fixture' "$tmp/output/kernelrelease"
grep -Fxq 'fixture image' "$tmp/output/Image"

mkdir "$tmp/resolve-work" "$tmp/resolve-output" \
	"$tmp/offline-work" "$tmp/offline-output"
PATH="$tmp/bin:$PATH" "$repo_root/scripts/build-kernel" \
	--source-url "$tmp/linux" \
	--commit "$base_commit" \
	--work "$tmp/resolve-work" \
	--output "$tmp/resolve-output" \
	--cache "$tmp/cache" \
	--resolve-only
resolved_commit=$(<"$tmp/resolve-output/resolved-commit")
[[ $resolved_commit == "$base_commit" ]]

PATH="$tmp/bin:$PATH" "$repo_root/scripts/build-kernel" \
	--source-url "$tmp/linux" \
	--commit "$resolved_commit" \
	--patch-dir "$tmp/patches" \
	--mbox "$tmp/series.mbox" \
	--work "$tmp/offline-work" \
	--output "$tmp/offline-output" \
	--cache "$tmp/cache" \
	--offline \
	--jobs 2
jq -e --arg tree "$expected_tree" \
	'.state == "complete" and .tree == $tree' \
	"$tmp/offline-output/source.json" >/dev/null

mkdir "$tmp/work-fail" "$tmp/output-fail" "$tmp/bad-patches"
cat > "$tmp/bad-patches/0001-conflict.patch" <<'EOF'
From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
From: Tipboot Test <tipboot-test@localhost>
Date: Thu, 1 Jan 1970 00:00:00 +0000
Subject: [PATCH] fixture: conflict

---
 fixture.txt | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)

diff --git a/fixture.txt b/fixture.txt
index df967b9..1111111 100644
--- a/fixture.txt
+++ b/fixture.txt
@@ -1 +1 @@
-not-the-base
+conflict
--
2.55.0
EOF

if PATH="$tmp/bin:$PATH" "$repo_root/scripts/build-kernel" \
	--source-url "$tmp/linux" \
	--commit "$base_commit" \
	--patch-dir "$tmp/bad-patches" \
	--work "$tmp/work-fail" \
	--output "$tmp/output-fail" \
	--cache "$tmp/cache" \
	--jobs 1; then
	echo "conflicting patch unexpectedly succeeded" >&2
	exit 1
else
	status=$?
	[[ $status -eq 5 ]]
fi
test -s "$tmp/output-fail/FAILED"
test -s "$tmp/output-fail/build.log"
test -s "$tmp/output-fail/source-diagnostics.txt"

git init -q -b master "$tmp/attacker"
git -C "$tmp/attacker" config user.name 'Tipboot Attacker'
git -C "$tmp/attacker" config user.email attacker@localhost
printf 'attacker\n' > "$tmp/attacker/payload"
git -C "$tmp/attacker" add payload
git -C "$tmp/attacker" commit -q -m attacker
attacker_commit=$(git -C "$tmp/attacker" rev-parse HEAD)
source_hash=$(printf '%s' "$tmp/linux" | sha256sum | awk '{print $1}')
mirror=$tmp/cache/kernel-git/$source_hash.git
git --git-dir="$mirror" fetch -q "$tmp/attacker" "$attacker_commit"

mkdir "$tmp/work-poison" "$tmp/output-poison"
if PATH="$tmp/bin:$PATH" "$repo_root/scripts/build-kernel" \
	--source-url "$tmp/linux" \
	--commit "$attacker_commit" \
	--work "$tmp/work-poison" \
	--output "$tmp/output-poison" \
	--cache "$tmp/cache" \
	--jobs 1; then
	echo "cache-poisoned exact commit unexpectedly succeeded" >&2
	exit 1
else
	status=$?
	[[ $status -eq 4 ]]
fi
grep -Fq 'declared source did not provide exact commit' \
	"$tmp/output-poison/build.log"
