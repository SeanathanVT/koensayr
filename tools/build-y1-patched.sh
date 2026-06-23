#!/bin/bash
# build-y1-patched.sh - Build the patched Y1 APK

set -e

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
DECODED_DIR="$SCRIPT_DIR/../staging/y1-decoded"
OUTPUT_APK="$SCRIPT_DIR/../staging/Y1-patched.apk"
APKTOOL_JAR="$SCRIPT_DIR/../tools/apktool-2.9.3.jar"

cd "$DECODED_DIR"

echo "=== Building patched Y1 APK ==="
echo "Decoded directory: $DECODED_DIR"
echo "Output APK: $OUTPUT_APK"
echo ""

# Build with apktool
echo "Building APK..."
java -jar "$APKTOOL_JAR" b . -o "$OUTPUT_APK" --use-aapt2

if [ $? -eq 0 ]; then
	echo ""
	echo "✓ APK built successfully: $OUTPUT_APK"
	echo ""
	echo "Next steps:"
	echo "1. Sign the APK with your signing key"
	echo "2. Install on the Y1 device"
	echo "3. Test the autoshutdown timer with reboot"
else
	echo ""
	echo "✗ Build failed. Trying without aapt2..."
	java -jar "$APKTOOL_JAR" b . -o "$OUTPUT_APK"
fi
