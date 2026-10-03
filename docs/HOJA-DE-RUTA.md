# Hoja de ruta hacia la independencia de Alma

Fecha: 2026-10-03. Complementa [PLAN-INDEPENDENCIA.md](PLAN-INDEPENDENCIA.md)
(objetivos) y [AUDITORIA.md](AUDITORIA.md) (hallazgos). Orden: primero lo que
hace inutilizable el lenguaje, luego la semántica común, luego las pruebas que
la fijan, luego el backend propio por etapas y al final el autohospedaje.
Ninguna etapa añade dependencias externas.

## Fase A — Hacer usable el intérprete (hecho en esta entrega)

| Tarea | Depende de | Criterio de aceptación | Riesgo |
|---|---|---|---|
| A1. GC con puntos seguros (I1–I5) | — | Pruebas de 100.000 iteraciones con umbral de 128 bytes (concatenación, listas, diccionarios, `texto()`, métodos, recursión, `intentar/capturar`, promesas) sin fallos ni fugas; caso CLI de 200.000 iteraciones | Raíz olvidada en una nativa nueva: toda nativa debe crear objetos con `registrarGc` y no recolectar |
| A2. Nativas sin abortos (I6–I8) | A1 | Errores capturables para NaN/inf/fuera de rango y ciclos | — |
| A3. Allocator de release y topes de E/S (R2, R4, R5) | A1 | `smp_allocator` en release; respuesta de red acotada | Sin timeout de red (R3) |

## Fase B — Semántica única entre motores (hecho)

| Tarea | Depende de | Criterio | Riesgo |
|---|---|---|---|
| B1. Formato decimal, comparación mixta, mínimo i64, `\0` (N1–N5) | — | Vectores de `numeros.zig`; muestreo de 20.000 patrones de bits con ida y vuelta exacta; casos diferenciales `decimales-formato`, `comparaciones-mixtas`, `escapes`, `enteros-extremos` | `strtod`/`printf` del CRT deben redondear correctamente (las diferenciales lo detectan) |
| B2. JSON correcto (N6) | B1 | Escapes `\u` con sustitutos, control como `\u00XX`, `-0`, no finitos rechazados | — |
| B3. Decisiones abiertas: identidad de referencias (I11), orden en `x[i] = v` (I14), rechazo léxico de escapes desconocidos (N7) | B1 | Aprobación del responsable y casos diferenciales nuevos | Cambia programas existentes |

## Fase C — Pruebas diferenciales como contrato (hecho)

`compilador/pruebas-diferenciales` + `zig build diferencial`, en CI Linux y
Windows. Criterio de aceptación de cualquier cambio de backend: el caso declara
el motor en `// motores:` y produce los mismos bytes y código de salida. Ampliar
la batería es obligatorio antes de declarar soportada una construcción.

## Fase D — Backend propio por etapas

| Etapa | Contenido | Depende de | Criterio de aceptación | Riesgo |
|---|---|---|---|---|
| D1 (hecho) | Ranuras reutilizadas, marcos hasta 128 KiB, límite de 64 llamadas, búfer de salida, literales únicos, UNWIND_INFO en todo el código, ASLR, determinismo, sin `unreachable` | C | `pruebas-propio.ps1` sin Zig en PATH; casos diferenciales con `propio` | ASLR depende del cargador de Windows: se comprueba ejecutando |
| D2a | Decimales (SSE2): literales, aritmética, comparación exacta, `imprimir` con el formato canónico | Decisión sobre la rutina de formato (ver [PROPUESTA-MEMORIA-NATIVA.md](PROPUESTA-MEMORIA-NATIVA.md) §4) | `decimales-formato` y `comparaciones-mixtas` con `propio` | El formateador shortest en código máquina es la pieza de mayor riesgo |
| D2b | Heap y textos dinámicos: `texto()`, concatenación | **Decisión de modelo de memoria** | `texto-concatenacion` con `propio`; sin fugas medidas con un contador como `ALMA_VERIFICAR_MEMORIA` | Elegir mal el modelo obliga a reescribir D2c–D2e |
| D2c | Listas y diccionarios | D2b | `colecciones` con `propio` | Ciclos si el modelo es RC |
| D2d | `estructura`/`modelo`, métodos | D2c | `errores-modelo` sin la parte de errores | — |
| D2e | `intentar/capturar/lanzar` | D2d | `errores-modelo` con `propio` | Interacción con unwind: preferir retorno de error explícito a SEH |
| D2f | `asincrona`/`esperar`/`hilo` (síncronos, como el intérprete) | D2e | `async` diferencial | — |
| D2g | stdlib: `matematicas`, `cadena`, `json`, `sistema` | D2c | Casos diferenciales por módulo | `sistema` necesita más importaciones de kernel32 |
| D3 | ELF x86-64 para Linux con syscalls directos | **Decisión** ([PROPUESTA-ELF-LINUX.md](PROPUESTA-ELF-LINUX.md)) | Todos los casos `propio` también en Linux en CI | Dos ABIs que mantener |
| D4 | `red` con TLS | **Decisión** ([PROPUESTA-RED-TLS.md](PROPUESTA-RED-TLS.md)) | Pruebas contra servidor local | Superficie criptográfica |

Regla para todas las etapas: sin fallback silencioso a C. Lo no soportado se
rechaza en `validar()` con un mensaje explícito antes de escribir el ejecutable.

## Fase E — Distribución (parcial)

Hecho: verificación SHA-256 obligatoria y generación de sumas por versión; CI
con Zig verificado. Pendiente: flujo de publicación que construya
`-Doptimize=ReleaseSafe` para cada plataforma, compare dos construcciones
independientes byte a byte y publique `SHA256SUMS.txt`; firma de los artefactos.

## Fase F — Autohospedaje

Solo planificación: [AUTOHOSPEDAJE.md](AUTOHOSPEDAJE.md). Requiere D2a–D2g como
mínimo (el compilador necesita textos dinámicos, colecciones, estructuras,
errores y E/S de archivos en el backend propio).

## Dependencias resumidas

```
A1 → A2, A3 → B1 → B2, B3 → C → D1 → D2a
                                D1 → [decisión memoria] → D2b → D2c → D2d → D2e → D2f
                                                                 D2c → D2g
                                D2* → [decisión ELF] → D3
                                D2g → [decisión TLS] → D4
                                D2b..D2g → F (autohospedaje)
```
