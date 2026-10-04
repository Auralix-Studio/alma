#!/bin/sh
# Instalador de Alma para Linux x64 y ARM64, incluido Android con Termux
# (por usuario, sin sudo).
#
# En un comando (descarga la última versión publicada):
#   curl -fsSL https://raw.githubusercontent.com/Auralix-Studio/alma/main/distribucion/instalar.sh | sh
# Una versión concreta: ... | ALMA_VERSION=v0.1.1 sh
#
# Sin conexión: coloca este script junto al binario (alma-linux-x64,
# alma-linux-arm64 o alma) y a SHA256SUMS.txt, y ejecuta:  sh instalar.sh
#
# Destino: ~/.local/bin; en Termux, $PREFIX/bin (ya está en el PATH).
# La instalación se aborta si falta SHA256SUMS.txt, si el binario no figura en él
# con su nombre exacto, si no hay herramienta de hash o si el hash no coincide.
# Sin colores: NO_COLOR=1.
set -eu

REPOSITORIO="Auralix-Studio/alma"

# Termux (Android): instala en $PREFIX/bin, que ya forma parte del PATH.
case "${PREFIX:-}" in
    */com.termux/*) TERMUX=1 ;;
    *) TERMUX="${TERMUX_VERSION:+1}" ;;
esac
if [ -n "$TERMUX" ]; then DEST="$PREFIX/bin"; else DEST="$HOME/.local/bin"; fi

SO="$(uname -s)"
ARQ="$(uname -m)"
case "$SO/$ARQ" in
    Linux/x86_64|Linux/amd64) NOMBRE="alma-linux-x64"; PLATAFORMA="Linux x64" ;;
    Linux/aarch64|Linux/arm64) NOMBRE="alma-linux-arm64"; PLATAFORMA="Linux ARM64" ;;
    *) NOMBRE=""; PLATAFORMA="$SO/$ARQ" ;;
esac
if [ -n "$TERMUX" ]; then PLATAFORMA="$PLATAFORMA (Termux)"; fi

# — Presentación —
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    VIOLETA=$(printf '\033[38;2;155;133;255m'); AMBAR=$(printf '\033[38;2;255;181;71m')
    VERDE=$(printf '\033[38;2;80;200;120m'); ROJO=$(printf '\033[38;2;240;90;90m')
    GRIS=$(printf '\033[38;2;150;150;160m'); NEGRITA=$(printf '\033[1m'); FIN=$(printf '\033[0m')
else
    VIOLETA=""; AMBAR=""; VERDE=""; ROJO=""; GRIS=""; NEGRITA=""; FIN=""
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) OK="✓"; FLECHA="→"; MAL="✗" ;;
    *) OK="ok"; FLECHA="->"; MAL="x" ;;
esac
paso() { printf '  %s%s%s %s\n' "$VERDE" "$OK" "$FIN" "$1"; }
info() { printf '  %s%s%s %s\n' "$VIOLETA" "$FLECHA" "$FIN" "$1"; }
fallar() { printf '\n  %s%s%s %s\n\n' "$ROJO" "$MAL" "$FIN" "$*" >&2; exit 1; }

printf '\n'
printf '     %s)%s\n' "$VIOLETA" "$FIN"
printf '    %s) \\%s      %sAlma%s\n' "$VIOLETA" "$FIN" "$NEGRITA" "$FIN"
printf '   %s/ ) (%s     %sprogramación en español%s\n' "$VIOLETA" "$FIN" "$GRIS" "$FIN"
printf '   %s\\(%s%s_%s%s)/%s\n\n' "$VIOLETA" "$FIN" "$AMBAR" "$FIN" "$VIOLETA" "$FIN"

# 1. Origen: binario local junto al script o descarga de GitHub Releases.
DIR=""
case "$0" in
    */instalar.sh|instalar.sh) DIR="$(cd "$(dirname "$0")" && pwd)" ;;
esac
SRC=""
SRC_NAME=""
if [ -n "$DIR" ]; then
    for n in $NOMBRE alma; do
        if [ -f "$DIR/$n" ]; then SRC="$DIR/$n"; SRC_NAME="$n"; break; fi
    done
fi
TEMPORAL=""
if [ -n "$SRC" ]; then
    info "Instalación sin conexión desde $DIR"
else
    if [ -z "$NOMBRE" ]; then
        fallar "Todavía no se publican binarios para $PLATAFORMA (hay Linux x64, Linux ARM64 —también Termux— y Windows x64; los móviles ARM de 32 bits no están soportados)."
    fi
    SRC_NAME="$NOMBRE"
    if [ -n "${ALMA_VERSION:-}" ]; then
        BASE="https://github.com/$REPOSITORIO/releases/download/$ALMA_VERSION"
        info "Plataforma: $PLATAFORMA  ·  versión $ALMA_VERSION"
    else
        BASE="https://github.com/$REPOSITORIO/releases/latest/download"
        info "Plataforma: $PLATAFORMA  ·  última versión"
    fi
    TEMPORAL="$(mktemp -d)"
    trap 'rm -rf "$TEMPORAL"' EXIT INT TERM
    descargar() { # url destino título
        if command -v curl >/dev/null 2>&1; then
            if [ -t 2 ]; then
                printf '  %s↓%s %s\n' "$AMBAR" "$FIN" "$3"
                curl -fL --progress-bar "$1" -o "$2" || fallar "No se pudo descargar $1"
            else
                curl -fsSL "$1" -o "$2" || fallar "No se pudo descargar $1"
            fi
        elif command -v wget >/dev/null 2>&1; then
            wget -q "$1" -O "$2" || fallar "No se pudo descargar $1"
        else
            fallar "Se necesita curl o wget para descargar Alma."
        fi
        paso "Descargado $3"
    }
    descargar "$BASE/$SRC_NAME" "$TEMPORAL/$SRC_NAME" "$SRC_NAME"
    descargar "$BASE/SHA256SUMS.txt" "$TEMPORAL/SHA256SUMS.txt" "SHA256SUMS.txt"
    DIR="$TEMPORAL"
    SRC="$TEMPORAL/$SRC_NAME"
fi

# 2. Verificación SHA-256 obligatoria.
SUMAS="$DIR/SHA256SUMS.txt"
[ -f "$SUMAS" ] || fallar "Falta SHA256SUMS.txt junto al binario; no se puede verificar $SRC_NAME."
# Coincidencia exacta del nombre (columna 2; admite el prefijo '*' de modo binario).
EXPECTED=$(awk -v n="$SRC_NAME" '$2 == n || $2 == "*" n { print $1; exit }' "$SUMAS")
[ -n "$EXPECTED" ] || fallar "$SRC_NAME no figura en SHA256SUMS.txt."
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$SRC" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL=$(shasum -a 256 "$SRC" | awk '{print $1}')
else
    fallar "No se encontró sha256sum ni shasum para verificar $SRC_NAME."
fi
[ "$ACTUAL" = "$EXPECTED" ] || fallar "El hash SHA-256 de $SRC_NAME no coincide: no se instala."
paso "SHA-256 verificado ${GRIS}$(printf '%s' "$ACTUAL" | cut -c1-12)${FIN}"

# 3. Instalación.
mkdir -p "$DEST"
cp "$SRC" "$DEST/alma"
chmod +x "$DEST/alma"
paso "Instalado en $DEST/alma"

INSTALADA="$("$DEST/alma" version 2>&1)" || fallar "Alma se instaló en $DEST/alma pero no pudo ejecutarse en este sistema: $INSTALADA
     Comunícalo en https://github.com/$REPOSITORIO/issues indicando: $PLATAFORMA, $(uname -r)"
printf '\n  %s%s¡Listo!%s %s está instalado.\n\n' "$NEGRITA" "$AMBAR" "$FIN" "$INSTALADA"
case ":$PATH:" in
    *":$DEST:"*) : ;;
    *)
        printf '  %sFalta un paso:%s %s no está en tu PATH. Agrega a ~/.profile o ~/.bashrc:\n' "$AMBAR" "$FIN" "$DEST"
        printf '    %sexport PATH="$HOME/.local/bin:$PATH"%s\n\n' "$VIOLETA" "$FIN"
        ;;
esac
printf '  Prueba:      %salma ejecutar hola.alma%s\n' "$VIOLETA" "$FIN"
printf '  Actualizar:  %salma actualizar%s\n' "$VIOLETA" "$FIN"
printf '  Aprende:     https://github.com/%s\n\n' "$REPOSITORIO"
