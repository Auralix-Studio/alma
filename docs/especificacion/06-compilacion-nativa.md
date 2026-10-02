# Alma — Compilación Nativa

> **Documento:** `06-compilacion-nativa.md`
> **Componente:** Compilador · Backend nativo (`alma compilar`)
> **Estado:** Borrador de trabajo `v0.1` (subconjunto)
> **Fuente de verdad para:** `compilador/src/codegen_c.zig`

`alma compilar <archivo.alma>` genera un **binario nativo autónomo** — un ejecutable que
corre por sí solo, sin `alma` ni intérprete.

## Cómo funciona
El backend **transpila Alma a C** y compila ese C a nativo con **`zig cc`** (el compilador
de C que ya trae Zig — sin dependencias externas). Los valores en tiempo de ejecución usan
una estructura `Val` con etiqueta y campos para entero/decimal/lógico/texto/nulo.
Antes de generar C se cargan los módulos Alma y se ejecuta el análisis semántico.

```
alma compilar fact.alma
  → genera fact.c   (código C)
  → invoca zig cc   → fact.exe   (binario nativo)
```

**Requisito:** un compilador de C accesible como `zig cc` (es decir, `zig` en el `PATH`).
Si no está, `alma compilar` deja el `.c` generado e indica cómo compilarlo a mano.

## Subconjunto soportado (v0.1)
- Funciones de nivel superior + recursión; `principal()` como punto de entrada.
- Funciones de módulos `.alma`, cargadas con `importar SIMBOLO desde "ruta"`,
  siempre que todas las definiciones cargadas usen este subconjunto.
- Variables, aritmética (`+ - * / %`), comparaciones, lógicos (`&& || !`, con cortocircuito).
- `entero`, `decimal`, `logico`, `nulo`, `texto` (incluida la concatenación con `+`).
- `si / sino si / sino`, `mientras`.
- `imprimir(...)` y `texto(valor)`.

## No soportado todavía (usá `alma ejecutar`)
Listas, diccionarios, `estructura`/`modelo`, `para`, llamadas a la librería estándar
(`sistema`, `red`, …), acceso a miembros/índices, `intentar`/`lanzar`,
`asincrona`/`hilo`. Al encontrarlos, `alma compilar` avisa con un mensaje claro y sugiere
`alma ejecutar`.

## Verificado
`alma compilar ejemplos/factorial.alma` produce un `.exe` nativo que imprime los factoriales;
`saludo.alma` compila la concatenación de texto. Ambos corren sin `alma` ni `zig`.

## Roadmap
Backend propio sin compiladores externos, runtime con gestión de memoria y compilación
de la biblioteca estándar. Después se buscará el autohospedaje. El plan vigente y sus
criterios de aceptación están en [PLAN-INDEPENDENCIA.md](../PLAN-INDEPENDENCIA.md).

## Errores y limitaciones
Los errores detectados devuelven código 1. Si falta Zig se conserva el C generado.
El cargador actual incorpora todas las definiciones de cada módulo en un espacio de
nombres compartido; aún no proporciona importación selectiva ni aislamiento.
El runtime C todavía necesita liberación de textos dinámicos y unificación completa
de la semántica con el intérprete.
