#!/bin/sh
# Install amcu from the latest GitHub release — or from source — into a
# directory on your PATH. Non-interactive by design, so it works the same
# whether a person or an agent runs it:
#
#   curl -fsSL https://raw.githubusercontent.com/uoox/amcu/main/Scripts/install.sh | sh
#
# Options (flags or environment):
#   --version vX.Y.Z   AMCU_VERSION      install a specific release (default: latest)
#   --dir DIR          AMCU_INSTALL_DIR  where to put the binary (default: ~/.local/bin)
#   --source           AMCU_SOURCE=1     build from the main branch instead of
#                                        downloading a release (needs a Swift toolchain)
#
# It downloads the universal tarball for the chosen release, verifies its
# SHA-256 against the sum published beside it, installs the binary, and then
# prints what still needs a human: the two macOS permission prompts. It never
# writes into a package manager's prefix — see the README for why.
set -eu

REPO="uoox/amcu"
VERSION="${AMCU_VERSION:-latest}"
DIR="${AMCU_INSTALL_DIR:-$HOME/.local/bin}"
SOURCE="${AMCU_SOURCE:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#--version=}"; shift ;;
        --dir) DIR="$2"; shift 2 ;;
        --dir=*) DIR="${1#--dir=}"; shift ;;
        --source) SOURCE=1; shift ;;
        -h|--help)
            if [ -f "$0" ]; then sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
            else echo "usage: install.sh [--version vX.Y.Z] [--dir DIR] [--source]"; fi
            exit 0 ;;
        *) echo "install.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*" >&2; }
fail() { say "error: $*"; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "amcu is macOS only (this is $(uname -s))"
os_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$os_major" -ge 14 ] 2>/dev/null || fail "amcu needs macOS 14 or later (this is $(sw_vers -productVersion))"
command -v curl >/dev/null || fail "curl is required"

case "$DIR" in
    /opt/homebrew/bin|/usr/local/bin|/opt/homebrew/bin/|/usr/local/bin/)
        fail "$DIR belongs to a package manager; install somewhere else (default: ~/.local/bin)" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ -n "$SOURCE" ]; then
    command -v swift >/dev/null || fail "--source needs a Swift toolchain (xcode-select --install gives you one)"
    command -v git >/dev/null || fail "--source needs git"
    say "cloning ${REPO}…"
    git clone --quiet --depth 1 "https://github.com/$REPO" "$tmp/src"
    say "building (this takes a minute or two)…"
    ( cd "$tmp/src" && swift build -c release 2>&1 | tail -1 >&2 )
    binary="$tmp/src/.build/release/amcu"
else
    if [ "$VERSION" = "latest" ]; then
        # The redirect target of /releases/latest names the tag, and unlike the
        # API it is not rate limited.
        location="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" \
            || fail "could not reach github.com to find the latest release"
        VERSION="${location##*/}"
        case "$VERSION" in
            v[0-9]*) ;;
            *) fail "could not determine the latest release (got '$VERSION'); pass --version vX.Y.Z or --source" ;;
        esac
    fi
    case "$VERSION" in v*) ;; *) VERSION="v$VERSION" ;; esac
    ver="${VERSION#v}"
    name="amcu-$ver-macos-universal"
    base="https://github.com/$REPO/releases/download/$VERSION"

    say "downloading $name.tar.gz ($VERSION)…"
    curl -fsSL -o "$tmp/$name.tar.gz" "$base/$name.tar.gz" \
        || fail "no built binary for $VERSION at $base/$name.tar.gz — check https://github.com/$REPO/releases, or run with --source"
    curl -fsSL -o "$tmp/$name.tar.gz.sha256" "$base/$name.tar.gz.sha256" \
        || fail "release $VERSION has no checksum file; refusing to install an unverified binary (use --source)"
    ( cd "$tmp" && shasum -a 256 -c "$name.tar.gz.sha256" >/dev/null ) \
        || fail "checksum mismatch for $name.tar.gz — the download is corrupt or not what was published"
    tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
    binary="$tmp/$name/amcu"
fi

[ -x "$binary" ] || fail "no executable at $binary"
mkdir -p "$DIR"
install -m 755 "$binary" "$DIR/amcu"
# curl does not set the quarantine attribute, but a tarball that arrived via a
# browser might carry one; clearing it is harmless either way.
xattr -d com.apple.quarantine "$DIR/amcu" 2>/dev/null || true

installed="$("$DIR/amcu" --version)"
say "installed amcu $installed → $DIR/amcu"

case ":$PATH:" in
    *":$DIR:"*) ;;
    *) say ""
       say "note: $DIR is not on your PATH. Add to your shell profile:"
       say "      export PATH=\"$DIR:\$PATH\"" ;;
esac

say ""
say "next — the two things only a person can do:"
say "  1. Grant permissions to whatever will run amcu (your terminal, or the agent's host):"
say "       $DIR/amcu doctor --request        # triggers the macOS prompts"
say "     Accessibility is required for everything; Screen Recording only for \`amcu screenshot\`."
say "     Approve them in the dialogs (or in System Settings > Privacy & Security), then re-run"
say "       $DIR/amcu doctor                  # every line should read [ok]"
say "  2. Optional, for web pages: \`amcu browser install\`, then load the unpacked extension it names."
say ""
say "for an agent: run \`amcu guide\` before the first use in a session (details: https://github.com/$REPO#quick-start)"
