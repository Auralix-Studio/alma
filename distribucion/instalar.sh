#!/bin/sh
# Instalador de Alma para Linux/macOS (por usuario, sin sudo).
# Uso: colocá este script junto al binario descargado y ejecutá:
#   sh instalar.sh
set -e

DEST="$HOME/.local/bin"
DIR="$(cd "$(dirname "$0")" && pwd)"

SRC=""
for n in alma alma-linux-x64 alma-macos-x64 alma-macos-arm64; do
    if [ -f "$DIR/$n" ]; then SRC="$DIR/$n"; break; fi
done
if [ -z "$SRC" ]; then
    echo "No encontré el binario de alma junto a este script." >&2
    exit 1
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
