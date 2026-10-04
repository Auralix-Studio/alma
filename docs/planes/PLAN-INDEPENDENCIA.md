# Alma: camino a un compilador independiente

Actualizado: 2026-10-03. Este documento distingue implementación de objetivos.
Estado actual, hallazgos y orden de trabajo: [AUDITORIA.md](../informes/AUDITORIA.md) y
[HOJA-DE-RUTA.md](HOJA-DE-RUTA.md). Nivel de independencia: **1 parcial** (backend
propio sin herramientas externas solo para el subconjunto escalar en Windows x64).

## Objetivo

Distribuir un compilador Alma que genere ejecutables sin invocar Zig, C, LLVM,
un ensamblador ni un enlazador externos. Zig se conserva como herramienta de
construcción inicial. Posteriormente se escribirá el compilador en Alma y se
compilará a sí mismo. Los módulos de usuario se desarrollan en Alma desde ahora.

Independencia del compilador no significa independencia del sistema operativo:
archivos, procesos y red seguirán necesitando sus interfaces. Cada plataforma y
arquitectura requiere soporte explícito; no se promete compatibilidad universal.

## Primera mejora implementada

- `ejecutar`, `analizar` y `compilar` comparten el análisis semántico obligatorio.
- `compilar` carga funciones de módulos `.alma` con el cargador existente antes
  de generar C. Solo se admite el subconjunto nativo actual. (Más tarde se añadió
  aislamiento por archivo con `exportar`/importación selectiva; ver espec. 04.)
- Los errores detectados del CLI terminan con código 1, después de liberar sus recursos.
- Una ejecución fallida conserva la salida acumulada antes del error.
- Las comparaciones entre dos enteros `i64` no pasan por `f64` en ninguno de los
  dos motores. (Desde 2026-10-03 las mixtas entero/decimal también son exactas.)
- `pruebas/cli.ps1` comprueba procesos reales, módulos y concordancia de resultados.

Por defecto `alma compilar` utiliza `zig cc`. Ya existe un generador propio experimental
con `alma compilar archivo.alma --backend=propio`, descrito en la especificación 07.
El autohospedaje todavía está pendiente.

## Etapas y criterios de aceptación

1. **Semántica y runtime fiables.** Unificar tipos, evaluación de argumentos,
   conversiones, errores aritméticos y ámbitos entre motores. Definir desbordamiento,
   propiedad de textos/colecciones y liberación de memoria. Pruebas de concordancia
   y mediciones de memoria en programas largos antes de ampliar el lenguaje.
2. **Representación intermedia propia.** Bajar el AST validado a instrucciones con
   operaciones, valores, funciones, bloques y posiciones de origen. Separar el
   backend C de la semántica y probar ambos contra el intérprete. Ninguna dependencia
   nueva de LLVM es necesaria para este diseño.
3. **Backend nativo propio, inicialmente Windows x64.** Emitir instrucciones,
   convenciones de llamada, relocaciones, importaciones y ejecutables PE/COFF.
   Añadir el runtime mínimo de salida, memoria y errores. Criterio: compilar y
   ejecutar pruebas con Zig y demás compiladores ausentes del PATH. El backend C
   se conserva temporalmente como referencia, sin fallback silencioso.
4. **Módulos y biblioteca implementados en Alma.** Compilar colecciones, tipos por
   valor/referencia, bytes y E/S; definir visibilidad, rutas canónicas y ciclos de
   importación. Criterio: construir aplicaciones multiarchivo con herramientas Alma.
5. **Autohospedaje.** Escribir lexer, parser, analizador y backend en Alma.
   Usar el compilador inicial para producir la primera versión; esa versión debe
   compilar la siguiente. Comparar artefactos reproducibles y ejecutar la batería
   de compatibilidad. Documentar y conservar el procedimiento de bootstrap.
6. **Más plataformas.** Añadir ELF/Linux y otras arquitecturas con pruebas propias.

## Deuda conocida

Actualizado 2026-10-03. El intérprete libera memoria con un GC de marcado y barrido
(ya no retiene todo en una arena). El runtime C libera textos dinámicos con conteo
de referencias, pero no compila objetos ni colecciones. El formato decimal, las
comparaciones mixtas, el mínimo i64 y los escapes ya coinciden entre intérprete y C
(pruebas diferenciales). Siguen abiertas: igualdad de referencias, orden de
evaluación en asignaciones indexadas, escapes desconocidos, timeout de red y todo
el lenguaje no escalar en el backend propio. Async es síncrono. Estas limitaciones
impiden presentar la versión actual como estable.

## Segunda mejora: errores del runtime y aritmética

- El runtime C valida que las operaciones numéricas reciban números, que las
  condiciones reciban lógicos y que `%` reciba enteros. La concatenación requiere
  dos textos; convertir números a texto requiere `texto(...)` explícito.
- La división por cero falla también con decimales, como en el intérprete.
- Los operadores de suma, resta, producto, división y negación de enteros detectan
  desbordamiento en ambos motores. El intérprete lo expone como error capturable;
  el runtime nativo termina con código 1 (todavía no compila `intentar`).
- La división entera trunca hacia cero. El resto conserva el signo del dividendo;
  `minimo_i64 % -1` vale cero sin ejecutar una división que desborde.
- Imprimir números en el runtime C ya no reserva textos temporales. Las reservas
  para `texto(...)` y concatenación comprueban fallos, pero siguen pendientes de
  gestión de vida útil: esto todavía no constituye una solución completa de memoria.

El backend C usa operaciones comprobadas de su compilador de construcción; el
futuro backend propio deberá implementar el mismo contrato y pasar estas pruebas.

## Tercera mejora: evaluación ordenada y salida inmediata

- El backend baja operandos y argumentos a temporales locales de cada función.
  Evalúa de izquierda a derecha mediante secuencias explícitas de C, sin depender
  del orden de evaluación que el compilador C elija para los argumentos.
- `&&` y `||` conservan el cortocircuito. Los temporales se recalculan al evaluar
  condiciones de bucles y cada llamada recursiva tiene sus propios temporales.
- El CLI conecta el intérprete a un destino de salida inmediato. El intérprete
  conserva el modo de captura por defecto para pruebas y uso embebido.
- El búfer de salida se reutiliza después de cada impresión; los fallos del destino
  producen un error de Alma y no provocan reenvíos automáticos del texto.
- El formato numérico del intérprete y de JSON usa memoria temporal en stack,
  evitando reservas en la arena para cada número. Una prueba comprueba que imprimir
  repetidamente el mismo número no aumenta la capacidad de la arena tras calentamiento.

Esto reduce retención por salida, pero no resuelve todavía las asignaciones de
argumentos, objetos ni textos persistentes del intérprete.

## Cuarta mejora: IR, textos nativos y backend independiente

La compilación ya pasa por una IR propia, sin AST ni C incrustados. Ambos backends
consumen esa IR. El backend C retiene/libera textos dinámicos; el backend propio emite
código máquina x64 y PE32+ sin herramientas externas para un subconjunto escalar.
Se añadió `alma ir`, diagnóstico de archivo de origen en módulos y verificaciones
de memoria. El detalle y los límites están en
[IR y backend propio](../especificacion/07-ir-y-backend-propio.md).

## Verificación local (Windows)

Con Zig 0.16 accesible en el PATH, desde `compilador`:

```powershell
zig build test
zig build
zig build diferencial
./pruebas/limites.ps1
./pruebas/cli.ps1
./pruebas/propio.ps1
```

Los resultados de la última verificación están en
[INFORME-ENDURECIMIENTO.md](../informes/INFORME-ENDURECIMIENTO.md).

Las pruebas CLI conservan sus casos generados bajo `.zig-cache/pruebas-cli` para
inspección. No requieren red ni modifican instalaciones del usuario.

Verificado el 2026-10-02 en Windows: construcción del CLI, 91 pruebas unitarias,
80 comprobaciones CLI con backend C (`-O2`) y 48 comprobaciones del backend propio
sin herramientas externas en el PATH.
En la primera etapa también se verificó el análisis semántico de todos los ejemplos.
Estas comprobaciones no certifican las características aún pendientes.
