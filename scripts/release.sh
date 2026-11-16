#!/bin/zsh
# Builds Cumulus outside the Mac App Store: a Developer ID archive, notarized by Apple, published as a GitHub release,
# then the Homebrew cask points at it.
#
#   scripts/release.sh <build number>
#
# The build number is the one Xcode Cloud gave the same version on App Store Connect, so both copies carry the same.
# Needs: Xcode signed in with an account of the team (signing and notarization go through it, no password to store),
# gh signed in to the account that owns the repository, and the tap cloned at $TAP (default ~/Developer/homebrew-tap).
set -euo pipefail

build=${1:?usage: scripts/release.sh <build number>}
root=${0:A:h:h}
tap=${TAP:-$HOME/Developer/homebrew-tap}
repo=guikbsx/xcode-cloud-companion
work=$(mktemp -d)
version=$(xcodebuild -project "$root/xcode-cloud-companion.xcodeproj" -scheme Cumulus -showBuildSettings 2>/dev/null \
  | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
archive=$work/Cumulus.xcarchive
zip=$work/Cumulus-$version.zip

echo "Cumulus $version ($build), working in $work"

xcodebuild archive -project "$root/xcode-cloud-companion.xcodeproj" -scheme Cumulus -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive" -derivedDataPath "$work/dd" \
  CURRENT_PROJECT_VERSION="$build" ENABLE_HARDENED_RUNTIME=YES -allowProvisioningUpdates -quiet

cat > "$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>destination</key><string>upload</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>4HYT2U85R2</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$work/ExportOptions.plist" \
  -exportPath "$work/upload" -allowProvisioningUpdates -quiet

echo "Waiting for Apple's notarization…"
until xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$work/notarized" >/dev/null 2>&1; do sleep 20; done

app=$work/notarized/Cumulus.app
spctl --assess --type exec "$app"
xcrun stapler validate "$app" >/dev/null
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
sha=$(shasum -a 256 "$zip" | awk '{ print $1 }')

git -C "$root" tag -a "v$version" -m "Cumulus $version"
git -C "$root" push origin "v$version"
gh release create "v$version" "$zip" --repo "$repo" --verify-tag --title "Cumulus $version" \
  --notes "Install with \`brew install --cask guikbsx/tap/cumulus\`, or download the archive below. Signed with Developer ID and notarized by Apple. macOS 26 or later."

cask=$tap/Casks/cumulus.rb
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
brew style "$cask"
git -C "$tap" commit -qam "Cumulus $version"
git -C "$tap" push

echo "Released Cumulus $version: $zip ($sha)"
