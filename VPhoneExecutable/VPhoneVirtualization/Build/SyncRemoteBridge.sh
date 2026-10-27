#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
source="${1:-$root/../vphone_remote/dist}"
target="$root/VPhoneExecutable/VPhoneVirtualization/RemoteBridgeArtifacts"
[[ -x "$source/vphone-remote-bridge" ]] || { print -u2 "Missing compiled bridge: $source"; exit 1; }
[[ -d "$source/VPhone Remote Audio.app" ]] || { print -u2 "Missing audio helper app: $source"; exit 1; }
/usr/bin/codesign --verify "$source/vphone-remote-bridge"
/usr/bin/codesign --verify --deep --strict "$source/VPhone Remote Audio.app"
/bin/mkdir -p "$target"
/bin/cp "$source/vphone-remote-bridge" "$target/vphone-remote-bridge"
/bin/rm -rf "$target/VPhoneRemoteAudio.app"
/bin/cp -R "$source/VPhone Remote Audio.app" "$target/VPhoneRemoteAudio.app"
/usr/bin/shasum -a 256 "$target/vphone-remote-bridge" "$target/VPhoneRemoteAudio.app/Contents/MacOS/vphone-remote-audio"
