# Informe de endurecimiento e independencia — 2026-10-03

Plataforma de verificación: Windows 11 x64, Zig 0.16.0 (WinGet), Windows
PowerShell 5.1. Base: `b71dc3c`. Hallazgos: [AUDITORIA.md](AUDITORIA.md); orden de
trabajo: [HOJA-DE-RUTA.md](../planes/HOJA-DE-RUTA.md).

## Nivel de independencia

| | Antes (`b71dc3c`) | Después |
|---|---|---|
| Nivel 1 | Parcial: `--backend=propio` sin herramientas externas, solo Windows x64 y subconjunto escalar; el backend C invoca `zig cc` | Igual cobertura, ahora con límite de llamadas, marcos grandes, búfer de salida, UNWIND_INFO completo y ASLR, y verificado contra el intérprete byte a byte |
| Nivel 2 | No | No (bloqueado por [PROPUESTA-MEMORIA-NATIVA.md](../propuestas/PROPUESTA-MEMORIA-NATIVA.md)) |
| Nivel 3 | No | No (plan en [AUTOHOSPEDAJE.md](../planes/AUTOHOSPEDAJE.md)) |
| Nivel 4 | Parcial; instaladores omitían la verificación | Parcial; verificación SHA-256 obligatoria, sumas generadas por versión |

## Verificación ejecutada (resultados reales)

| Comando, desde `compilador/` | Resultado |
|---|---|
| `zig build test --summary all` (Debug) | 126/126, 1 min |
| `zig build test -Doptimize=ReleaseSafe --summary all` | 126/126 |
| `zig build -Doptimize=ReleaseSafe` y `zig build` | correctos |
| Pruebas de estrés del GC (unitarias, umbral 128 B) | 100.000 concatenaciones/listas/diccionarios/`texto()`: 33.335 recolecciones, máximo 2.779 B contados; cadena viva de 100.000 bytes: 99.734 recolecciones; métodos, recursión, errores y promesas: 100.003 recolecciones; textos derivados, `para` con mutación, recursión profunda, ciclos de 10.000 listas y fallos de asignación: correctas |
| `zig build diferencial` | 42 aprobadas, 0 fallidas, 9 excluidas (17 casos; incluye `gc-estres`, 200.000 iteraciones desde la CLI) |
| `pruebas/limites.ps1` | 14 comprobaciones |
| `pruebas/cli.ps1` | 76 comprobaciones |
| `pruebas/modulos.ps1` | 44 comprobaciones |
| `pruebas/compilar.ps1` | 18 comprobaciones |
| `pruebas/propio.ps1` (PATH vaciado: sin Zig) | 74 comprobaciones, incluida la reproducibilidad byte a byte |
| ASLR (manual) | El ejecutable propio se carga en `0x7FF6817A0000`, no en la base preferida `0x140000000` |

Las 9 exclusiones de la diferencial son casos que declaran un subconjunto de
motores (`colecciones`, `errores-modelo` y `gc-estres` solo intérprete;
decimales, comparaciones mixtas y `texto()` sin backend propio).

**No verificado en esta máquina:** Linux (lo ejecutará la CI con pwsh y la
diferencial intérprete/C), PowerShell 7 y el tope de respuesta de `red` contra
un servidor real (la validación de cabeceras sí tiene prueba unitaria).

## Fallos encontrados durante la verificación y corregidos

- GC: el índice de objetos y la pila de marcado se contaban como heap vivo y
  el umbral geométrico se disparaba (25 recolecciones, 26 MB). Ahora se
  reservan fuera del conteo (`a35608d`).
- Pruebas: `0.1 + 0.2` evaluado en comptime; una prueba de la IR corrompida al
  escribirla; una función auxiliar que reasignaba la `i` global (`a35608d`,
  `ce53d17`).
- Scripts: incompatibilidades con PowerShell 5.1 (codificación, `ArgumentList`),
  compilaciones repetidas sin `--sobrescribir` y un here-string sin salto final
  (`8e99964`).

## Decisiones pendientes

Ver la tabla de AUDITORIA.md (estado «Decisión pendiente») y las propuestas de
memoria nativa, ELF/Linux y red/TLS.
