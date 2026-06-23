#!/bin/bash
# build-y1-native.sh - Build from native Linux path to avoid WSL path issues

set -e

WORK_DIR="/tmp/y1-build-$$"
REPO_DIR="/mnt/c/Users/jmaus/source/repos/koensayr"
DECODED_SRC="$REPO_DIR/staging/y1-decoded"
APKTOOL_JAR="$REPO_DIR/tools/apktool-2.9.3.jar"
OUTPUT_APK="$REPO_DIR/staging/Y1-patched.apk"

echo "=== Building patched Y1 APK from native Linux path ==="
echo ""

# Create temporary work directory
echo "Creating work directory: $WORK_DIR"
mkdir -p "$WORK_DIR"

# Copy decoded APK to Linux path
echo "Copying decoded APK to native Linux path..."
cp -r "$DECODED_SRC" "$WORK_DIR/y1-decoded"

# Build
echo "Building APK..."
cd "$WORK_DIR/y1-decoded"
java -jar "$APKTOOL_JAR" b . -o "$WORK_DIR/Y1-patched.apk"

if [ $? -eq 0 ]; then
	echo ""
	echo "✓ Build successful!"
	echo "Copying APK back to repo..."
	cp "$WORK_DIR/Y1-patched.apk" "$OUTPUT_APK"

	echo ""
	echo "✓ Patched APK created: $OUTPUT_APK"
	echo ""
	ls -lh "$OUTPUT_APK"
	echo ""
	echo "Cleaning up..."
	rm -rf "$WORK_DIR"

	echo ""
	echo "Next steps:"
	echo "1. Sign the APK: apksigner sign --ks your-key.jks Y1-patched.apk"
	echo "2. Install on device: adb install Y1-patched.apk"
	echo "3. Test autoshutdown with reboot"
else
	echo ""
	echo "✗ Build failed"
	echo "Work directory preserved for debugging: $WORK_DIR"
	exit 1
fi
