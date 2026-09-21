#!/bin/sh
set -eu
TARGET_DIR="$1"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILDROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_DIR="$(CDPATH= cd -- "$BUILDROOT_DIR/.." && pwd)"
APP_DIR="${NEXTGEN_APP_DIR:-$WORKSPACE_DIR/app}"
PRODUCT="${NEXTGEN_PRODUCT:-sound}"
EXEC_DIR="$TARGET_DIR/root/Exec"
COMMON_RUNTIME="$APP_DIR/Application/Files/Runtime/Sound/Exec"
mkdir -p "$TARGET_DIR/root" "$EXEC_DIR"

for name in Arial.ttf NotoSansCJKtc-Regular.ttf Translations.csv ionicons.ttf open-iconic.ttf; do
    [ ! -e "$COMMON_RUNTIME/$name" ] || cp -L "$COMMON_RUNTIME/$name" "$EXEC_DIR/$name"
done

case "$PRODUCT" in
    sound)
        APP_BINARY="$APP_DIR/Application/build/sound/bin/NextGen"
        if [ -d "$COMMON_RUNTIME/Templates" ]; then
            rm -rf "$EXEC_DIR/Templates"
            mkdir -p "$EXEC_DIR/Templates"
            cp -aL "$COMMON_RUNTIME/Templates/." "$EXEC_DIR/Templates/"
        fi
        [ ! -f "$COMMON_RUNTIME/FacCalFile.dat" ] || install -m 0644 "$COMMON_RUNTIME/FacCalFile.dat" "$EXEC_DIR/FacCalFile.dat"
        if [ -f "$APP_DIR/Application/Files/hpdc.csv" ]; then
            install -d -m 0755 "$EXEC_DIR/BaseHPD"
            install -m 0644 "$APP_DIR/Application/Files/hpdc.csv" "$EXEC_DIR/BaseHPD/hpdc.csv"
        fi
        ;;
    vibra)
        APP_BINARY="$APP_DIR/Application/build/vibra/bin/NextGen"
        ;;
    *)
        echo "Unknown NEXTGEN_PRODUCT: $PRODUCT" >&2
        exit 1
        ;;
esac

if [ -x "$APP_BINARY" ]; then
    install -m 0755 "$APP_BINARY" "$TARGET_DIR/root/NextGen"
else
    echo "warning: NextGen application not staged (missing $APP_BINARY)" >&2
fi
