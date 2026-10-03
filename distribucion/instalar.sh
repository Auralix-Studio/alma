#!/bin/sh
# Instalador de Alma para Linux/macOS (por usuario, sin sudo).
# Uso: colocá este script junto al binario descargado y ejecutá:
#   sh instalar.sh
set -e

DEST="$HOME/.local/bin"
DIR="$(cd "$(dirname "$0")" && pwd)"

SRC_NAME=""
for n in alma alma-linux-x64 alma-macos-x64 alma-macos-arm64; do
    if [ -f "$DIR/$n" ]; then SRC="$DIR/$n"; SRC_NAME="$n"; break; fi
done
if [ -z "$SRC" ]; then
    echo "No encontré el binario de alma junto a este script." >&2
    exit 1
fi

if [ -f "$DIR/SHA256SUMS.txt" ]; then
    EXPECTED=$(grep "$SRC_NAME" "$DIR/SHA256SUMS.txt" | awk '{print $1}')
    if [ -n "$EXPECTED" ]; then
        if command -v sha256sum >/dev/null 2>&1; then
            ACTUAL=$(sha256sum "$SRC" | awk '{print $1}')
        elif command -v shasum >/dev/null 2>&1; then
            ACTUAL=$(shasum -a 256 "$SRC" | awk '{print $1}')
        else
            echo "Aviso: No se encontró sha256sum ni shasum. Omitiendo validación."
            ACTUAL="$EXPECTED"
        fi
        if [ "$ACTUAL" != "$EXPECTED" ]; then
            echo "Error: El hash SHA256 de $SRC_NAME no coincide. Abortando." >&2
            exit 1
        fi
    fi
fi

mkdir -p "$DEST"
cp "$SRC" "$DEST/alma"
chmod +x "$DEST/alma"

echo "Alma instalado en: $DEST/alma"
case ":$PATH:" in
    *":$DEST:"*) : ;;
    *)
        echo ""
        echo "Nota: $DEST no está en tu PATH. Agregá esta línea a tu ~/.profile o ~/.bashrc:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
esac
echo "Probá:  alma version"
