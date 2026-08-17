#!/bin/sh
# Build the release artifact the way the release workflow does, so a maintainer
# can reproduce it locally: one universal (arm64 + x86_64) binary, tarred with
# the licence, plus a SHA-256 file next to it.
#
#   Scripts/package.sh            → dist/amcu-<version>-macos-universal.tar.gz
#   Scripts/package.sh v0.6.0     → additionally refuses if the version the
#                                   binary reports is not 0.6.0
#
# The version is read from the built binary, not from the tag, so a tag that
# disagrees with Sources/AmcuCore/Version.swift fails loudly instead of
# shipping a binary that reports the wrong number.
set -eu

cd "$(dirname "$0")/.."
expected_tag="${1:-}"

echo "building universal release binary…" >&2
swift build -c release --arch arm64 --arch x86_64 >&2
bin_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
binary="$bin_dir/amcu"
[ -x "$binary" ] || { echo "error: $binary was not produced" >&2; exit 1; }

version="$("$binary" --version)"
if [ -n "$expected_tag" ] && [ "$expected_tag" != "v$version" ]; then
    echo "error: tag $expected_tag but the binary reports $version — bump Sources/AmcuCore/Version.swift (and extension/manifest.json) first" >&2
    exit 1
fi

archs="$(lipo -archs "$binary")"
case "$archs" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) echo "error: expected a universal binary, got: $archs" >&2; exit 1 ;;
esac

name="amcu-$version-macos-universal"
stage="$(mktemp -d)"
mkdir -p "$stage/$name" dist
install -m 755 "$binary" "$stage/$name/amcu"
install -m 644 LICENSE "$stage/$name/LICENSE"
tar -C "$stage" -czf "dist/$name.tar.gz" "$name"
rm -rf "$stage"

( cd dist && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256" )

echo "dist/$name.tar.gz" >&2
echo "dist/$name.tar.gz.sha256" >&2
cat "dist/$name.tar.gz.sha256" >&2
echo "$version"
