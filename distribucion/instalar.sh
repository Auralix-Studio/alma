#!/bin/sh
# Instalador de Alma para Linux/macOS (por usuario, sin sudo).
# Uso: colocá este script junto al binario descargado y a SHA256SUMS.txt y ejecutá:
#   sh instalar.sh
# La instalación se aborta si falta SHA256SUMS.txt, si el binario no figura en él,
# si no hay herramienta de hash disponible o si el hash no coincide.
set -eu

DEST="$HOME/.local/bin"
DIR="$(cd "$(dirname "$0")" && pwd)"

SRC=""
SRC_NAME=""
for n in alma alma-linux-x64 alma-macos-x64 alma-macos-arm64; do
    if [ -f "$DIR/$n" ]; then SRC="$DIR/$n"; SRC_NAME="$n"; break; fi
done
if [ -z "$SRC" ]; then
    echo "No encontré el binario de alma junto a este script." >&2
    exit 1
fi

SUMAS="$DIR/SHA256SUMS.txt"
if [ ! -f "$SUMAS" ]; then
    echo "Error: falta SHA256SUMS.txt junto al binario; no se puede verificar $SRC_NAME. Abortando." >&2
    exit 1
fi
# Coincidencia exacta del nombre (columna 2; admite el prefijo '*' de modo binario).
EXPECTED=$(awk -v n="$SRC_NAME" '$2 == n || $2 == "*" n { print $1; exit }' "$SUMAS")
if [ -z "$EXPECTED" ]; then
    echo "Error: $SRC_NAME no figura en SHA256SUMS.txt. Abortando." >&2
    exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$SRC" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL=$(shasum -a 256 "$SRC" | awk '{print $1}')
else
    echo "Error: no se encontró sha256sum ni shasum para verificar $SRC_NAME. Abortando." >&2
    exit 1
fi
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "Error: el hash SHA256 de $SRC_NAME no coincide. Abortando." >&2
    exit 1
fi
echo "Hash SHA256 verificado: $SRC_NAME"

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
