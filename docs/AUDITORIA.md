# Auditoría de Alma — 2026-10-03

Alcance: todo el repositorio en la rama `main`, estado base `b71dc3c` más el
trabajo sin commitear que había en `interprete.zig` (GC a medio rehacer). Las
referencias `archivo:línea` apuntan a `b71dc3c` salvo que se indique otra cosa.
Cada hallazgo se confirmó leyendo el código; la columna «Estado» remite al
commit que lo corrige o a la decisión pendiente. Los resultados de ejecución
están en [INFORME-ENDURECIMIENTO.md](INFORME-ENDURECIMIENTO.md).

## 1. Nivel de independencia actual (con evidencia)

| Nivel | Criterio | Estado en `b71dc3c` | Evidencia |
|---|---|---|---|
| 1 | `alma compilar` sin Zig/C/LLVM/ensamblador/enlazador | **Parcial**: solo `--backend=propio`, solo Windows x64 y solo un subconjunto escalar. El backend por defecto invoca `zig cc` | `main.zig:295` (`"zig", "cc"`); `codegen_pe.zig` emite PE32+ propio; `codegen_pe.zig:162,188,217` rechazan decimales, `texto()` y concatenación |
| 2 | Backend propio con el lenguaje completo | **No** | `ir.zig:190,246` rechaza colecciones, acceso a miembros, tipos, errores y concurrencia; la biblioteca estándar solo existe en `interprete.zig` |
| 3 | Autohospedaje | **No** | No hay ningún componente del compilador escrito en Alma; lexer, parser, analizador, IR y backends son Zig |
| 4 | Distribución sin dependencias, hash verificado, builds reproducibles | **Parcial** | El binario `alma` es autocontenido para interpretar; `instalar.sh:20-36` e `instalar.ps1:20-30` omitían la verificación en silencio; no hay procedimiento de build reproducible del propio `alma` |

Conclusión: **nivel 1 parcial**. Todo el lenguaje real (colecciones, objetos,
errores, async, stdlib, red) vive en el intérprete tree-walking dentro de un
binario Zig. Este trabajo no cambia el nivel: endurece el subconjunto existente
del backend propio y prepara las decisiones necesarias para ampliarlo.

## 2. Hallazgos

Severidades: **C** crítico (crash, corrupción, pérdida de datos,
vulnerabilidad), **A** alto (comportamiento incorrecto, divergencia entre
motores), **M** medio (malas prácticas, rendimiento, mantenibilidad), **B** bajo.

### 2.1 Intérprete y memoria

| # | Sev. | Hallazgo | Ubicación | Causa | Corrección | Estado |
|---|---|---|---|---|---|---|
| I1 | C | Segfault en bucles largos con concatenación, listas y `texto()` | `interprete.zig:247-262` | `registrarGc` llamaba a `recolectar()` en cualquier reserva; los temporales que solo vivían en el stack de Zig (operandos, listas a medio construir) no eran raíces y se liberaban | Recolectar solo en puntos seguros (inicio de sentencia, cabeza de bucle) con raíces temporales por sentencia | `21a5d95` |
| I2 | C | Recursión sin límite al marcar | `interprete.zig:293-338` | `marcarPtr`/`marcarEntorno` recursivos sobre listas y entornos | Marcado con pila explícita reservada antes de marcar | `21a5d95` |
| I3 | A | Errores tragados al barrer | `interprete.zig:347` | `nuevos.put(...) catch {}` perdía objetos vivos del índice si fallaba la reserva | Barrido sin reservas (`removeByPtr` + `rehash`) | `21a5d95` |
| I4 | M | Umbral de GC con bytes ficticios | `interprete.zig:260` | `bytes_reservados += 64` por objeto, sin relación con el tamaño real | `memoria_gc.zig` cuenta bytes reales; umbral geométrico | `21a5d95` |
| I5 | C | Use-after-free en `para` | `interprete.zig:758` | Se iteraba `l.items`; `agregar` en el cuerpo reubica el buffer | Iterar una instantánea enraizada | `21a5d95` |
| I6 | C | Pánico/UB en conversiones | `interprete.zig:1294,1298,1302` | `@intFromFloat` de NaN/inf/fuera de i64 | Conversión comprobada con error de Alma | `0189b50` |
| I7 | C | Pánico en `absoluto(mínimo)` y `salir(256)` | `interprete.zig:1287,1429` | `-n` desborda; `@intCast` a `u8` sin validar | Errores capturables | `0189b50` |
| I8 | C | Desbordamiento de stack al mostrar/serializar estructuras cíclicas | `interprete.zig:1094,1603` | Recursión sin límite (`agregar(l, l); imprimir(l)`) | Límite `limites.anidamiento` (64) | `0189b50` |
| I9 | M | Mensaje de depuración en producción | `interprete.zig:525` | `std.debug.print("ERROR: ...")` | `fallar(...)` | `21a5d95` |
| I10 | B | `catch unreachable` evitable | `interprete.zig:1716` | `bufPrint` de 3 bytes | Tabla hexadecimal | `0189b50` |
| I11 | M | Igualdad de referencias siempre falsa | `interprete.zig:103-115` | `sonIguales` devuelve `falso` para listas, diccionarios e instancias, incluso `a == a` | Definir identidad vs igualdad estructural | **Decisión pendiente** |
| I12 | B | `TipoDef` se reserva en la arena en cada declaración | `registrarTipo` | Un `modelo` declarado dentro de un bucle retiene memoria | Mover a tabla por declaración | Pendiente |
| I13 | B | Semilla de `aleatorio` débil | `matAleatorio` | Dirección de stack | Usar `io.random` cuando hay E/S | Pendiente |
| I14 | M | Orden de evaluación en `x[i] = v` | `ejecStmt .asignacion` | Se evalúa `v` antes que `x` e `i` | Especificar el orden | **Decisión pendiente** |

### 2.2 Semántica numérica y divergencias entre motores

| # | Sev. | Hallazgo | Ubicación | Causa | Corrección | Estado |
|---|---|---|---|---|---|---|
| N1 | A | Formato decimal distinto: intérprete `0.30000000000000004`, C `0.3`; `1e+07`; `0.333333` | `interprete.zig:1104`; `escalar.h:134,145` | `{}` de Zig vs `%g` de C | Shortest round-trip común (`numeros.zig`; C busca la menor precisión que relee) | `5b0a5a5` |
| N2 | A | Comparación mixta inexacta: `9007199254740993 == 9007199254740992.0` verdadero | `interprete.zig:103-112,1017`; `escalar.h:113,119` | El entero se convertía a `f64` | Orden exacto entero/decimal en ambos motores | `5b0a5a5` |
| N3 | A | `-9223372036854775808` fallaba | `ir.zig:114`, `interprete.zig` (`literal_entero`) | La magnitud se convierte antes de negar | Plegado en el parser; el analizador rechaza otros fuera de rango | `5b0a5a5` |
| N4 | A | `"\0"` divergía | `ir.zig:93-111` | La IR no reconocía `\0` | Decodificador único | `5b0a5a5` |
| N5 | A | Runtime C convertía `\n` en `\r\n` en Windows | `escalar.h` (stdout en modo texto) | CRT de Windows | `_setmode(_O_BINARY)` | `5b0a5a5` |
| N6 | A | JSON inválido con caracteres de control; `\u` no soportado; NaN/inf serializables; `-0` perdía el signo | `interprete.zig:1497,1603` | Escapes incompletos | Escapes `\uXXXX` con sustitutos, `\u00XX` al serializar, error para no finitos | `693c173` |
| N7 | M | Escapes desconocidos eliminan la barra en silencio | `numeros.byteDeEscape` | Comportamiento heredado | Rechazo léxico propuesto en espec. 01 §8.3 | **Decisión pendiente** |

### 2.3 Red, sistema y CLI

| # | Sev. | Hallazgo | Ubicación | Causa | Corrección | Estado |
|---|---|---|---|---|---|---|
| R1 | C | Inyección de cabeceras y aborto del proceso | `interprete.zig:1683` | Nombres/valores con CR/LF o `:` pasaban a `std.http`, que los `assert`a | Validación previa | `68c48a8` |
| R2 | A | Respuesta de red sin tope | `interprete.zig:1660` | `Writer.Allocating` sin límite; `limites.red_respuesta` sin uso | `allocRemaining(.limited)` | `68c48a8` |
| R3 | A | Sin timeout de red | `interprete.zig:1645-1661` | `std.http.Client` 0.16 no lo expone | Propuesta en [PROPUESTA-RED-TLS.md](PROPUESTA-RED-TLS.md) | **Pendiente** |
| R4 | M | `page_allocator` en release | `main.zig:40` | Una página por objeto pequeño | `smp_allocator` | `68c48a8` |
| R5 | M | Topes de lectura no configurables | `limites.zig` | Constantes | `--limite-lectura`, `--limite-red` | `68c48a8` |
| R6 | A | URL sin codificar en el cuerpo POST | `alma/principal.alma:107` | Concatenación directa de `region` | `red.codificar_url` | `68c48a8` |
| R7 | C | `alma nuevo` sobrescribe archivos del usuario | `main.zig:412-460` | `writeFile` sin comprobar existencia | Comprobación previa de los tres archivos | `12a09a6` |
| R8 | B | `sistema.escribir_archivo` escribe cualquier ruta | `sisEscribirArchivo` | Diseño sin sandbox | Documentado; sin cambio | Aceptado |

### 2.4 Backend propio (`codegen_pe.zig`, `ir.zig`)

| # | Sev. | Hallazgo | Ubicación | Causa | Corrección | Estado |
|---|---|---|---|---|---|---|
| P1 | C | Sin límite de llamadas: recursión infinita agota el stack sin diagnóstico | `codegen_pe.zig` (no existía) | — | Contador en `.data`, error con código 1 a las 65 llamadas activas | `fa097db` |
| P2 | A | Registros temporales sin reutilizar; marco > 4096 rechazado (~250 registros) | `ir.zig:70`, `codegen_pe.zig:235` | Un registro por expresión | Ranuras por intervalos de vida + sondeo de páginas hasta 128 KiB | `81d2c8f`, `fa097db` |
| P3 | M | Un `WriteFile` por fragmento | `codegen_pe.zig:448` | Sin búfer | Búfer de 4 KiB, vaciado al salir y antes de errores | `fa097db` |
| P4 | B | Literales duplicados | `codegen_pe.zig:79` | Sin tabla | Deduplicación | `fa097db` |
| P5 | M | Rutinas de error sin UNWIND_INFO | `codegen_pe.zig:530` | Se saltaba (`jmp`) fuera de cualquier rango de `.pdata` | Rutinas llamadas, con prólogo y `.pdata` | `fa097db` |
| P6 | M | Sin ASLR | `codegen_pe.zig:620,635` | `RELOCS_STRIPPED`, sin `DYNAMIC_BASE` | Flags + bloque de reubicación de relleno | `fa097db` |
| P7 | B | `unreachable` dependientes de `validar` | `codegen_pe.zig:273,329` | — | Errores explícitos | `fa097db` |
| P8 | A | Cobertura: sin decimales, `texto()`, concatenación, colecciones, objetos, errores, async, stdlib | `codegen_pe.zig:162,188,217` | Falta runtime con memoria dinámica | [PROPUESTA-MEMORIA-NATIVA.md](PROPUESTA-MEMORIA-NATIVA.md) | **Decisión pendiente** |
| P9 | M | Solo Windows x64 | — | Sin emisor ELF | [PROPUESTA-ELF-LINUX.md](PROPUESTA-ELF-LINUX.md) | **Decisión pendiente** |
| P10 | B | Diagnósticos de error sin archivo/línea | rutinas de error | Sin tabla de posiciones | Tabla de posiciones por llamada | Pendiente |

### 2.5 Repositorio, pruebas, CI y distribución

| # | Sev. | Hallazgo | Ubicación | Corrección | Estado |
|---|---|---|---|---|---|
| D1 | M | Archivos sobrantes versionados: `interprete.zig.bak/.new`, `dummy.zig`, `test_fmt.zig`, `compilador/principal.alma`, `compilador/operaciones.alma` | raíz de `compilador/` | Eliminados (sin referencias); `.gitignore` con `*.bak`, `*.new`, `*.orig` | `9d7bc1f` |
| D2 | C | Instaladores omitían la verificación si faltaba el hash, la herramienta o la entrada; `grep`/`-match` por subcadena/regex | `instalar.sh:20-36`, `instalar.ps1:20-30` | Abortar en todos los casos; coincidencia exacta | `ef966e1` |
| D3 | M | `SHA256SUMS.txt` listaba binarios no versionados | `distribucion/SHA256SUMS.txt` | Retirado; `generar-sumas.sh` por versión | `ef966e1` |
| D4 | A | CI: Linux solo con pruebas unitarias; sin diferenciales; `setup-zig` sin garantía para 0.16 | `.github/workflows/ci.yml` | Zig 0.16.0 verificado por SHA-256; diferenciales y límites en ambos sistemas; ReleaseSafe | `31e349b` |
| D5 | M | Pruebas de `ir.zig`, `emision_c.zig`, `modulos.zig` no registradas | `src/pruebas.zig` | Registradas | `5b0a5a5` |
| D6 | M | Sin pruebas diferenciales | — | `pruebas-diferenciales/` + `zig build diferencial` | `984a674` |
| D7 | B | Pruebas CLI comentadas (archivo de origen en errores de módulos, compilar sin Zig) | `pruebas-cli.ps1` (final) | Revisar y reactivar o eliminar | Pendiente |
| D8 | B | `desinstalar.ps1` borra la carpeta completa de instalación | `distribucion/desinstalar.ps1` | Borrar solo `alma.exe` | Pendiente |
| D9 | B | `.alma` y scripts con CRLF/LF mezclados (`core.autocrlf`) | `.gitattributes` | `-text` para `.salida`, `eol=lf` para `.sh` | `984a674` |

### 2.6 Documentación que contradice el código (estado base)

- `PLAN-INDEPENDENCIA.md` afirmaba que el intérprete retenía todo en una arena;
  el código ya tenía un GC (defectuoso, ver I1–I5).
- `especificacion/07` afirmaba «marcos limitados a 4096 bytes», «base fija sin
  ASLR» y «sin límite de llamadas» como estado; corregido en esta entrega.
- `INFORME-ENDURECIMIENTO.md` listaba como pendientes módulos aislados,
  `compilar -o` y licencia, ya implementados en `b71dc3c`.
- La cabecera de `interprete.zig` declaraba diferidos `estructura/modelo`, `para`
  y acceso a miembros, todos implementados.

## 3. Búsquedas específicas realizadas

- `catch {}`: único caso relevante I3; `sisSalir` ignora el fallo al vaciar la
  salida antes de terminar (aceptable: el proceso termina igualmente).
- `unreachable`: I10, P7; los restantes (`numeros.zig` al formatear dígitos de
  un `u64` en un búfer de 20 bytes) son demostrablemente inalcanzables.
- `.unlimited`: no aparece en el código de Alma; las lecturas usan
  `limites.archivo_fuente`, `limite_archivo` y `limite_red`.
- Recursión sin límite: parser, intérprete, runtime C y JSON ya acotados
  (`limites.zig`); se añadieron marcado del GC (I2) y formateo (I8). El cargador
  de módulos recursa por cadena de importaciones (acotado por el número de
  archivos) y `copiarValor` por anidamiento estático de `estructura`.
- Overflows: aritmética comprobada en los tres motores; `@intCast` de longitudes
  (`usize`→`i64`) seguro en 64 bits.
- Inyección: R1 (cabeceras). `sistema` no ejecuta procesos; no hay `shell`.
- Escrituras que sobrescriben: R7; `compilar` ya protegía la salida con
  `--sobrescribir` y la comprobación de fuentes.
- Determinismo: el backend propio genera bytes idénticos (prueba unitaria y
  `pruebas-propio.ps1`); el backend C depende de `zig cc`.
