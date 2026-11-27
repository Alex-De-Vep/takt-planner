#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../../.." && pwd)
arch=${1:-$(dpkg --print-architecture)}
output=${2:-"$repo/dist"}

case "$arch" in
    amd64) rid=linux-x64 ;;
    arm64) rid=linux-arm64 ;;
    *) printf 'Unsupported Debian architecture: %s\n' "$arch" >&2; exit 2 ;;
esac

project="$repo/apps/linux/src/Takt.Linux/Takt.Linux.csproj"
version=$(dotnet msbuild "$project" -nologo -getProperty:Version)
debian_version=${version/-/\~}
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT

app_id=io.github.alex_de_vep.Takt
name="Takt-Linux-$version-$arch"
package="$stage/deb"
app="$package/usr/lib/takt"
install -d "$app/lib" "$output" "$package/DEBIAN" "$package/usr/bin" \
    "$package/usr/share/applications" "$package/usr/share/icons/hicolor/256x256/apps"

dotnet publish "$project" -r "$rid" --self-contained -c Release \
    --artifacts-path "$stage/artifacts" --output "$app/lib" \
    -p:DebugType=None -p:DebugSymbols=false

install -m 644 "$repo/LICENSE" "$app/LICENSE"
cat > "$app/takt" <<'EOF'
#!/bin/sh
set -eu
root=$(dirname -- "$(readlink -f -- "$0")")
exec "$root/lib/Takt.Linux" "$@"
EOF
chmod 755 "$app/takt"

ln -s ../lib/takt/takt "$package/usr/bin/takt"
install -m 644 "$here/../packaging/$app_id.desktop" "$package/usr/share/applications/$app_id.desktop"
install -m 644 "$repo/apps/macos/Planner/Assets.xcassets/AppIcon.appiconset/icon_256x256@1x.png" \
    "$package/usr/share/icons/hicolor/256x256/apps/$app_id.png"

cat > "$package/DEBIAN/control" <<EOF
Package: takt-linux-preview
Version: $debian_version
Architecture: $arch
Maintainer: Takt contributors
Section: office
Priority: optional
Depends: libgtk-4-1 (>= 4.14), libadwaita-1-0 (>= 1.5), libicu74 | libicu76 | libicu78, libssl3t64 | libssl3, libgssapi-krb5-2, zlib1g, libstdc++6
Description: Takt local task planner for Linux
 Preview client with native GTK controls and a local task library.
EOF

dpkg-deb --root-owner-group --build "$package" "$stage/$name.deb"
install -m 644 "$stage/$name.deb" "$output/$name.deb"
(cd "$output" && sha256sum "$name.deb" > "$name.deb.sha256")
