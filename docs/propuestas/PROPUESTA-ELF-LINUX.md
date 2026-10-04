# Backend propio para Linux x86-64 (ELF) — decisión pendiente

Fecha: 2026-10-03. Propuesta; **no implementada**. Etapa D3 de la
[hoja de ruta](../planes/HOJA-DE-RUTA.md).

## Objetivo

`alma compilar --backend=propio` en Linux x86-64 produce un ejecutable ELF64
estático que no depende de libc, del enlazador dinámico ni de herramientas
externas, con la misma IR, el mismo código de funciones y la misma semántica que
el backend PE (validada por `zig build diferencial`).

## Qué se reutiliza

Todo el código de funciones de `codegen_pe.zig` es independiente del sistema:
ranuras etiquetadas, aritmética comprobada, comparaciones, llamadas internas
(convención propia: `rcx` apunta al área de argumentos), límite de llamadas y
búfer de salida. Solo cambian tres primitivas y el contenedor:

| Primitiva | Windows (hoy) | Linux (propuesta) |
|---|---|---|
| escribir(fd, datos, n) | `GetStdHandle` + `WriteFile` | `syscall` 1 (`write`), reintentando escrituras parciales y `EINTR` |
| salir(código) | `ExitProcess` | `syscall` 231 (`exit_group`) |
| reservar/liberar (futuro heap) | `HeapAlloc`/`HeapFree` | `syscall` 9/11 (`mmap`/`munmap`) |

Se propone separar `codegen_pe.zig` en `codegen_x64.zig` (funciones y runtime
común, parametrizado por una interfaz de plataforma) y dos contenedores:
`contenedor_pe.zig` y `contenedor_elf.zig`.

## Alternativas de formato

| Opción | Coste | Ventajas | Inconvenientes |
|---|---|---|---|
| (a) `ET_EXEC` estático en dirección fija | Bajo: cabecera ELF + 3 `PT_LOAD` + `PT_GNU_STACK` | Lo más simple | Sin ASLR |
| (b) `ET_DYN` estático sin `PT_INTERP` (static-pie) | Bajo-medio: igual que (a) con direcciones relativas a 0 | ASLR del kernel; el código ya es 100 % relativo a RIP, así que no necesita reubicaciones dinámicas | Requiere kernel ≥ 4.x para cargar static-pie sin intérprete (cualquier distribución actual) |
| (c) Enlazar dinámicamente con libc | Alto | `printf`/`strtod` disponibles | Dependencia de glibc/musl y del enlazador dinámico: contradice el objetivo |

**Recomendación: (b).** Segmentos: texto (R-X), datos de solo lectura (R--),
datos (RW-), con `p_align` 4096 y `PT_GNU_STACK` sin ejecución. Sin tablas de
desenrollado obligatorias (Linux no las exige para terminar); `.eh_frame`
opcional más adelante para depuradores. Sin sondeo de páginas: el kernel hace
crecer la pila; los marcos siguen limitados a 128 KiB por coherencia.

## Pruebas y aceptación

- Unitarias: cabecera ELF (`e_type`, `e_machine`, segmentos alineados, sin
  `PT_INTERP`, sin `PT_DYNAMIC`), determinismo byte a byte.
- `zig build diferencial` en Linux ejecuta también los casos `propio`.
- Un script que ejecute el binario con `PATH` vacío y `ldd` informando
  «not a dynamic executable».

## Riesgos

- Dos contenedores que mantener: la separación propuesta los aísla.
- Diferencias de E/S (escrituras parciales en tuberías): cubrir con una prueba
  de salida mayor que el búfer de una tubería.

## Decisión solicitada

Aprobar (b) y la separación `codegen_x64` + contenedores. No se implementa sin
aprobación.
