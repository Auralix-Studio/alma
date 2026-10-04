# Instalar Alma

El CLI `alma` es un **binario autocontenido**: para `alma ejecutar`, `alma nuevo`,
`alma analizar` y `alma compilar --backend=propio` (Windows x64) no hace falta
nada más. `alma compilar` con el backend C (`--backend=c`, el predeterminado)
requiere además [Zig 0.16](https://ziglang.org/download/) en el `PATH`.

Plataformas publicadas: **Windows x64** y **Linux x64** (estático, sin
dependencias). macOS y ARM están previstos más adelante.

## En un comando

**Windows** (PowerShell, sin permisos de administrador):

```powershell
irm https://github.com/Auralix-Studio/alma/releases/latest/download/instalar.ps1 | iex
```

Instala en `%LOCALAPPDATA%\Programs\Alma\alma.exe` y lo agrega al `PATH` del usuario.

**Linux:**

```sh
curl -fsSL https://github.com/Auralix-Studio/alma/releases/latest/download/instalar.sh | sh
```

Instala en `~/.local/bin/alma`.

Después, en una terminal nueva:

```
alma version
alma ejecutar hola.alma
```

### Una versión concreta

```powershell
$env:ALMA_VERSION = "v0.1.0"; irm https://github.com/Auralix-Studio/alma/releases/download/v0.1.0/instalar.ps1 | iex
```

```sh
curl -fsSL https://github.com/Auralix-Studio/alma/releases/download/v0.1.0/instalar.sh | ALMA_VERSION=v0.1.0 sh
```

## Verificación de integridad (siempre)

Los instaladores descargan el binario y `SHA256SUMS.txt` de la misma versión y
**abortan sin instalar** si falta `SHA256SUMS.txt`, si el binario no figura en él
con su nombre exacto, si no hay herramienta de hash o si el hash no coincide.

Los binarios todavía **no están firmados**: al descargarlos con el navegador,
Windows SmartScreen puede mostrar un aviso. La instalación con `irm`/`curl` no
pasa por ese aviso.

## Sin conexión

Descarga de la página de la versión el binario (`alma-windows-x64.exe` o
`alma-linux-x64`), `SHA256SUMS.txt` y el instalador; ponlos en la misma carpeta y
ejecuta:

```powershell
powershell -ExecutionPolicy Bypass -File .\instalar.ps1
```

```sh
sh instalar.sh
```

Si compilaste Alma tú mismo (`zig build -Doptimize=ReleaseSafe`), genera las
sumas de tu binario con `sh generar-sumas.sh <carpeta>` antes de instalar.

## Desinstalar

- **Windows:** `powershell -ExecutionPolicy Bypass -File .\desinstalar.ps1`
- **Linux:** `sh desinstalar.sh`

Alma es un único archivo: desinstalar borra ese binario y lo quita del `PATH`.

## Cómo se publica una versión (mantenedores)

1. Actualiza `VERSION` en `compilador/src/main.zig` (y la versión de
   `editores/vscode-alma/package.json` si cambió la extensión).
2. Crea y sube la etiqueta: `git tag v0.1.0 && git push origin v0.1.0`
   (`v0.1.0-rc.1` para una versión de prueba, que se marca como *prerelease* y no
   publica la extensión en las tiendas).
3. `.github/workflows/release.yml`:
   - corre las pruebas;
   - compila cada binario dos veces desde cachés vacías y exige que sean iguales
     byte a byte;
   - genera `SHA256SUMS.txt`, empaqueta la extensión;
   - prueba los instaladores en Windows y Linux;
   - publica la versión en GitHub Releases.
4. La extensión se publica en VS Code Marketplace y Open VSX si existen los
   secretos `VSCE_PAT` y `OVSX_PAT` en el repositorio.
