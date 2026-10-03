# Memoria del intérprete — decisión pendiente

Fecha: 2026-10-03. Propuesta; no implementa ARC, GC ni VM.

## Punto de partida

La inspección de `ejecucion/interprete.zig` muestra una arena por intérprete:
entornos, textos, listas, diccionarios, instancias, errores, promesas y módulos
usan su allocator. Reasignar un valor reemplaza el enlace sin recuperar el
anterior. `deinit` libera la arena al terminar. Hay una prueba de capacidad para
salida repetida, pero no mide el bucle de concatenación señalado en la solicitud.
La cifra de 840 MB para 20 millones de iteraciones procede de esa solicitud;
no se presenta aquí como una medición reproducida.

No se puede reiniciar simplemente la arena en cada iteración: variables, alias,
contenedores y valores retornados pueden referenciar asignaciones anteriores.
Separar la vida del AST de la vida de los valores también es obligatorio.

## Alternativas

Los costos siguientes son relativos y no estimaciones de tiempo verificadas.

| Alternativa | Costo de implementación | Riesgos principales | Encaje con independencia |
|---|---|---|---|
| (a) ARC en el intérprete actual | Alto: redefinir propiedad de todos los `Valor`, entornos, retornos, temporales y caminos de error | Liberación prematura, dobles liberaciones, retenciones olvidadas; ciclos no se recuperan solo con ARC | Reutiliza el contrato de propiedad de la IR y experiencia con textos C; todavía exige otro trabajo al pasar a VM |
| (b) GC simple de marcado y barrido, no móvil | Medio: heap de objetos, raíces explícitas y recorrido de referencias | Raíces omitidas en temporales Zig/nativas; pausas y umbrales de recolección; recorrido debe evitar recursión sin límite | Puede implementarse sin dependencias y portarse a Alma; futuro backend necesita protocolo de raíces o mantener un runtime diferente |
| (c) VM de bytecode con ARC compartida con runtime nativo | Muy alto: VM, bytecode, verificación, marcos explícitos, cobertura del lenguaje y runtime de objetos | Migración extensa antes de corregir la memoria; duplicidad temporal de motores; ciclos continúan siendo problema de ARC | Mejor convergencia a largo plazo de propiedad, errores y autohospedaje; la IR escalar actual aún no cubre todas las colecciones/objetos |

### Recomendación

Elegir (b) si la prioridad es recuperar pronto memoria del intérprete completo,
incluidos grafos cíclicos. Mantener la arena para AST/datos inmutables del programa
y mover valores de vida dinámica al heap trazado. No usar escaneo conservador del
stack: registrar raíces explícitas en globales, marcos, temporales, errores en
vuelo, módulos, promesas y llamadas nativas. Recolectar solo en puntos donde
esas raíces estén completas. Usar marcado iterativo para evitar otro desbordamiento.

Elegir (c) si la prioridad permite posponer la solución y financiar la convergencia
con el backend independiente. Antes de compartir ARC de objetos hay que decidir
el tratamiento de ciclos; el ARC escalar de textos del backend C no lo resuelve.
La opción (a) tiene menos sustitución arquitectónica que (c), pero comparte ese
riesgo y obliga a auditar manualmente los temporales del recorrido AST.

Ninguna opción requiere nuevas dependencias de Zig/C/LLVM en los programas Alma.
La implementación inicial en Zig sigue siendo parte del bootstrap; autohospedaje
requiere portar tanto el compilador como las partes necesarias de su runtime.

## Medición de regresión prevista

Agregar un caso Zig que ejecute código Alma real, sin `imprimir` ni `rango(n)`:
`mientras i < n`, `s = "x" + texto(i)`, incremento de `i`. Medir
`interp.arena.queryCapacity()` tras inicialización y tras lotes largos con el
mismo intérprete; comprobar también el último `s` y el contador para impedir
que una ejecución vacía pase. Conservar AST/lexer fuera de la arena medida.

Registrar bytes absolutos y delta, tamaño del lote, arquitectura y optimización.
Calibrar un techo generoso a partir de la medición local para detectar aumentos
accidentales sin convertir la retención actual en un requisito. El caso de
20 millones debe ser una medición optativa fuera de la suite rápida; usar un
lote menor en CI. La capacidad de arena no equivale al RSS del proceso.

Al introducir recuperación, sustituir el techo provisional por una comprobación
de estabilización con estado vivo constante; añadir alias, ciclos, valores que
escapan de funciones, copia de estructuras, errores y fallos de asignación.
La medición todavía está pendiente y no cuenta como corrección de memoria.

## Decisión solicitada

Elegir (a), (b) o (c); recomendación inicial: (b). No comenzar una migración de
propiedad ni introducir ARC antes de recibir esa decisión.
