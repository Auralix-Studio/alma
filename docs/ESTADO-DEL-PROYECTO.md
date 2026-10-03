# Estado del proyecto Alma — documento de traspaso

> Snapshot histórico de julio de 2026. Para los cambios del 2 de octubre y la dirección
> vigente, consultar [PLAN-INDEPENDENCIA.md](PLAN-INDEPENDENCIA.md). Las rutas,
> cantidades de pruebas y propuestas de backend siguientes pueden estar desactualizadas.

Snapshot completo para retomar el trabajo en cualquier sesión nueva. **Todo el código,
docs y binarios están en disco** bajo `C:\Users\aless\Desktop\Alma-Codex`.

Última actualización: 2026-07-28.

---

## Qué es Alma
Lenguaje de programación de propósito general **en español** (ecosistema Auralix).
Sintaxis con bloques por indentación cerrados con `fin`, sin `;`. Diferenciador:
`estructura` = tipo por **valor** (se copia) vs `modelo` = tipo por **referencia** (se comparte).
Hoy se ejecuta con un **intérprete tree-walking** (`alma ejecutar`); el compilador nativo
está en curso. El compilador de Alma está escrito en **Zig 0.16**.

---

## Toolchain (CRÍTICO para poder compilar)
- **Zig 0.16.0**, instalado por winget. **NO está en el PATH** de los shells.
  Anteponer el shim antes de cualquier comando `zig`:
  ```powershell
  $env:PATH = "C:\Users\aless\AppData\Local\Microsoft\WinGet\Links;" + $env:PATH
  ```
- Compilar/testear (desde `compilador/`):
  ```
  zig build test        # ≈80 tests, todos en verde
  zig build             # produce compilador/zig-out/bin/alma.exe
  zig build run -- ejecutar ../ejemplos/factorial.alma
  ```
- Binarios de release (autocontenidos, sin dependencias):
  ```
  zig build -Dtarget=x86_64-windows    -Doptimize=ReleaseSafe   # alma.exe
  zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe   # alma (estático)
  ```
- `alma` instalado del usuario: `%LOCALAPPDATA%\Programs\Alma\alma.exe` (en el PATH del usuario).
  Reinstalar copiando el `.exe` nuevo ahí.
- Gotchas de la API 0.16 ya resueltos en el código: `addExecutable` usa
  `.root_module = b.createModule(...)`; `ArrayListUnmanaged` se inicia con `.empty`;
  `DebugAllocator` (no GeneralPurposeAllocator); todo el I/O va por `std.Io`
  (`main(init: std.process.Init.Minimal)` → `std.Io.Threaded` → `io`); diccionarios con
  `std.StringArrayHashMapUnmanaged` (orden de inserción).

---

## Estructura del repo
```
Alma-Codex/
├── README.md                     # cara del proyecto
├── compilador/                   # compilador + CLI (Zig)
│   ├── build.zig, build.zig.zon
│   └── src/
│       ├── main.zig              # CLI `alma`
│       ├── modulos.zig           # carga multi-archivo (importar … desde)
│       ├── paquete.zig           # manifiesto alma.paquete
│       ├── codegen_c.zig         # transpilador a C (para `alma compilar`) *(ver abajo)*
│       ├── pruebas.zig           # raíz de tests
│       ├── lexico/               # token.zig, lexer.zig
│       ├── sintaxis/             # ast.zig (con Pos), parser.zig
│       ├── semantica/            # analizador.zig (nombres + tipos)
│       └── ejecucion/            # interprete.zig (+ librería estándar)
├── docs/
│   ├── ESTADO-DEL-PROYECTO.md    # este archivo
│   ├── tutorial-alma-en-5-minutos.md
│   └── especificacion/           # 01 léxico · 02 gramática · 03 semántica · 04 módulos/paquetes · 05 stdlib
├── editores/vscode-alma/         # extensión de VS Code (instalada en ~/.vscode/extensions)
├── distribucion/                 # instaladores Win/Linux + SHA256SUMS
└── ejemplos/                     # *.alma
```

---

## Qué está IMPLEMENTADO (todo funciona)
- **Lexer** — off-side rule + `fin`, identificadores Unicode (ñ/acentos).
- **Parser + AST** — precedencia completa, todas las sentencias, posiciones (`ast.Pos`).
- **Análisis semántico** (`alma analizar`) — nombres no definidos, aridad, contexto de
  `retornar`/`romper`, constantes, redefiniciones, duplicados, **y chequeo de tipos gradual**
  (solo donde hay anotaciones → cero falsos positivos). Diagnósticos `archivo:línea:columna`.
- **Intérprete** — variables, aritmética entero/decimal, texto (+concat), lógicos con
  cortocircuito, comparaciones, `si/sino si/sino`, `mientras`, `para`, funciones + recursión,
  **listas**, **diccionarios**, **estructura/modelo** (valor vs referencia) con **métodos** y
  `yo`, **errores** (`intentar/capturar/lanzar`), **async** (`asincrona/esperar/hilo`,
  cooperativo), entry point `principal()`.
- **Librería estándar** (módulos con namespace, `importar X` real):
  `matematicas` (raiz, potencia, absoluto, piso, techo, redondear, minimo, maximo, aleatorio, PI, E),
  `cadena` (dividir, unir, reemplazar, mayusculas, minusculas, contiene, recortar, empieza_con, termina_con),
  `sistema` (leer_archivo, escribir_archivo, existe, salir),
  `json` (analizar, serializar),
  `red` (obtener, publicar — HTTP/HTTPS real con TLS; aceptan `cabeceras` opcional = diccionario).
  Globales: imprimir, rango, longitud, agregar, texto, claves, tiene, error.
- **Módulos multi-archivo** — `importar SIMBOLO desde "ruta"` (enlazado por `modulos.zig`).
- **Paquetes** — `alma.paquete` + `alma paquete validar|info`; `alma nuevo` crea el manifiesto.
- **CLI**: `nuevo`, `ejecutar`, `analizar`, `paquete`, `tokens`, `ast`, `version`, `ayuda`.
- **Extensión VS Code** (resaltado), **instaladores**, **binarios release**.

## EN CURSO / próximo paso inmediato
- **`alma compilar` (compilador nativo)**: `compilador/src/codegen_c.zig` **ya está escrito
  y con test unitario que pasa** (transpila un subconjunto de Alma a C). **FALTA conectarlo
  en `main.zig`**: agregar el comando `alma compilar <archivo> [-o salida]` que llame a
  `codegen_c.generar(gpa, programa)`, escriba el `.c`, e invoque `zig cc <archivo>.c -o <salida>`
  vía `std.process.run(gpa, io, .{ .argv = … })`. Subconjunto compilable: funciones, aritmética,
  texto, lógica, `si/mientras`, `imprimir`, `texto()`. No compila aún: listas, diccionarios,
  estructura/modelo, `para`, módulos/stdlib, async, try/catch (para eso, `alma ejecutar`).

## Roadmap después
1. Terminar `alma compilar` (paso de arriba).
2. Más lenguaje: métodos en `estructura`, funciones anónimas/closures, `coincidir` (match),
   interpolación de texto, reemplazar el UA por defecto en `red`.
3. Tooling: `alma lsp` (autocompletado en vivo), `alma formatear`, `alma probar`.
4. Más stdlib: `tiempo`, argumentos de CLI, variables de entorno.
5. Backend LLVM real (a largo plazo).

---

## Cómo se prueba/usa
- Tests: `zig build test` (desde `compilador/`, con el shim en el PATH).
- Ejecutar: `alma ejecutar programa.alma` · Analizar: `alma analizar programa.alma`.
- Ejemplos destacados: `factorial.alma`, `tipos.alma` (valor vs referencia), `red.alma`
  (API JSON real), `tiktok.alma` (réplica del descargador TS), `proyecto-modular/` (multi-archivo).

## Convenciones de trabajo (del usuario, Alessandro)
- Respetar SIEMPRE la sintaxis de Alma (`.alma`, `fin`, indentación, `modelo` vs `estructura`,
  español, sin `;`).
- Preguntar antes de asumir detalles técnicos faltantes; documentar en Markdown al avanzar.
- Ver también la memoria persistente: `alma-language-spec.md`, `alma-work-conventions.md`,
  `alma-estado-actual.md`.
