# Endurecimiento de Alma — entrega parcial verificable

Fecha: 2026-10-03. Plataforma ejecutada: Windows x64, Zig 0.16.0 de WinGet.

## Línea base

El primer `zig build test` en `compilador/` no pudo iniciar porque Zig no era
accesible mediante el PATH del sandbox. Se ejecutó después la instalación
existente mediante `C:\Users\aless\AppData\Local\Microsoft\WinGet\Links\zig.exe`.
Resultado antes de modificar código: **91/91 pruebas pasan**.

El usuario aprobó explícitamente los tres máximos de 64 y su conteo en
[el contrato de límites](PROPUESTA-LIMITES.md). No se añadieron dependencias.

## Tarea 1 completada

| Corrección / commit | Archivos tocados (rutas desde la raíz) | Regresión observada antes | Resultado posterior |
|---|---|---|---|
| Parser — `8c6e780` | `compilador/src/sintaxis/parser.zig`, `compilador/src/limites.zig`, `compilador/src/main.zig`, `compilador/pruebas-limites.ps1`, `docs/PROPUESTA-LIMITES.md`, `docs/especificacion/02-gramatica.md` | Las cuatro pruebas nuevas aceptaban profundidad indebida: 91 pasan, 4 fallan | `zig build test`: 95/95; 4 comprobaciones CLI del parser |
| Intérprete — `acd81ab` | `compilador/src/ejecucion/interprete.zig`, `compilador/pruebas-limites.ps1` | Tres pruebas nuevas no obtenían el error esperado: 95 pasan, 3 fallan | `zig build test`: 98/98; 2 comprobaciones CLI |
| Runtime C — `0cf8bd5` | `compilador/src/emision_c.zig`, `compilador/src/runtime/escalar.h`, `compilador/pruebas-limites.ps1` | El programa de frontera 65 terminaba con código 0, haciendo fallar la nueva prueba CLI | `zig build test`: 98/98; 6 comprobaciones CLI de C |
| JSON — `364964b` | `compilador/src/ejecucion/interprete.zig`, `compilador/pruebas-limites.ps1`, `docs/especificacion/05-libreria-estandar.md` | Dos pruebas nuevas aceptaban el contenedor 65: 98 pasan, 2 fallan | `zig build test`: 100/100; 2 comprobaciones CLI de JSON |

### Pruebas añadidas

Nueve pruebas unitarias:

- Parser: frontera de paréntesis y restauración entre expresiones; altura de
  unarios/binarios/postfijos; contenedores/argumentos/índices; presupuesto
  combinado de bloques y expresiones. También comprueban restauración del
  contador tras un error y posición de diagnóstico válida.
- Intérprete: frontera 64/65 con captura y recuperación repetida; recursión
  mutua; funciones y métodos compartiendo el mismo presupuesto.
- JSON: frontera 64/65 con análisis normal posterior; anidamiento mixto de
  arreglos y objetos.

Nueva suite `compilador/pruebas-limites.ps1`, con timeout por proceso de 30 s:

- 200.000 paréntesis: `analizar`, `ejecutar`, `compilar` y `ast` terminan con
  código 1 y diagnóstico `parentesis.alma:1:65:`.
- Recursión infinita interpretada: código 1 y diagnóstico de origen; captura
  repetida de ese error permite continuar y terminar con éxito.
- Runtime C: frontera 64 aceptada en 100 llamadas sucesivas, frontera 65
  rechazada con código 1, recursión infinita rechazada con diagnóstico de origen.
- JSON con 300.000 `[` tanto incompleto como cerrado: error capturado y análisis
  posterior de `42` correcto.

### Verificación final ejecutada

| Comando desde `compilador/` | Resultado observado |
|---|---|
| `zig build test --summary all` | 100/100, Debug |
| `zig build test -Doptimize=ReleaseSafe --summary all` | 100/100 |
| `zig build` + `./pruebas-limites.ps1` | 14 comprobaciones correctas, Debug |
| `zig build -Doptimize=ReleaseSafe --prefix .zig-cache/release-safe` + suite de límites con ese binario | 14 comprobaciones correctas |
| `./pruebas-cli.ps1` | 80 comprobaciones correctas |
| `./pruebas-propio.ps1` | 48 comprobaciones correctas, incluidas las de determinismo, sin Zig en PATH durante las pruebas propias |

Las compilaciones C de las suites usan el comando actual de Alma con `zig cc`.
No se ejecutaron suites Linux ni ReleaseFast. Los casos temporales quedan bajo
`compilador/.zig-cache/`; los scripts se pueden volver a ejecutar.

## Propuestas entregadas y decisiones pendientes

| Tarea | Documento y commit | Decisión solicitada |
|---|---|---|
| 2. Módulos | [Especificación 04](especificacion/04-modulos-y-paquetes.md), `f6c9c43` | Aprobar entornos por archivo, exports explícitos, importación selectiva, constantes privadas e inicialización única; incluye rutas canónicas y rechazo explícito de ciclos |
| 4. Números y escapes | [Números](PROPUESTA-NUMEROS.md) y [léxico](especificacion/01-lexico-y-tokens.md), `efbb980` | Aprobar formato binary64, ceros/no finitos y JSON, comparación mixta exacta, mínimo i64 y lista cerrada de escapes |
| 5. Memoria | [Comparación de alternativas](PROPUESTA-MEMORIA.md), `41e5be7` | Elegir ARC, GC o VM con ARC; recomendación propuesta: GC simple no móvil |

Estas propuestas son documentación y no correcciones implementadas. No agregan
pruebas de comportamiento aprobadas: esas pruebas pertenecen a su implementación
posterior. La batería de 100 pruebas corresponde al código de la tarea 1.

Se detiene la implementación en el paso 2 por la instrucción explícita de
proponer primero y esperar confirmación. Para conservar el orden solicitado,
las tareas 3–7 no se han implementado. La documentación de decisiones posteriores
se adelantó para permitir una revisión conjunta.

## Riesgos y trabajo abiertos

- Módulos: aislamiento, importación selectiva, constantes/importaciones internas,
  ciclos y rutas canónicas siguen pendientes de implementación.
- `alma compilar` conserva su comportamiento previo de escritura del C y salidas;
  directorio temporal, `--conservar-c`, `-o` y protección de archivos están pendientes.
- Las divergencias numéricas, NUL en la IR, validación del mínimo entero y
  comparación mixta no se han corregido. Tampoco se creó aún la nueva suite
  diferencial de archivos `.alma`; solo se ejecutó la suite CLI existente.
- La arena del intérprete sigue reteniendo valores. La nueva medición de capacidad
  en bucle largo solicitada en la tarea 5 aún no está añadida; no se afirma haber
  reproducido los 840 MB citados en la solicitud.
- Quedan todos los cambios de endurecimiento de la tarea 6, incluida la decisión
  de licencia, y las optimizaciones/protecciones del backend propio de la tarea 7.
- El backend propio todavía no tiene límite de llamadas. El parser compartido
  sí está protegido. Sus pruebas existentes pasan, sin implicar que esos defectos
  estén corregidos.
- Los contadores limitan profundidad lógica, no bytes de stack. Marcos C muy
  grandes y combinaciones extremas de expresiones y llamadas requieren evaluación
  adicional. La serialización/formateo de colecciones cíclicas tampoco queda
  protegida por el límite de `json.analizar`.
- Linux sigue sin validarse en esta entrega. No se creó CI todavía.
