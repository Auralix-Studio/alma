# Compilador de Alma

Front-end del compilador del lenguaje **Alma** (ecosistema Auralix).

**Estado:** Etapas 1–3 + **CLI `alma`** → Lexer · Parser (AST) · Intérprete (tree-walking).
`alma ejecutar archivo.alma` corre programas de verdad: funciones, listas y diccionarios + `para`,
`estructura` (valor) vs `modelo` (referencia) con **métodos**, **manejo de errores** (`intentar`/`capturar`/`lanzar`),
**async** (`asincrona`/`esperar`/`hilo`), **análisis semántico** (`alma analizar`) y
**módulos multi-archivo** + paquetes. Léxico híbrido (indentación + `fin`). Pruebas unitarias con `zig build test` y pruebas del CLI con `./pruebas-cli.ps1`.

## Requisitos
- **Zig 0.16.x**. Descarga: <https://ziglang.org/download/>

## Estructura
```
compilador/
├── build.zig
├── build.zig.zon
└── src/
    ├── main.zig              # CLI `alma` (nuevo/ejecutar/analizar/paquete/…)
    ├── modulos.zig           # carga y enlazado multi-archivo (importar … desde)
    ├── paquete.zig           # manifiesto alma.paquete
    ├── pruebas.zig           # raíz que agrega todos los tests
    ├── lexico/
    │   ├── token.zig         # TipoToken, Token, tabla de palabras clave
    │   └── lexer.zig         # Lexer (pull) + pila de indentación
    ├── sintaxis/
    │   ├── ast.zig           # nodos del AST + serializador a S-expresión
    │   └── parser.zig        # parser recursivo-descendente con precedencia
    ├── semantica/
    │   └── analizador.zig    # análisis semántico / linter (alma analizar)
    └── ejecucion/
        └── interprete.zig    # intérprete tree-walking (valores, entornos, imprimir)
```

## Comandos
Correr todos los tests (lexer + parser + intérprete):
```
zig build test
```

Compilar el binario `alma` (queda en `zig-out/bin/alma`):
```
zig build
```

Ejecutar un programa Alma (vía `zig build run`, con `--` para pasar argumentos):
```
zig build run -- ejecutar ../ejemplos/factorial.alma
```

### CLI `alma`
```
alma nuevo    <nombre>         Crea un proyecto nuevo (con alma.paquete).
alma ejecutar <archivo.alma>   Compila al vuelo y ejecuta.
alma analizar <archivo.alma>   Revisa el código en busca de errores (linter).
alma paquete  <validar|info>   Valida el manifiesto alma.paquete.
alma tokens   <archivo.alma>   Muestra el flujo de tokens (desarrollo).
alma ast      <archivo.alma>   Muestra el AST (desarrollo).
alma version                   Versión.
alma ayuda                     Ayuda.
```
Los diagnósticos incluyen `archivo:línea:columna`.
Pendientes (oficiales): `formatear`, `probar`, `doc`, `lsp`.

## Contrato
- Léxico: [`docs/especificacion/01-lexico-y-tokens.md`](../docs/especificacion/01-lexico-y-tokens.md)
- Gramática: [`docs/especificacion/02-gramatica.md`](../docs/especificacion/02-gramatica.md)

## Desarrollo hacia la independencia

El plan vigente está en [PLAN-INDEPENDENCIA.md](../docs/PLAN-INDEPENDENCIA.md).
La compilación nativa carga módulos Alma y valida el programa antes de generar C.
El backend C requiere Zig; el backend propio experimental Windows x64 se selecciona con --backend=propio y no invoca herramientas externas. El autohospedaje sigue pendiente.
