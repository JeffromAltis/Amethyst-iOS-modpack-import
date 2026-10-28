#!/bin/bash
# Copy an Amethyst .ipa into LiveContainer's Documents folder on a USB-connected iPad.
# Usage: scripts/deploy_usb.sh path/to/Amethyst.ipa
#
# LiveContainer patches and re-signs apps when it installs them, so this script does
# NOT overwrite Documents/Applications/*.app. It drops the .ipa where LiveContainer can
# see it; finish by tapping "+" in LiveContainer and picking Amethyst-latest.ipa.
set -euo pipefail

LC_BUNDLE_ID="${LC_BUNDLE_ID:-com.kdt.livecontainer.W89WFJM5TF}"
DEST_NAME="Amethyst-latest.ipa"

IPA="${1:?usage: $0 path/to/app.ipa}"
[ -f "$IPA" ] || { echo "No such file: $IPA" >&2; exit 1; }

for tool in idevice_id ifuse fusermount; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done

if [ -z "$(idevice_id -l)" ]; then
    echo "No iPad connected over USB (is it unlocked and trusted?)" >&2
    exit 2
fi

if ! ifuse --list-apps | grep -q "\"$LC_BUNDLE_ID\""; then
    echo "LiveContainer ($LC_BUNDLE_ID) not found on the device." >&2
    exit 1
fi

MOUNT_DIR="$(mktemp -d)"
cleanup() { fusermount -u "$MOUNT_DIR" 2>/dev/null || true; rmdir "$MOUNT_DIR" 2>/dev/null || true; }
trap cleanup EXIT

ifuse --documents "$LC_BUNDLE_ID" "$MOUNT_DIR"
cp "$IPA" "$MOUNT_DIR/$DEST_NAME.partial"
mv -f "$MOUNT_DIR/$DEST_NAME.partial" "$MOUNT_DIR/$DEST_NAME"
sync

echo "Copied $(basename "$IPA") to LiveContainer as $DEST_NAME."
echo "On the iPad: open LiveContainer, tap +, and pick $DEST_NAME (Files > On My iPad > LiveContainer)."
