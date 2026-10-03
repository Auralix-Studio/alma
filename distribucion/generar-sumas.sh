#!/bin/sh
# Genera SHA256SUMS.txt para los binarios de una versión, en el formato que
# verifican instalar.sh / instalar.ps1 y `sha256sum -c`.
# Uso: sh generar-sumas.sh <directorio-con-binarios>
# Se publica junto a los binarios de esa misma versión; no se versiona en el repo.
set -eu
DIR="${1:?Uso: sh generar-sumas.sh <directorio-con-binarios>}"
cd "$DIR"
encontrados=""
for n in alma alma-linux-x64 alma-macos-x64 alma-macos-arm64 alma.exe alma-windows-x64.exe; do
    [ -f "$n" ] && encontrados="$encontrados $n"
done
if [ -z "$encontrados" ]; then
    echo "No hay binarios de alma en $DIR" >&2
    exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    sha256sum $encontrados > SHA256SUMS.txt
else
    # shellcheck disable=SC2086
    shasum -a 256 $encontrados > SHA256SUMS.txt
fi
cat SHA256SUMS.txt
