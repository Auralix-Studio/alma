# Memoria y runtime del backend propio — decisión pendiente

Fecha: 2026-10-03. Propuesta; **no implementa nada**. Bloquea las etapas D2a–D2g
de la [hoja de ruta](HOJA-DE-RUTA.md): textos dinámicos, colecciones, objetos,
errores y biblioteca estándar en el backend propio.

## Punto de partida (código actual)

- La IR ya tiene un contrato de propiedad: cada registro posee su valor,
  `copiar` retiene, `liberar` suelta y `retornar` limpia el marco (`ir.zig`).
  El backend C lo implementa con conteo de referencias de textos (`escalar.h`).
- El backend propio guarda cada valor en una ranura etiquetada de 16 bytes
  (dato + etiqueta) en el marco de la función; todos los marcos tienen la misma
  forma (`push rbp; mov rbp, rsp; sub rsp, n`) y la ranura de cada registro se
  conoce en tiempo de compilación (`codegen_pe.zig`, `asignarRanuras`).
- Tras cada operación el resultado vuelve a su ranura: entre instrucciones IR no
  queda ningún valor solo en registros de la CPU.
- El intérprete usa marcado y barrido no móvil (decisión (b) de
  [PROPUESTA-MEMORIA.md](PROPUESTA-MEMORIA.md), ya implementada).

## Decisión 1: modelo de memoria

| Opción | Coste de implementación | Riesgos | Encaje |
|---|---|---|---|
| (a) Conteo de referencias (como el runtime C) | Medio: `retener`/`soltar` en `copiar`/`liberar`/`retornar` ya marcados por la IR; liberación recursiva de contenedores | Los ciclos (`agregar(l, l)`, modelos que se apuntan) se pierden; coste en cada copia; liberación recursiva profunda necesita pila explícita | Reutiliza el contrato de la IR y el runtime C como referencia diferencial |
| (b) GC trazador preciso, no móvil, marcado y barrido | Medio-alto: asignador + marcado iterativo + barrido; raíces = ranuras etiquetadas de todos los marcos (cadena de `rbp`) | Pausas proporcionales al heap vivo; hay que garantizar que cada llamada al asignador ocurra con todos los valores en ranuras (ya es así) | Misma semántica que el intérprete (ciclos incluidos); el escaneo es exacto gracias a las etiquetas, sin conservadurismo |
| (c) RC + recolector de ciclos (trial deletion) | Alto: (a) más el algoritmo de ciclos | Dos mecanismos que mantener | Libera pronto y recupera ciclos |
| (d) Región única sin liberar | Bajo | Crecimiento ilimitado en bucles largos (el problema que tuvo el intérprete) | Inaceptable salvo para programas cortos |

**Recomendación: (b).** El diseño de marcos del backend propio hace el escaneo
de raíces exacto y barato: recorrer la cadena de `rbp`, y en cada marco las
`n` ranuras (cuántas lo dice una tabla por función emitida en `.rdata`, indexada
por dirección de retorno, o una palabra de cabecera en el propio marco). Iguala
la semántica del intérprete con ciclos y deja al backend C como única pieza con
RC (que puede migrar más tarde). Recolectar solo dentro del asignador, que se
invoca siempre desde una instrucción IR con sus operandos ya en ranuras.

Detalles propuestos para (b):

- Objeto en el heap: cabecera de 16 bytes (tipo, marca, tamaño) + datos. Textos
  inmutables con longitud; listas con capacidad y elementos etiquetados;
  diccionarios con tabla abierta y orden de inserción, como el intérprete.
- Asignador: Windows `GetProcessHeap`/`HeapAlloc`/`HeapFree` (kernel32, sin CRT)
  en la primera versión; Linux, `mmap` con listas libres por tamaño (sin libc).
  El contador de bytes vivos dispara la recolección con el mismo umbral
  geométrico que el intérprete.
- Marcado con pila explícita en el heap (sin recursión), como en el intérprete.
- Raíces adicionales: literales estáticos (no se marcan: no están en el heap),
  el valor de error en vuelo y el búfer de salida (no contiene referencias).

## Decisión 2: cómo se escribe el runtime nativo

| Opción | Coste | Riesgos | Encaje con autohospedaje |
|---|---|---|---|
| (i) Rutinas emitidas por el propio generador (mini-ensamblador en Zig, como hoy `imprimir` y el búfer de salida) | Alto: asignador, GC, textos, diccionarios y formateo en código máquina escrito a mano | Errores de codificación difíciles de depurar; mitigado con pruebas diferenciales | Bueno: el generador en Alma reemplazará al de Zig con el mismo diseño |
| (ii) Runtime en Zig precompilado a un blob de código reubicable, incrustado en `alma` en tiempo de construcción | Medio: un paso de `build.zig` (objeto freestanding → binario plano) y un enlazador mínimo de símbolos del blob | El runtime de cada ejecutable lo produce Zig: los programas siguen sin invocar Zig, pero la independencia depende del compilador semilla hasta reescribirlo | Malo a largo plazo: hay que reescribirlo para el nivel 3 |
| (iii) Runtime escrito en Alma y compilado por el backend propio | Bajo cuando el backend sea completo | Huevo y gallina: necesita colecciones y textos compilados | Ideal en la fase de autohospedaje |

**Recomendación: (i) ahora, con un mini-ensamblador tipado en Zig** (funciones
`mov`, `add`, `call`, etiquetas) en vez de bytes literales, para que las rutinas
del runtime sean legibles y probables una a una; migrar a (iii) durante el
autohospedaje. (ii) acelera a corto plazo pero contradice el objetivo.

## Decisión 3: formateo de decimales en el backend propio (etapa D2a)

`imprimir(decimal)` debe producir los bytes de `numeros.formatearDecimal`.
Sin CRT no hay `printf`/`strtod`, así que la técnica del runtime C no sirve.

| Opción | Coste | Riesgo |
|---|---|---|
| (α) Ryu con tablas pequeñas (como `std.fmt.float.Backend64_TablesSmall`): multiplicaciones 64×64→128 (`mul`) y tablas de potencias de 5 en `.rdata` | Medio | Correcto por construcción si se porta fielmente; validar con los mismos 20.000 patrones de bits del intérprete |
| (β) Dragon4 / aritmética de enteros grandes exacta | Medio | Más lento; sin tablas |
| (γ) Schubfach | Medio | Algoritmo menos extendido |

**Recomendación: (α)**, porque el intérprete ya usa Ryu de `std` como referencia
y las pruebas pueden comparar bit a bit ambas implementaciones.

## Decisión solicitada

Elegir el modelo de memoria (a/b/c), la forma del runtime (i/ii/iii) y el
algoritmo de formateo (α/β/γ). Recomendación: **(b) + (i) + (α)**. Hasta recibir
la decisión, el backend propio sigue rechazando de forma explícita decimales,
`texto()`, concatenación, colecciones, objetos, errores, async y stdlib.
