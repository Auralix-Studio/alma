<p align="center"><img src="marca/png/alma-logo-128.png" width="96" alt="Logo de Alma"></p>

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
escrito en Alma. Zig sigue siendo la herramienta de construcción inicial.
`alma compilar archivo.alma --backend=propio` ya genera ejecutables Windows x64
sin compilador externo para un subconjunto experimental. El backend C, predeterminado,
requiere `zig cc`. Véase el [plan de independencia](docs/planes/PLAN-INDEPENDENCIA.md).

---

## Instalar

**Windows x64** (PowerShell):

```powershell
irm https://raw.githubusercontent.com/Auralix-Studio/alma/main/distribucion/instalar.ps1 | iex
```

**Linux x64 / ARM64, también Android con Termux**:

```sh
curl -fsSL https://raw.githubusercontent.com/Auralix-Studio/alma/main/distribucion/instalar.sh | sh
```

Los instaladores descargan la última versión, verifican su SHA-256 y la instalan
para tu usuario (sin permisos de administrador). Más opciones, instalación sin
conexión y desinstalación: [`distribucion/`](distribucion/README.md). Para colores,
icono y ejecución con un clic en VS Code, instala la extensión **Alma**
([`editores/vscode-alma`](editores/vscode-alma/README.md)).

## Empezar en 30 segundos

```bash
alma nuevo mi-proyecto
cd mi-proyecto
alma ejecutar principal.alma
```

### Compilar Alma desde el código fuente

Requiere **[Zig 0.16](https://ziglang.org/download/)** (el compilador de Alma está escrito en Zig).

```bash
cd compilador
zig build                       # compila el binario `alma` en zig-out/bin/
zig build run -- ejecutar ../ejemplos/basicos/factorial.alma
zig build test                  # pruebas unitarias
zig build diferencial           # intérprete vs backends nativos
```
¿Nuevo en Alma? Leé **[Alma en 5 minutos](docs/guias/tutorial-alma-en-5-minutos.md)**.

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
| **Compilación nativa** | Backend C vía `zig cc` y backend propio experimental Windows x64 con `--backend=propio` |
| **CLI** | `alma nuevo`, `alma ejecutar`, `alma compilar`, `alma analizar`, `alma paquete`, `alma actualizar`, `alma tokens`, `alma ast` |
| **Editor** | Extensión de VS Code con resaltado de sintaxis |

**En camino:** paralelismo real (event loop / hilos nativos), FFI con C (`externa`), y un
backend LLVM directo. Hoy el lenguaje completo corre con un **intérprete tree-walking**
(`alma ejecutar`); `alma compilar` ya genera **binarios nativos** para un subconjunto (vía
`zig cc`). Async se resuelve de forma **cooperativa/síncrona**; el
paralelismo real y la ampliación del backend propio son parte del roadmap.

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
alma actualizar                Instala la última versión publicada (verifica SHA-256).
alma version                   Versión de Alma.
alma ayuda                     Ayuda.
```

Los diagnósticos de `analizar` y `ejecutar` incluyen `archivo:línea:columna`.
`ejecutar` y `compilar` validan el programa antes de procesarlo. Los errores detectados
devuelven código de salida 1. `compilar` carga funciones de otros archivos Alma siempre
que sus definiciones pertenezcan al subconjunto nativo soportado.

Comandos oficiales aún no implementados: `formatear`, `probar`, `doc`, `lsp`.

`alma ir archivo.alma` muestra la representación intermedia en JSON. Consultá
[IR y backend propio](docs/especificacion/07-ir-y-backend-propio.md) para los límites
de cada backend y las pruebas de compilación sin Zig.

---

## Estructura del repositorio

```
alma/
├── compilador/                 Compilador + CLI `alma`, escrito en Zig
│   ├── src/
│   │   ├── main.zig            CLI `alma`
│   │   ├── modulos.zig         Carga multi-archivo (importar … desde)
│   │   ├── paquete.zig         Manifiesto alma.paquete
│   │   ├── numeros.zig         Semántica numérica y escapes compartidos
│   │   ├── ir.zig              Representación intermedia
│   │   ├── emision_c.zig       Backend C (+ runtime/escalar.h)
│   │   ├── codegen_pe.zig      Backend propio Windows x64
│   │   ├── lexico/             Lexer (tokens)
│   │   ├── sintaxis/           Parser + AST
│   │   ├── semantica/          Analizador (alma analizar)
│   │   └── ejecucion/          Intérprete tree-walking + GC
│   └── pruebas/
│       ├── diferenciales/      Intérprete vs C vs propio (`zig build diferencial`)
│       └── *.ps1               Suites CLI, límites, módulos, compilación, propio
├── docs/                       Ver docs/README.md
│   ├── especificacion/         Léxico, gramática, semántica, módulos, stdlib, backends
│   ├── guias/                  Tutorial
│   ├── planes/                 Independencia, hoja de ruta, autohospedaje, productos
│   ├── propuestas/             Decisiones de diseño (aprobadas o pendientes)
│   └── informes/               Auditoría, verificación, estado histórico
├── ejemplos/                   Programas .alma (básicos, stdlib, modular, aplicaciones)
├── distribucion/               Instaladores (Windows/Linux) con verificación SHA-256
└── editores/vscode-alma/       Extensión de VS Code (resaltado)
```

Para instalar el binario `alma` en tu sistema, mirá [`distribucion/`](distribucion/README.md).

## Ejemplos

| Archivo | Muestra |
|---|---|
| [`saludo.alma`](ejemplos/basicos/saludo.alma) | Lo mínimo: variables e `imprimir` |
| [`factorial.alma`](ejemplos/basicos/factorial.alma) | Recursión y `mientras` |
| [`tipos.alma`](ejemplos/basicos/tipos.alma) | `estructura` (valor) vs `modelo` (referencia) |
| [`servidor.alma`](ejemplos/basicos/servidor.alma) | `modelo` con métodos |
| [`diccionario.alma`](ejemplos/basicos/diccionario.alma) | Diccionarios y `para` |
| [`errores.alma`](ejemplos/basicos/errores.alma) | `intentar` / `capturar` / `lanzar` |
| [`async.alma`](ejemplos/basicos/async.alma) | `asincrona` / `esperar` / `hilo` |
| [`proyecto-modular/`](ejemplos/proyecto-modular) | Programa en varios archivos (`importar … desde`) |
| [`stdlib.alma`](ejemplos/biblioteca-estandar/stdlib.alma) | Librería estándar: `matematicas`, `cadena`, `sistema`, `json` |
| [`red.alma`](ejemplos/biblioteca-estandar/red.alma) | Llamar a una API JSON real por HTTPS (`red` + `json`) |
| [`descargador-tiktok/`](ejemplos/aplicaciones/descargador-tiktok) | Aplicación completa: `red`, `json`, diccionarios y errores |

## Documentación

- [Tutorial — Alma en 5 minutos](docs/guias/tutorial-alma-en-5-minutos.md)
- [Especificación léxica y tokens](docs/especificacion/01-lexico-y-tokens.md)
- [Gramática (EBNF)](docs/especificacion/02-gramatica.md)
- [Índice de toda la documentación](docs/README.md)
- [El compilador por dentro](compilador/README.md)

---

*Alma · ecosistema Auralix.*
