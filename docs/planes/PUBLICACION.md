# Publicación de Alma: CLI, extensión de editor y marca

Fecha: 2026-10-03, actualizado 2026-10-04. Estado: **decisiones tomadas (§5);
pasos 1–3 de la §6 implementados**, pendiente la primera versión. Objetivo: que cualquiera pueda instalar `alma` y usar `alma ejecutar`
con un comando, ver los archivos `.alma` coloreados y con su icono en el editor, y
reconocer la marca. Es el requisito previo de la
[app de aprendizaje](APP-APRENDIZAJE.md).

## 1. Situación actual (verificada)

- Repositorio público: `github.com/Auralix-Studio/alma`. **No hay ninguna versión
  publicada** (sin GitHub Releases).
- Instaladores en `distribucion/`: verifican SHA-256, pero esperan el binario en
  la misma carpeta (no descargan nada).
- Extensión en `editores/vscode-alma/`: gramática de colores, sin publicar, sin
  icono, sin licencia ni repositorio en `package.json`. La gramática no colorea
  `lanzar` ni los módulos `matematicas`, `cadena`, `sistema`, `json`, `red`.
- No existe logo ni paleta de marca.

## 2. CLI `alma`: dónde y cómo publicar

### 2.1 Canal principal: GitHub Releases (propuesto)

Un flujo `release.yml` que se dispara al crear una etiqueta `vX.Y.Z`:

1. Corre las pruebas (igual que `ci.yml`).
2. Compila con Zig 0.16 desde un solo runner, `-Doptimize=ReleaseSafe`, para:
   | Archivo | Plataforma |
   |---|---|
   | `alma-windows-x64.exe` | Windows 10/11 x64 |
   | `alma-linux-x64` | Linux x64 (estático, musl) |
   | `alma-linux-arm64` | Linux ARM64 (Raspberry Pi, servidores ARM) |
   | `alma-macos-x64` | macOS Intel |
   | `alma-macos-arm64` | macOS Apple Silicon |
3. Genera `SHA256SUMS.txt` con `distribucion/generar-sumas.sh`.
4. Compila dos veces y compara byte a byte (build reproducible).
5. Publica la versión con los binarios, `SHA256SUMS.txt`, los instaladores y
   el `.vsix` de la extensión.

### 2.2 Instalación en un comando

Los instaladores pasan a descargar la última versión y verificar el hash antes de
instalar (el modo actual, con el binario al lado, se conserva para uso sin red):

```powershell
# Windows (PowerShell)
irm https://github.com/Auralix-Studio/alma/releases/latest/download/instalar.ps1 | iex
```

```sh
# Linux / macOS
curl -fsSL https://github.com/Auralix-Studio/alma/releases/latest/download/instalar.sh | sh
```

Después:

```
alma version
alma ejecutar hola.alma
```

`alma compilar --backend=propio` (Windows x64) no necesita nada más;
`alma compilar` con el backend C sigue necesitando Zig instalado. Esto se dirá
en la página de instalación.

### 2.3 Gestores de paquetes (fase siguiente)

| Gestor | Sistema | Qué hace falta | Prioridad |
|---|---|---|---|
| winget | Windows | Manifiesto enviado por PR a `microsoft/winget-pkgs` | Alta |
| Scoop | Windows | Repositorio `scoop-bucket` propio | Media |
| Homebrew | macOS/Linux | Repositorio `homebrew-tap` propio | Alta |
| AUR | Arch Linux | Paquete `alma-bin` | Baja |

Todos apuntan a los binarios de GitHub Releases: no hay que alojar nada aparte.

### 2.4 Firma de código

Sin firma, Windows SmartScreen avisa al ejecutar un `.exe` descargado desde el
navegador, y macOS Gatekeeper bloquea binarios descargados con el navegador (no
con `curl`). Firmar requiere un certificado de firma de código (Windows) y una
cuenta de Apple Developer (macOS), ambos de pago. Se propone publicar sin firma al
principio, con instalación por `irm`/`curl`, y firmar antes de difundir la app.

### 2.5 Sitio web

Una página en GitHub Pages (`auralix-studio.github.io/alma` o dominio propio) con
la instalación, el tutorial, la documentación de `docs/` y, más adelante, un
«Probar en el navegador» con `alma.wasm` (la misma pieza que necesita la app).

## 3. Extensión «Alma» para editores

### 3.1 Dónde publicar

| Tienda | Editores que la usan | Requisito |
|---|---|---|
| Visual Studio Marketplace | VS Code | Editor `auralix` creado con una cuenta de Microsoft (Azure DevOps) y un token |
| Open VSX | VSCodium, Cursor, Windsurf, Gitpod, Theia | Cuenta en open-vsx.org (con GitHub) y un token |
| GitHub Releases | Instalación manual (`.vsix`) | Ninguno |

Publicar en ambas tiendas desde el mismo flujo (`vsce` y `ovsx`), con los tokens
guardados como secretos del repositorio.

### 3.2 Contenido de la versión 0.2

- **Colores:** gramática corregida (`lanzar`, módulos estándar, `texto`,
  `error`).
- **Icono de la extensión** (PNG 128×128) e **icono de archivo** para `.alma`
  (`contributes.languages[].icon`). Se ve con los temas de iconos que usan iconos
  de lenguaje; Seti y otros temas pueden imponer el suyo.
- **Fragmentos:** `funcion`, `principal`, `si`, `mientras`, `para`, `modelo`,
  `estructura`, `intentar`.
- **Comando «Alma: ejecutar archivo»** (botón ▶ en la barra del editor): abre una
  terminal con `alma ejecutar "<archivo>"`. Avisa si `alma` no está instalado y
  enlaza la instalación.
- **Errores en el editor:** un *problem matcher* para
  `archivo:línea:columna: mensaje`, que es el formato que ya imprime `alma`.
- Licencia, repositorio, `CHANGELOG.md` y `.vscodeignore`.
- **Temas de color propios** («Alma Oscuro» y «Alma Claro») con la paleta de la
  marca: opcionales; los colores de la gramática ya funcionan con cualquier tema.

Después (fuera de la 0.2): servidor de lenguaje `alma lsp` para autocompletado y
errores en vivo, que hoy no existe.

## 4. Marca

### 4.1 Logo

Tres conceptos propuestos (mostrados en la conversación del 2026-10-03):

| Concepto | Idea | Paleta |
|---|---|---|
| A · Llama | «Alma» como llama interior | Violeta `#6D4AFF`, ámbar `#FFB547`, tinta `#16131F` |
| B · Monograma «a» | Letra «a» con chispa en un cuadrado redondeado | Verde azulado `#0E8F7E`, amarillo `#FFD166`, tinta `#0B1F1C` |
| C · Corchetes con alma | `‹ ›` de código con un corazón | Coral `#E2504C`, tinta `#2E2A3D`, lavanda `#F4F1FF` |

Requisitos del logo elegido: legible a 16 px (icono de archivo), versiones para
fondo claro y oscuro, monocromo, y archivos SVG y PNG (16, 32, 128, 256, 512,
1024) en `marca/` en la raíz del repositorio. Los conceptos son bocetos: el
diseño final conviene encargarlo o refinarlo con un diseñador.

### 4.2 Uso

La misma marca se usa en el icono de la extensión, el icono de archivo `.alma`,
el sitio, el README y la app de aprendizaje.

## 5. Decisiones tomadas (2026-10-03)

1. **Logo:** concepto A, llama (`marca/`).
2. **Plataformas de la primera versión:** Windows x64 y Linux x64. macOS y ARM
   quedan para después; los instaladores lo indican.
3. **Tiendas de la extensión:** VS Code Marketplace y Open VSX. Requiere crear
   el editor `auralix` en ambas y guardar los tokens como secretos `VSCE_PAT` y
   `OVSX_PAT` del repositorio (con tus cuentas).
4. **Firma de código:** sin firma al principio.
5. **Primera versión:** `v0.1.0`, precedida de `v0.1.0-rc.1` para probar el flujo.

## 6. Orden de trabajo

1. **Hecho:** `.github/workflows/release.yml` (pruebas, binarios reproducibles,
   sumas, prueba de instaladores en Windows y Linux, GitHub Releases, tiendas) e
   instaladores en modo descarga. Falta ejecutarlo con `v0.1.0-rc.1`.
2. **Hecho:** extensión 0.2 (gramática, icono, fragmentos, comando de
   ejecución, problem matcher); `vsce package` la empaqueta sin avisos.
3. **Hecho:** logo, paleta e iconos en `marca/`, en la extensión y el README.
4. Página de instalación en GitHub Pages.
5. Gestores de paquetes (winget, Homebrew).
6. Luego, fase 0 de la app de aprendizaje: `alma.wasm`.
