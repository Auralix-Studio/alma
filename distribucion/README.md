# Instalar Alma

El CLI de Alma es un **binario autocontenido**: no necesitás instalar Zig ni ninguna
dependencia. Estos scripts lo copian a una carpeta de tu usuario y lo dejan en el `PATH`.

## 1. Descargá el binario para tu sistema
- **Windows x64:** `alma-windows-x64.exe`
- **Linux x64:** `alma-linux-x64`

## 2. Validá la integridad (opcional pero recomendado)
Compará el checksum contra [`SHA256SUMS.txt`](SHA256SUMS.txt):
- Windows: `Get-FileHash alma-windows-x64.exe -Algorithm SHA256`
- Linux: `sha256sum -c SHA256SUMS.txt`

## 3. Instalá
Poné el binario **en la misma carpeta** que el script de instalación y ejecutá:

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
