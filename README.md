# Alma

**Alma** es un lenguaje de programación de propósito general, **en español**, del ecosistema
**Auralix**. Elimina la barrera del inglés sin renunciar a la ingeniería de alto nivel:
tiene un *piso bajo* (sintaxis limpia, fácil para principiantes) y un *techo alto*
(tipos, colecciones, objetos y control de memoria por estructura).

```alma
// Un vistazo a Alma
estructura Vector3D
    x: decimal
    y: decimal
    z: decimal
fin

modelo Contador
    total: entero

    funcion incrementar()
        total = total + 1
    fin
fin

funcion principal()
    a = Vector3D(1.0, 2.0, 3.0)
    b = a            // 'estructura' se COPIA (valor)
    b.x = 99.0
    imprimir(a.x)    // 1.0  — 'a' no cambió

    c = Contador(0)
    c.incrementar()
    c.incrementar()
    imprimir(c.total)  // 2  — 'modelo' se comparte (referencia)
fin
```

> **El diferenciador:** `estructura` define tipos **por valor** (se copian) y `modelo`
> define tipos **por referencia** (se comparten). Hoy el intérprete almacena ambos en
> una arena liberada al finalizar: todavía no hay colocación de estructuras en stack
> ni conteo de referencias. La diferencia observable actual es copia frente a alias.

**Dirección del proyecto:** construir un backend propio y, posteriormente, un compilador
escrito en Alma. Zig sigue siendo la herramienta inicial y `alma compilar` todavía
requiere `zig cc`. Véase el [plan de independencia](docs/PLAN-INDEPENDENCIA.md).

---

## Empezar en 30 segundos

Requiere **[Zig 0.16](https://ziglang.org/download/)** (el compilador de Alma está escrito en Zig).

```bash
cd compilador
zig build                       # compila el binario `alma` en zig-out/bin/
zig build run -- ejecutar ../ejemplos/factorial.alma
```

Con el binario `alma` en el PATH podés arrancar un proyecto:

```bash
alma nuevo mi-proyecto
cd mi-proyecto
alma ejecutar principal.alma
```

O corré la batería de pruebas:

```bash
zig build test                  # pruebas unitarias
```

¿Nuevo en Alma? Leé **[Alma en 5 minutos](docs/tutorial-alma-en-5-minutos.md)**.

---

## Qué puede hacer Alma hoy

| Área | Incluye |
|---|---|
| **Tipos** | `entero`, `decimal`, `texto`, `logico`, `nulo`, `lista`, `diccionario` |
| **Control de flujo** | `si` / `sino si` / `sino`, `mientras`, `para … en …` |
| **Funciones** | parámetros tipados, `retornar`, recursión |
| **Colecciones** | listas `[…]` con indexación; diccionarios `{clave: valor}`; `rango`, `longitud`, `agregar`, `claves`, `tiene` |
| **Objetos** | `estructura` (valor) y `modelo` (referencia), construcción, campos, **métodos** con self implícito y `yo` |
| **Errores** | `intentar` / `capturar (e)` / `lanzar error("…")`, con `e.mensaje` |
| **Concurrencia** | `asincrona` / `esperar` / `hilo` (semántica cooperativa en el intérprete) |
| **Librería estándar** | `matematicas`, `cadena`, `sistema` (archivos), `json`, `red` (HTTP/HTTPS) — con `importar` real |
| **Módulos** | Programas multi-archivo con `importar SIMBOLO desde "ruta"` |
| **Paquetes** | Manifiesto `alma.paquete` + `alma paquete validar` |
| **Análisis** | `alma analizar` detecta errores antes de ejecutar: nombres, aridad, contexto, constantes, y **chequeo de tipos gradual** |
| **Compilación nativa** | `alma compilar` → binario nativo autónomo (subconjunto, vía `zig cc`) |
| **CLI** | `alma nuevo`, `alma ejecutar`, `alma compilar`, `alma analizar`, `alma paquete`, `alma tokens`, `alma ast` |
| **Editor** | Extensión de VS Code con resaltado de sintaxis |

**En camino:** paralelismo real (event loop / hilos nativos), FFI con C (`externa`), y un
backend LLVM directo. Hoy el lenguaje completo corre con un **intérprete tree-walking**
(`alma ejecutar`); `alma compilar` ya genera **binarios nativos** para un subconjunto (vía
`zig cc`). Async se resuelve de forma **cooperativa/síncrona**; el
paralelismo real y un backend nativo propio sin compilador externo son parte del roadmap.

---

## El comando `alma`

```
alma nuevo    <nombre>         Crea un proyecto nuevo (con alma.paquete).
alma ejecutar <archivo.alma>   Compila al vuelo y ejecuta el programa.
alma compilar <archivo.alma>   Genera un binario nativo (subconjunto; requiere zig cc).
alma analizar <archivo.alma>   Revisa el código en busca de errores (linter).
alma paquete  <validar|info>   Valida el manifiesto alma.paquete del proyecto.
alma tokens   <archivo.alma>   Muestra el flujo de tokens (desarrollo).
alma ast      <archivo.alma>   Muestra el árbol de sintaxis (desarrollo).
alma version                   Versión de Alma.
alma ayuda                     Ayuda.
```

Los diagnósticos de `analizar` y `ejecutar` incluyen `archivo:línea:columna`.
`ejecutar` y `compilar` validan el programa antes de procesarlo. Los errores detectados
devuelven código de salida 1. `compilar` carga funciones de otros archivos Alma siempre
que sus definiciones pertenezcan al subconjunto nativo soportado.

Comandos oficiales aún no implementados: `formatear`, `probar`, `doc`, `lsp`.

---

## Estructura del repositorio

```
Alma-Codex/
├── compilador/            Compilador + CLI, escrito en Zig
│   └── src/
│       ├── main.zig       CLI `alma`
│       ├── modulos.zig    Carga multi-archivo (importar … desde)
│       ├── paquete.zig    Manifiesto alma.paquete
│       ├── lexico/        Lexer (tokens)
│       ├── sintaxis/      Parser + AST
│       ├── semantica/     Analizador (alma analizar)
│       └── ejecucion/     Intérprete tree-walking
├── docs/
│   ├── especificacion/    Spec del léxico, la gramática, la semántica y los módulos
│   └── tutorial-alma-en-5-minutos.md
├── distribucion/          Instaladores (Windows/Linux) + checksums
├── editores/vscode-alma/  Extensión de VS Code (resaltado)
└── ejemplos/              Programas .alma de ejemplo
```

Para instalar el binario `alma` en tu sistema, mirá [`distribucion/`](distribucion/README.md).

## Ejemplos

| Archivo | Muestra |
|---|---|
| [`saludo.alma`](ejemplos/saludo.alma) | Lo mínimo: variables e `imprimir` |
| [`factorial.alma`](ejemplos/factorial.alma) | Recursión y `mientras` |
| [`tipos.alma`](ejemplos/tipos.alma) | `estructura` (valor) vs `modelo` (referencia) |
| [`servidor.alma`](ejemplos/servidor.alma) | `modelo` con métodos |
| [`diccionario.alma`](ejemplos/diccionario.alma) | Diccionarios y `para` |
| [`errores.alma`](ejemplos/errores.alma) | `intentar` / `capturar` / `lanzar` |
| [`async.alma`](ejemplos/async.alma) | `asincrona` / `esperar` / `hilo` |
| [`proyecto-modular/`](ejemplos/proyecto-modular) | Programa en varios archivos (`importar … desde`) |
| [`stdlib.alma`](ejemplos/stdlib.alma) | Librería estándar: `matematicas`, `cadena`, `sistema`, `json` |
| [`red.alma`](ejemplos/red.alma) | Llamar a una API JSON real por HTTPS (`red` + `json`) |

## Documentación

- [Tutorial — Alma en 5 minutos](docs/tutorial-alma-en-5-minutos.md)
- [Especificación léxica y tokens](docs/especificacion/01-lexico-y-tokens.md)
- [Gramática (EBNF)](docs/especificacion/02-gramatica.md)
- [El compilador por dentro](compilador/README.md)

---

*Alma · ecosistema Auralix.*
