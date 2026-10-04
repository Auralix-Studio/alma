# Alma — Compilación Nativa

> **Documento:** `06-compilacion-nativa.md`
> **Componente:** Compilador · Backend nativo (`alma compilar`)
> **Estado:** Borrador de trabajo `v0.1` (subconjunto)
> **Fuente de verdad para:** `compilador/src/codegen_c.zig`

Este documento describe el backend C predeterminado. El backend independiente
Windows x64 se selecciona con `--backend=propio` y se documenta en
[IR y backend propio](07-ir-y-backend-propio.md).

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
`alma compilar ejemplos/basicos/factorial.alma` produce un `.exe` nativo que imprime los factoriales;
`saludo.alma` compila la concatenación de texto. Ambos corren sin `alma` ni `zig`.

## Roadmap
Backend propio sin compiladores externos, runtime con gestión de memoria y compilación
de la biblioteca estándar. Después se buscará el autohospedaje. El plan vigente y sus
criterios de aceptación están en [PLAN-INDEPENDENCIA.md](../planes/PLAN-INDEPENDENCIA.md).

## Errores y limitaciones
Los errores detectados devuelven código 1. Si falta Zig se conserva el C generado.
El cargador aísla los nombres por archivo y enlaza únicamente los símbolos
exportados que se solicitan. Los backends nativos rechazan inicializadores
globales y tipos fuera de su subconjunto; el intérprete admite esos módulos.
El runtime C libera textos dinámicos mediante conteo de referencias e instrucciones
de copia/liberación en la IR. Todavía falta unificar completamente otros aspectos
de la semántica con el intérprete, incluido el formato decimal.

### Contrato aritmético del runtime

Las operaciones numéricas y las condiciones validan los tipos en runtime, también
cuando las variables no tienen anotación. `+` concatena solo dos textos; para mezclar
texto con números se requiere `texto(numero)`. `%` requiere dos enteros. Dividir por
cero, entero o decimal, termina con error y código 1.

Los operadores enteros `+`, `-`, `*`, `/` y negación comprueban el rango de `i64`.
El desbordamiento termina con el diagnóstico `desbordamiento de entero`, incluido
el caso mínimo de `i64` dividido por `-1`. El resto de esa misma pareja es cero.
La división entera trunca hacia cero: `-7 / 3` es `-2` y `-7 % 3` es `-1`.

Imprimir un número usa salida directa sin reservar texto. Las conversiones explícitas
y concatenaciones reservan memoria con comprobación de fallo y conteo de referencias.
Los textos dejan de ocupar memoria cuando se libera su última referencia.

### Orden de evaluación

Operandos y argumentos se evalúan de izquierda a derecha. El backend genera
registros de la IR y secuencias explícitas para preservar los efectos de llamadas
anidadas. Los operadores `&&` y `||` solo evalúan el lado derecho cuando corresponde.
Los temporales pertenecen a cada invocación de función, incluida la recursión.
