#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <derived-data-path> <output-directory> <version>" >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 64
fi

derived_data_path=$1
output_dir=$2
version=$3

if [[ ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]]; then
  echo "Invalid package version: $version" >&2
  exit 64
fi

if [[ ! -d "$derived_data_path" ]]; then
  echo "Derived data directory not found: $derived_data_path" >&2
  exit 1
fi
derived_data_path=$(cd "$derived_data_path" && pwd -P)

products_dir="$derived_data_path/Build/Products"
mac_app="$products_dir/Release/Daybreak.app"
ios_app="$products_dir/Release-iphoneos/Daybreak.app"

if [[ ! -d "$mac_app" ]]; then
  echo "macOS app bundle not found: $mac_app" >&2
  exit 1
fi
if [[ ! -f "$mac_app/Contents/Info.plist" ]]; then
  echo "macOS app Info.plist not found: $mac_app/Contents/Info.plist" >&2
  exit 1
fi
if [[ ! -d "$ios_app" ]]; then
  echo "iOS app bundle not found: $ios_app" >&2
  exit 1
fi
if [[ ! -f "$ios_app/Info.plist" ]]; then
  echo "iOS app Info.plist not found: $ios_app/Info.plist" >&2
  exit 1
fi

mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd -P)

tmp_root=${TMPDIR:-/tmp}
tmp_dir=$(mktemp -d "${tmp_root%/}/daybreak-release.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

versioned_name="Daybreak-$version"
dmg_name="$versioned_name-macOS.dmg"
ipa_name="$versioned_name-iOS.ipa"
dmg_path="$output_dir/$dmg_name"
ipa_path="$output_dir/$ipa_name"
dmg_staged="$tmp_dir/$dmg_name"
ipa_staged="$tmp_dir/$ipa_name"

dmg_contents="$tmp_dir/dmg-contents"
mkdir -p "$dmg_contents"
ditto "$mac_app" "$dmg_contents/Daybreak.app"
ln -s /Applications "$dmg_contents/Applications"
hdiutil create \
  -volname "Daybreak $version" \
  -srcfolder "$dmg_contents" \
  -ov \
  -format UDZO \
  "$dmg_staged"

ipa_contents="$tmp_dir/ipa/Payload"
mkdir -p "$ipa_contents"
ditto "$ios_app" "$ipa_contents/Daybreak.app"
ditto -c -k --sequesterRsrc --keepParent "$tmp_dir/ipa/Payload" "$ipa_staged"

mv -f "$dmg_staged" "$dmg_path"
mv -f "$ipa_staged" "$ipa_path"
printf 'Created unsigned packages:\n  %s\n  %s\n' "$dmg_path" "$ipa_path"
