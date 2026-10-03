# Instalar Alma

El CLI de Alma es un **binario autocontenido**: no necesitás instalar Zig ni ninguna
dependencia para ejecutar programas interpretados. `alma compilar --backend=c` requiere Zig en el PATH. El backend experimental propio (`alma compilar archivo.alma --backend=propio`) produce ejecutables Windows x64 sin compilador externo; consulta sus límites en [la especificación](../docs/especificacion/07-ir-y-backend-propio.md). Estos scripts lo copian a una carpeta de tu usuario y lo dejan en el `PATH`.

## 1. Descargá el binario y `SHA256SUMS.txt` de la misma versión
- **Windows x64:** `alma-windows-x64.exe`
- **Linux x64:** `alma-linux-x64`
- **`SHA256SUMS.txt`** publicado junto a esos binarios.

`SHA256SUMS.txt` no se versiona en el repositorio: cada versión lo genera con
`sh generar-sumas.sh <carpeta-con-binarios>` y lo publica con sus binarios.
Si compilaste Alma vos mismo (`zig build -Doptimize=ReleaseSafe`), generalo con
ese script sobre tu binario antes de instalar.

## 2. Verificación de integridad (obligatoria)
Los instaladores **abortan** si falta `SHA256SUMS.txt`, si el binario no figura
en él con su nombre exacto, si no hay herramienta de hash (`sha256sum`/`shasum`)
o si el hash no coincide. También podés verificarlo a mano:
- Windows: `Get-FileHash alma-windows-x64.exe -Algorithm SHA256`
- Linux: `sha256sum -c SHA256SUMS.txt`

## 3. Instalá
Poné el binario y `SHA256SUMS.txt` **en la misma carpeta** que el script de
instalación y ejecutá:

**Windows** (PowerShell):
```powershell
powershell -ExecutionPolicy Bypass -File .\instalar.ps1
```
Instala en `%LOCALAPPDATA%\Programs\Alma\alma.exe` y lo agrega al `PATH` del usuario.

**Linux / macOS:**
```sh
sh instalar.sh
```
Instala en `~/.local/bin/alma`.

Abrí una terminal **nueva** y probá:
```
alma version
```

## Desinstalar
- **Windows:** `powershell -ExecutionPolicy Bypass -File .\desinstalar.ps1`
- **Linux / macOS:** `sh desinstalar.sh`

Como Alma es un único archivo, desinstalar solo borra ese binario y lo quita del `PATH`.
No toca el registro ni deja archivos regados.
