#!/bin/sh
# Instalador de Alma para Linux x64 (por usuario, sin sudo).
#
# En un comando (descarga la última versión publicada):
#   curl -fsSL https://github.com/Auralix-Studio/alma/releases/latest/download/instalar.sh | sh
# Una versión concreta: ALMA_VERSION=v0.1.0 sh instalar.sh
#
# Sin conexión: coloca este script junto al binario (alma-linux-x64 o alma) y a
# SHA256SUMS.txt, y ejecuta:  sh instalar.sh
#
# La instalación se aborta si falta SHA256SUMS.txt, si el binario no figura en él
# con su nombre exacto, si no hay herramienta de hash o si el hash no coincide.
set -eu

REPOSITORIO="Auralix-Studio/alma"
DEST="$HOME/.local/bin"

fallar() { echo "Error: $*" >&2; exit 1; }

# 1. Origen: binario local junto al script o descarga de GitHub Releases.
DIR=""
case "$0" in
    */instalar.sh|instalar.sh) DIR="$(cd "$(dirname "$0")" && pwd)" ;;
esac
SRC=""
SRC_NAME=""
if [ -n "$DIR" ]; then
    for n in alma-linux-x64 alma; do
        if [ -f "$DIR/$n" ]; then SRC="$DIR/$n"; SRC_NAME="$n"; break; fi
    done
fi
TEMPORAL=""
if [ -z "$SRC" ]; then
    SO="$(uname -s)"
    ARQ="$(uname -m)"
    case "$SO/$ARQ" in
        Linux/x86_64|Linux/amd64) SRC_NAME="alma-linux-x64" ;;
        *) fallar "todavía no se publican binarios para $SO/$ARQ (solo Linux x64 y Windows x64)." ;;
    esac
    if [ -n "${ALMA_VERSION:-}" ]; then BASE="https://github.com/$REPOSITORIO/releases/download/$ALMA_VERSION"
    else BASE="https://github.com/$REPOSITORIO/releases/latest/download"; fi
    TEMPORAL="$(mktemp -d)"
    trap 'rm -rf "$TEMPORAL"' EXIT INT TERM
    descargar() {
        if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
        elif command -v wget >/dev/null 2>&1; then wget -q "$1" -O "$2"
        else fallar "se necesita curl o wget para descargar Alma."; fi
    }
    echo "Descargando $BASE/$SRC_NAME"
    descargar "$BASE/$SRC_NAME" "$TEMPORAL/$SRC_NAME"
    descargar "$BASE/SHA256SUMS.txt" "$TEMPORAL/SHA256SUMS.txt"
    DIR="$TEMPORAL"
    SRC="$TEMPORAL/$SRC_NAME"
fi

# 2. Verificación SHA-256 obligatoria.
SUMAS="$DIR/SHA256SUMS.txt"
[ -f "$SUMAS" ] || fallar "falta SHA256SUMS.txt junto al binario; no se puede verificar $SRC_NAME."
# Coincidencia exacta del nombre (columna 2; admite el prefijo '*' de modo binario).
EXPECTED=$(awk -v n="$SRC_NAME" '$2 == n || $2 == "*" n { print $1; exit }' "$SUMAS")
[ -n "$EXPECTED" ] || fallar "$SRC_NAME no figura en SHA256SUMS.txt."
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$SRC" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL=$(shasum -a 256 "$SRC" | awk '{print $1}')
else
    fallar "no se encontró sha256sum ni shasum para verificar $SRC_NAME."
fi
[ "$ACTUAL" = "$EXPECTED" ] || fallar "el hash SHA-256 de $SRC_NAME no coincide: no se instala."
echo "Hash SHA-256 verificado: $SRC_NAME"

# 3. Instalación.
mkdir -p "$DEST"
cp "$SRC" "$DEST/alma"
chmod +x "$DEST/alma"

echo "Alma instalado en: $DEST/alma"
"$DEST/alma" version
case ":$PATH:" in
    *":$DEST:"*) : ;;
    *)
        echo ""
        echo "Nota: $DEST no está en tu PATH. Agrega esta línea a tu ~/.profile o ~/.bashrc:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
esac
echo "Prueba:  alma ejecutar hola.alma"
