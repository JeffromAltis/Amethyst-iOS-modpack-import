#!/bin/bash
set -e

APP_NAME="Amethyst"
BUILD_DIR="build-ios"
DIST_DIR="dist"
MOUNT_DIR="$HOME/ipad-livecontainer"

echo "=========================================="
echo "  Starting Amethyst iOS Local USB Build   "
echo "=========================================="

# 1. Clean and build native components (GL4ES, MoltenVK, JNI, etc.)
echo "[1/4] Cross-compiling C/C++ native layers..."
cmake -B $BUILD_DIR -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build $BUILD_DIR --parallel $(nproc)

# 2. Assemble .app bundle structure
echo "[2/4] Assembling .app payload..."
rm -rf $DIST_DIR Payload
mkdir -p Payload/$APP_NAME.app

# Copy output binaries and metadata into the app bundle
cp -R $BUILD_DIR/bin/* Payload/$APP_NAME.app/
if [ -f "Info.plist" ]; then
    cp Info.plist Payload/$APP_NAME.app/
fi

# 3. Apply ldid signing and entitlements for JIT/LiveContainer
echo "[3/4] Applying ldid entitlements..."
if [ -f "entitlements.plist" ]; then
    ldid -Sentitlements.plist Payload/$APP_NAME.app/$APP_NAME
fi

# Package into IPA
mkdir -p $DIST_DIR
zip -r $DIST_DIR/$APP_NAME.ipa Payload
echo "[+] Built $DIST_DIR/$APP_NAME.ipa successfully."

# 4. Deploy via USB directly into LiveContainer on iPad
echo "[4/4] Pushing to iPad via USB..."

# Find LiveContainer's App Bundle ID dynamically
LC_BUNDLE_ID=$(ifuse --list-apps | grep -i "livecontainer" | awk '{print $1}' | head -n 1)

if [ -z "$LC_BUNDLE_ID" ]; then
    echo "[!] Error: LiveContainer app not found on connected iPad."
    echo "[!] Fallback default: com.kdt.livecontainer"
    LC_BUNDLE_ID="com.kdt.livecontainer"
fi

# Mount LiveContainer's Document container over USB
mkdir -p $MOUNT_DIR
echo "[*] Mounting $LC_BUNDLE_ID to $MOUNT_DIR..."
ifuse --documents "$LC_BUNDLE_ID" $MOUNT_DIR

# Copy the built IPA into LiveContainer's import directory
mkdir -p $MOUNT_DIR/Applications
cp $DIST_DIR/$APP_NAME.ipa $MOUNT_DIR/Applications/

# Unmount cleanly
echo "[*] Unmounting USB interface..."
fusermount -u $MOUNT_DIR

echo "=========================================="
echo " SUCCESS: $APP_NAME.ipa pushed to iPad!  "
echo " Open LiveContainer on your iPad to test."
echo "=========================================="