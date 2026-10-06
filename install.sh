#!/bin/sh
# Install the release or beta SDK into the current user's directories.
set -eu
channel=release
version=
prefix=${LEAF_INSTALL_DIR:-"$HOME/.local/share/leaf"}
bin_dir=${LEAF_BIN_DIR:-"$HOME/.local/bin"}
download_base=https://github.com/SatoriTours/Leaf
update_path=1
fail() { printf 'leaf install: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --channel|--version|--prefix|--bin-dir|--download-base)
            [ "$#" -ge 2 ] || fail "missing value for $1"
            case "$1" in
                --channel) channel=$2;;
                --version) version=$2;;
                --prefix) prefix=$2;;
                --bin-dir) bin_dir=$2;;
                --download-base) download_base=$2;;
            esac
            shift 2;;
        --no-path) update_path=0; shift;;
        --help|-h)
            printf 'Usage: install.sh [--channel release|beta] [--version vX.Y.Z] [--prefix DIR] [--bin-dir DIR] [--no-path]\n'
            exit 0;;
        *) fail "unknown option: $1";;
    esac
done
case "$channel" in release|beta) ;; *) fail 'channel must be release or beta';; esac
if [ -n "$version" ]; then
    [ "$channel" = release ] || fail '--version is only available for release'
    printf '%s\n' "$version" | LC_ALL=C grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || fail 'version must be vX.Y.Z'
fi
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) target=linux-x86_64; bridge_name=libleaf_gpui.so;;
    Darwin-x86_64) target=macos-x86_64; bridge_name=libleaf_gpui.dylib;;
    Darwin-arm64|Darwin-aarch64) target=macos-aarch64; bridge_name=libleaf_gpui.dylib;;
    *) fail 'unsupported platform; supported: Linux x86_64, macOS Intel/Apple Silicon (Windows: install.ps1)';;
esac
for tool in curl tar mktemp; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
if command -v sha256sum >/dev/null 2>&1; then hash_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then hash_tool=shasum
else fail 'sha256sum or shasum is required'; fi
case "$download_base" in https://*|file://*) ;; *) fail 'download base must use HTTPS (or file:// for offline installation)';; esac
asset=leaf-sdk-$target.tar.gz
if [ "$channel" = beta ]; then base_url=$download_base/releases/download/beta
elif [ -n "$version" ]; then base_url=$download_base/releases/download/$version
else base_url=$download_base/releases/latest/download; fi
# Nothing in the existing installation is changed until download and validation succeed.
mkdir -p "$prefix/versions" "$bin_dir"
prefix=$(cd "$prefix" && pwd -P)
bin_dir=$(cd "$bin_dir" && pwd -P)
staging=$(mktemp -d "$prefix/versions/.install.XXXXXXXX")
entry_tmp=
cleanup() { [ -z "$entry_tmp" ] || rm -f "$entry_tmp"; rm -rf "$staging"; }
trap cleanup EXIT HUP INT TERM
curl --proto '=https,file' --proto-redir '=https' -fsSL --retry 3 --connect-timeout 15 -o "$staging/$asset" "$base_url/$asset"
curl --proto '=https,file' --proto-redir '=https' -fsSL --retry 3 --connect-timeout 15 -o "$staging/checksum" "$base_url/$asset.sha256"
expected=$(awk 'NR==1 {print $1}' "$staging/checksum")
printf '%s\n' "$expected" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{64}$' || fail 'invalid checksum file'
if [ "$hash_tool" = sha256sum ]; then actual=$(sha256sum "$staging/$asset" | awk '{print $1}')
else actual=$(shasum -a 256 "$staging/$asset" | awk '{print $1}'); fi
[ "$expected" = "$actual" ] || fail 'checksum mismatch; existing installation kept'
# Refuse links and entries outside the expected archive root before extraction.
tar -tzf "$staging/$asset" > "$staging/entries"
if LC_ALL=C grep -Eq '(^/|(^|/)\.\.(/|$))' "$staging/entries"; then fail 'invalid SDK archive paths'; fi
while IFS= read -r entry; do
    case "$entry" in leaf-sdk|leaf-sdk/|leaf-sdk/*) ;; *) fail 'invalid SDK archive root';; esac
done < "$staging/entries"
tar -tvzf "$staging/$asset" > "$staging/details"
if LC_ALL=C grep -Eq '^[lh]' "$staging/details"; then fail 'SDK archive must not contain links'; fi
tar -xzf "$staging/$asset" -C "$staging"
for file in bin/leaf src/leaf.nim toolchain/nim/bin/nim toolchain/nim/lib/system.nim sdk.json "lib/$bridge_name"; do
    [ -f "$staging/leaf-sdk/$file" ] || fail "SDK file missing: $file"
done
"$staging/leaf-sdk/bin/leaf" --verify-sdk "$channel" "$target" "$version" || fail 'SDK metadata or executable does not match this installation'
"$staging/leaf-sdk/bin/leaf" --version || fail 'SDK executable cannot run on this system'
installed=$prefix/versions/$channel-$(basename "$staging" | sed 's/^\.install\.//')
mv "$staging/leaf-sdk" "$installed"
entry_tmp=$bin_dir/.leaf-install-$$
[ ! -d "$bin_dir/leaf" ] || fail 'command destination is a directory'
ln -s "$installed/bin/leaf" "$entry_tmp"
mv -f "$entry_tmp" "$bin_dir/leaf"
entry_tmp=
# Add PATH once. A new shell reads this; a subprocess cannot change its parent shell.
if [ "$update_path" = 1 ]; then
    escaped=$(printf '%s' "$bin_dir" | sed "s/'/'\\\\''/g")
    path_line="export PATH='$escaped':\"\$PATH\" # Leaf SDK"
    case "${SHELL:-}" in
        */zsh) shell_profile=${ZDOTDIR:-$HOME}/.zshrc;;
        *) shell_profile=$HOME/.bashrc;;
    esac
    for profile in "$HOME/.profile" "$shell_profile"; do
        mkdir -p "$(dirname "$profile")"
        if [ ! -f "$profile" ] || ! grep -Fqx "$path_line" "$profile"; then printf '\n%s\n' "$path_line" >> "$profile"; fi
    done
fi
printf 'Installed %s SDK: %s\n' "$channel" "$installed"
printf 'Command: %s/leaf (open a new terminal to refresh PATH)\n' "$bin_dir"
