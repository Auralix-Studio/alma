# Autohospedaje de Alma — plan

Fecha: 2026-10-03. Solo planificación (nivel 3 de independencia); nada de esto
está implementado.

## Objetivo

El compilador de Alma está escrito en Alma y se compila a sí mismo con el
backend propio. Zig queda únicamente como **compilador semilla**: construye la
primera versión y permite reconstruir todo desde el código fuente.

## Requisitos previos del lenguaje

El compilador actual (lexer, parser, analizador, IR, emisor PE) necesita, y hoy
Alma no tiene o no compila de forma nativa:

| Requisito | Estado | Motivo |
|---|---|---|
| Textos dinámicos, concatenación, `texto()` | Intérprete sí; backend propio no | Diagnósticos, nombres, generación de código |
| Listas y diccionarios | Intérprete sí; backend propio no | Tokens, AST, tablas de símbolos |
| `estructura`/`modelo` | Intérprete sí; backend propio no | Nodos del AST e instrucciones IR |
| Errores (`intentar/lanzar`) | Intérprete sí; backend propio no | Diagnósticos con recuperación |
| Acceso a bytes de un texto y textos binarios | **No existe** | El lexer recorre bytes UTF-8; el emisor produce bytes arbitrarios |
| Operadores de bits (`&`, `|`, `^`, `<<`, `>>`) | **No existe** (`&` y `|` sueltos son inválidos en el lexer) | Codificar instrucciones x86 y cabeceras PE/ELF |
| Enteros sin signo o aritmética modular explícita | **No existe** | Desplazamientos de 32 bits, máscaras |
| Lectura/escritura de archivos binarios | `sistema` solo en el intérprete, y como texto | Leer fuentes y escribir ejecutables |
| Argumentos de línea de comandos | **No existe** | `alma compilar <archivo>` |

Cada requisito nuevo del lenguaje necesita propuesta y aprobación (regla de
especificación) y casos en `pruebas-diferenciales/`.

## Requisitos previos del backend

Etapas D2b–D2g de la [hoja de ruta](HOJA-DE-RUTA.md) completas en Windows, y D3
(ELF) si se quiere autohospedaje en Linux. Rendimiento suficiente: compilar el
compilador (estimado del orden de 10⁴ líneas de Alma) en un tiempo razonable con
el GC del runtime nativo.

## Procedimiento de bootstrap

1. **Etapa 0 (semilla):** `alma0` = compilador actual construido con Zig 0.16
   (`zig build -Doptimize=ReleaseSafe`).
2. **Etapa 1:** con `alma0`, compilar las fuentes del compilador escrito en Alma
   (`compilador-alma/`) con `--backend=propio` → `alma1`. `alma1` está generado
   por el código de Zig.
3. **Etapa 2:** con `alma1`, compilar las mismas fuentes → `alma2`. `alma2` es el
   primer compilador generado por el compilador en Alma.
4. **Etapa 3:** con `alma2`, compilar de nuevo → `alma3`.
5. **Punto fijo:** exigir `alma2` == `alma3` byte a byte. Si difieren, el
   compilador no es determinista o depende de algo del compilador que lo generó.
6. **Validación:** `alma2` debe pasar la batería diferencial completa y las
   pruebas del backend propio sin Zig en `PATH`.

## Artefactos reproducibles

- El backend propio ya es determinista (sin marcas de tiempo, orden estable de
  literales y funciones); mantenerlo como invariante con una prueba que compile
  dos veces y compare.
- Publicar con cada versión: fuentes, `alma2`, su SHA-256 y el SHA-256 de `alma0`
  usado. Cualquiera puede repetir 1–5 y obtener los mismos hashes.
- Mitigación opcional de «trusting trust»: compilación diversa doble (repetir el
  bootstrap desde dos semillas distintas, p. ej. `alma0` construido con Zig en
  dos plataformas, y comparar `alma2`).

## Transición

- Mientras ambos compiladores coexistan, la batería diferencial compara también
  `alma0` contra `alma2` sobre cada caso.
- El intérprete en Zig puede mantenerse como herramienta de desarrollo o
  reescribirse en Alma; no es necesario para el nivel 3 si `ejecutar` pasa a ser
  «compilar y ejecutar» con el backend propio.
- El código Zig se conserva solo como semilla y debe poder compilar la versión
  en Alma de la misma línea de versiones.
