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
irm https://raw.githubusercontent.com/Auralix-Studio/alma/main/distribucion/instalar.ps1 | iex
```

Instala en `%LOCALAPPDATA%\Programs\Alma\alma.exe` y lo agrega al `PATH` del usuario.

**Linux:**

```sh
curl -fsSL https://raw.githubusercontent.com/Auralix-Studio/alma/main/distribucion/instalar.sh | sh
```

Instala en `~/.local/bin/alma`.

Después, en una terminal nueva:

```
alma version
alma ejecutar hola.alma
```

### Una versión concreta

```powershell
$env:ALMA_VERSION = "v0.1.0"; irm https://raw.githubusercontent.com/Auralix-Studio/alma/v0.1.0/distribucion/instalar.ps1 | iex
```

```sh
curl -fsSL https://raw.githubusercontent.com/Auralix-Studio/alma/v0.1.0/distribucion/instalar.sh | ALMA_VERSION=v0.1.0 sh
```

El script de instalación se sirve desde el repositorio (`raw.githubusercontent.com`,
como texto UTF-8): GitHub Releases lo entrega como binario y PowerShell 5.1 lo
leería como Latin-1, corrompiendo acentos y símbolos. El script, a su vez,
descarga el binario y las sumas de GitHub Releases.

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

## Actualizar

```
alma actualizar               # instala la última versión estable si es más nueva
alma actualizar --comprobar   # solo dice si hay una versión nueva
alma actualizar --version=v0.1.0-rc.1   # una versión concreta, también de prueba
```

Descarga de GitHub Releases el binario de tu plataforma y el `SHA256SUMS.txt` de
esa versión, verifica el SHA-256 y solo entonces reemplaza el ejecutable. En
Windows el ejecutable anterior queda como `alma.exe.anterior` (se borra en la
siguiente actualización). Volver a ejecutar el comando de instalación también
actualiza.

## Desinstalar

- **Windows:** `powershell -ExecutionPolicy Bypass -File .\desinstalar.ps1`
- **Linux:** `sh desinstalar.sh`

Alma es un único archivo: desinstalar borra ese binario y lo quita del `PATH`.

## Cómo se publica una versión (mantenedores)

La publicación es automática y la hace `.github/workflows/release.yml`:

- **Versión estable:** sube `VERSION` en `compilador/src/main.zig` (por ejemplo
  a `0.2.0`) y fusiona en `main`. Si `v0.2.0` todavía no está publicada, el
  flujo la crea; si ya existe, no hace nada.
- **Versión de prueba:** sube una etiqueta con sufijo, por ejemplo
  `git tag v0.2.0-rc.1 && git push origin v0.2.0-rc.1`. Se marca como
  *prerelease*: `alma actualizar` no la instala salvo con `--version`, y no
  publica la extensión en las tiendas.
- También se puede lanzar a mano desde la pestaña *Actions* («Publicar versión»).

En cada publicación el flujo:

1. corre las pruebas;
2. compila Windows x64 y Linux x64 dos veces desde cachés vacías y exige que
   los binarios sean iguales byte a byte;
3. genera `SHA256SUMS.txt` y empaqueta la extensión;
4. instala con `instalar.ps1`/`instalar.sh` en Windows y Linux y ejecuta un
   ejemplo;
5. publica la versión en GitHub Releases;
6. publica la extensión en VS Code Marketplace y Open VSX si existen los
   secretos `VSCE_PAT` y `OVSX_PAT` (solo versiones estables).

Si cambió la extensión, sube también la versión de
`editores/vscode-alma/package.json`: las tiendas rechazan volver a publicar el
mismo número.