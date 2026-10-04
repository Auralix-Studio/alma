# Alma para VS Code

Resaltado de sintaxis para el lenguaje **Alma** (ecosistema Auralix): colorea archivos
`.alma` mediante una gramática TextMate.

## Qué resalta
- Comentarios `//`, `///` (doc) y `//!` (doc de módulo).
- Cadenas de texto con secuencias de escape.
- Números enteros y decimales (con `_` y exponente).
- Palabras clave: `funcion`, `si`/`sino`/`para`/`mientras`/`fin`, `estructura`/`modelo`,
  `importar`/`exportar`/`desde`, `retornar`/`romper`/`continuar`, `asincrona`/`esperar`/`hilo`,
  `intentar`/`capturar`, `fijo`, `externa`.
- Constantes: `verdadero`, `falso`, `nulo`, y `yo` (self).
- Tipos primitivos: `entero`, `decimal`, `texto`, `logico`, `diccionario`, `lista`.
- Funciones de la librería estándar: `imprimir`, `rango`, `longitud`, `agregar`, `claves`, `tiene`.
- Nombres de función/tipo en sus declaraciones, llamadas, y operadores.

## Probar la extensión

**Modo desarrollo (recomendado):**
1. Abre la carpeta `editores/vscode-alma` en VS Code.
2. Presiona `F5` para lanzar un *Extension Development Host*.
3. En la nueva ventana, abre cualquier archivo `.alma` (p. ej. `ejemplos/basicos/factorial.alma`).

**Instalación manual:**
Copia esta carpeta a tu directorio de extensiones de VS Code y recarga:
- Windows: `%USERPROFILE%\.vscode\extensions\alma-lang-0.1.0`
- macOS/Linux: `~/.vscode/extensions/alma-lang-0.1.0`

## Estado
`v0.1` — solo resaltado (gramática TextMate). El autocompletado, errores en vivo y
*go-to-definition* llegarán con el servidor LSP (`alma lsp`).
