# Alma: camino a un compilador independiente

Actualizado: 2026-10-02. Este documento distingue implementación de objetivos.

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
  de generar C. Solo se admite el subconjunto nativo actual. El cargador incorpora
  todas las definiciones del módulo: todavía no proporciona aislamiento de nombres.
- Los errores detectados del CLI terminan con código 1, después de liberar sus recursos.
- Una ejecución fallida conserva la salida acumulada antes del error.
- Las comparaciones entre dos enteros `i64` no pasan por `f64` en ninguno de los
  dos motores. Las comparaciones mixtas entero/decimal siguen convirtiendo a decimal.
- `pruebas-cli.ps1` comprueba procesos reales, módulos y concordancia de resultados.

`alma compilar` TODAVÍA utiliza `zig cc`. Esta etapa prepara la base; no implementa
un generador de código máquina ni autohospedaje.

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

El intérprete conserva memoria en una arena hasta finalizar; no implementa ARC.
El runtime C no libera sus textos dinámicos. Hay diferencias pendientes en tipos,
división decimal por cero y orden de evaluación. Async es síncrono. Los diagnósticos
de módulos necesitan conservar el archivo de origen de cada nodo. Estas limitaciones
impiden presentar la versión actual como estable o de consumo acotado.

## Verificación local (Windows)

Con Zig 0.16 accesible en el PATH, desde `compilador`:

```powershell
zig build test
zig build
./pruebas-cli.ps1
```

Las pruebas CLI conservan sus casos generados bajo `.zig-cache/pruebas-cli` para
inspección. No requieren red ni modifican instalaciones del usuario.
