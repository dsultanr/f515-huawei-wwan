#!/bin/bash
# Builds F515WwanApp.apk without gradle: aapt2 -> javac -> d8 -> zipalign -> apksigner.
set -euo pipefail

SDK=/home/dsultanr/android-sdk
BT=$SDK/android-14
PLATFORM=$SDK/android-11/android.jar
PROJ=$(cd "$(dirname "$0")" && pwd)
OUT=$PROJ/build
APK=$PROJ/F515WwanApp.apk

mkdir -p "$OUT/classes"
mkdir -p "$OUT/dex"

echo "== aapt2 link (manifest + assets)"
"$BT/aapt2" link \
    --manifest "$PROJ/AndroidManifest.xml" \
    -I "$PLATFORM" \
    -A "$PROJ/assets" \
    --min-sdk-version 26 --target-sdk-version 29 \
    -o "$OUT/base.apk"

echo "== javac"
find "$PROJ/src" -name '*.java' > "$OUT/sources.txt"
javac -source 8 -target 8 -nowarn \
    -bootclasspath "$PLATFORM" \
    -d "$OUT/classes" @"$OUT/sources.txt" 2>&1 | grep -v 'bootstrap class path' || true

echo "== d8"
"$BT/d8" --min-api 26 --output "$OUT/dex" \
    $(find "$OUT/classes" -name '*.class')

echo "== package"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q -X "$OUT/unsigned.apk" classes.dex)

echo "== zipalign + sign"
if [ ! -f "$PROJ/keystore.jks" ]; then
    keytool -genkeypair -keystore "$PROJ/keystore.jks" -alias f515wwan \
        -storepass f515wwan -keypass f515wwan -keyalg RSA -keysize 2048 \
        -validity 10000 -dname "CN=F515WwanApp, O=f515, C=RU" >/dev/null 2>&1
    echo "   (created keystore.jks)"
fi
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --ks "$PROJ/keystore.jks" --ks-pass pass:f515wwan \
    --key-pass pass:f515wwan --v1-signing-enabled true --v2-signing-enabled true \
    --out "$APK" "$OUT/aligned.apk"

echo "== done"
ls -la "$APK"
"$BT/apksigner" verify --print-certs "$APK" | head -3
