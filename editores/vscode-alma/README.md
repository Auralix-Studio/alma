# Alma para VS Code

Soporte del lenguaje **Alma** (programación en español, ecosistema Auralix) para
Visual Studio Code y editores compatibles (VSCodium, Cursor, Windsurf).

## Funciones

- **Colores** para archivos `.alma`: palabras clave (`funcion`, `si`, `mientras`,
  `para`, `intentar`, `lanzar`…), textos y escapes, números, comentarios y
  comentarios de documentación, tipos, constantes (`verdadero`, `falso`, `nulo`,
  `yo`), funciones nativas y módulos estándar (`matematicas`, `cadena`, `sistema`,
  `json`, `red`).
- **Icono de archivo** para `.alma` (con los temas de iconos que usan los iconos
  de lenguaje; algunos temas, como Seti, imponen el suyo).
- **Fragmentos:** `principal`, `funcion`, `si`, `sisino`, `mientras`, `para`,
  `estructura`, `modelo`, `intentar`, `importar`.
- **Ejecutar archivo:** botón ▶ en la barra del editor, `Ctrl+F5` o el comando
  «Alma: Ejecutar archivo». Corre `alma ejecutar` y marca los errores
  (`archivo:línea:columna`) en el editor y en el panel de problemas.

## Requisitos

Para ejecutar programas hace falta el CLI `alma` en el `PATH`
([instalación](https://github.com/Auralix-Studio/alma#instalar)) o su ruta en
el ajuste `alma.rutaEjecutable`. Los colores y los fragmentos funcionan sin él.

## Desarrollo

1. Abre la carpeta `editores/vscode-alma` en VS Code.
2. Pulsa `F5` para lanzar un *Extension Development Host*.
3. Abre un archivo `.alma` (p. ej. `ejemplos/basicos/factorial.alma`).

Empaquetar: `npx @vscode/vsce package` (genera `alma-lang-<versión>.vsix`).

## Pendiente

Autocompletado, errores en vivo e ir a la definición llegarán con un servidor de
lenguaje (`alma lsp`), que todavía no existe.
