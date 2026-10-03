# IR de Alma y backend propio Windows x64

Estado: experimental, 2026-10-02. Implementación: `ir.zig`, `emision_c.zig`,
`runtime/escalar.h` y `codegen_pe.zig`.

## Uso

```powershell
alma ir programa.alma
alma compilar programa.alma --backend=propio
./programa.exe
```

`ir` muestra JSON versionado con funciones, registros, instrucciones y posiciones
de origen. El backend propio escribe directamente un PE32+ Windows x64: no genera C
ni ejecuta Zig, un ensamblador o un enlazador. Solo importa `GetStdHandle`, `WriteFile`
y `ExitProcess` de `KERNEL32.dll`, provista por Windows.

El compilador Alma actual se construye desde Zig. Esa dependencia de construcción
inicial no es necesaria en la máquina del usuario para usar `--backend=propio`.
El autohospedaje (compilador escrito en Alma) todavía está pendiente.

Sin opción, `alma compilar` conserva el backend C de arranque. También se puede elegir
explícitamente `--backend=c`; requiere `zig cc`. No hay cambio automático de backend:
el propio rechaza lo que todavía no soporta antes de escribir el ejecutable.

## Subconjunto del backend propio

- Enteros `i64`, lógicos y nulo; textos literales UTF-8, sus copias y su igualdad.
- Operadores enteros comprobados, comparaciones y operadores lógicos con cortocircuito.
- Variables, `si`, `mientras`, `romper`, `continuar`, funciones y recursión.
- Funciones importadas de archivos Alma y `imprimir` con múltiples argumentos.
- Evaluación de izquierda a derecha, detección de variables sin inicializar y salida
  inmediata. Los errores se escriben a stderr y terminan con código 1.

No admite decimales, conversión `texto(...)`, concatenación dinámica, colecciones,
objetos, biblioteca estándar, captura de errores ni concurrencia. La inferencia
conservadora de tipos detecta concatenaciones posibles también entre funciones.
Los marcos de función están limitados a 4096 bytes en esta versión. La compilación
puede rechazar programas con muchas expresiones hasta implementar reutilización de
registros y soporte de marcos mayores.

Los errores del backend propio aún no incluyen archivo y línea. El backend C y el
intérprete sí conservan esa información al cargar módulos. Los ejecutables propios
usan base fija (sin relocaciones/ASLR); el formato y ABI internos son experimentales.

## Representación intermedia

El AST validado se transforma en una IR que posee sus nombres y literales, sin
punteros al parser ni fragmentos de C. Cada función declara parámetros, registros e
instrucciones. Las instrucciones incluyen literales, copias, liberaciones, operaciones,
llamadas, etiquetas, saltos condicionales y retorno.

Cada registro posee su valor. Las operaciones leen valores prestados y producen un
resultado propio. Las copias conservan las referencias necesarias; las liberaciones
se emiten después del último uso temporal. Un retorno conserva su resultado y limpia
el marco. Los parámetros se retienen al entrar a la función.

El backend C implementa este contrato con conteo de referencias para textos dinámicos.
Libera temporales, valores reemplazados y registros al salir, incluso en retornos
anticipados. Los literales no necesitan liberación. Esto no implementa aún ARC para
objetos o colecciones, ni cambia la arena del intérprete.

El backend propio usa registros etiquetados en stack y textos literales estáticos;
su subconjunto actual no necesita reservar memoria dinámica durante la ejecución.

## Comprobaciones

Desde `compilador`, después de construir Alma:

```powershell
zig build test
./pruebas-cli.ps1
./pruebas-propio.ps1
```

Las pruebas CLI comparan interpretación y C y recompilan casos de texto con
`ALMA_VERIFICAR_MEMORIA` y `ALMA_LIMITE_TEXTOS=32`. Comprueban ausencia de textos vivos
al terminar y que 2000 iteraciones no retengan textos descartados. No son un benchmark
general ni sustituyen pruebas de otros tipos que aún no se compilan.

Las pruebas del backend propio vacían el PATH de herramientas externas durante la
compilación y ejecución; comprueban resultados, errores, módulos y reproducibilidad
binaria. Las unitarias revisan cabeceras PE, importaciones, directorio de unwind y
liberación de recursos ante fallos de asignación del compilador.

Referencias de plataforma: [formato PE de Microsoft](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format)
y [convención x64](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention).
