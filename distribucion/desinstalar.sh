#!/bin/sh
# Desinstalador de Alma para Linux/macOS.
# Uso:  sh desinstalar.sh
set -e

BIN="$HOME/.local/bin/alma"
if [ -f "$BIN" ]; then
    rm -f "$BIN"
    echo "Alma desinstalado ($BIN eliminado)."
else
    echo "No estaba instalado en $BIN (nada que borrar)."
fi
