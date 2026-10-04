# Aprende Alma — plan de una aplicación de aprendizaje estilo Mimo

Fecha: 2026-10-03. Estado: **plan; nada implementado**. Las decisiones marcadas
como pendientes necesitan aprobación antes de empezar la fase correspondiente.

## 1. Qué es

Una aplicación para aprender a programar **en español con Alma**: lecciones
cortas (3–5 minutos), ejercicios interactivos que ejecutan código Alma real,
progreso por caminos de aprendizaje y gamificación (rachas, XP, logros), como
Mimo. La ventaja diferencial frente a Mimo y similares: el lenguaje, los
mensajes de error y las palabras clave están en español, así que el principiante
no aprende inglés y programación a la vez.

Público inicial: hispanohablantes sin experiencia (14+ años), en móvil y web.

## 2. Qué puede y qué no puede hacer Alma hoy (condiciona la arquitectura)

| Necesidad de la app | Estado en Alma | Consecuencia |
|---|---|---|
| Ejecutar los ejercicios del alumno | El intérprete cubre el lenguaje v0.1 completo, con GC y límites | Es el motor de ejecución de la app |
| Interfaz gráfica, servidor web, base de datos | **No existen** en Alma (`red` solo es cliente HTTP) | La aplicación (interfaz y servicios) se escribe en otra tecnología |
| Ejecutar en el dispositivo sin servidor | El intérprete está en Zig; Zig compila a WebAssembly | Compilar el intérprete a `alma.wasm` |
| Cortar bucles infinitos del alumno | Hay límite de llamadas, pero **no de pasos ni de tiempo** | Añadir un presupuesto de pasos y de memoria al intérprete |
| Programas que leen datos del usuario | **No hay entrada** (`leer`) | Las lecciones se basan en la salida; la entrada sería una propuesta nueva del lenguaje |
| Mensajes de error con posición | Sí: `archivo:línea:columna` en español | Se muestran en el editor sobre la línea del error |
| Verificar la *forma* de una solución («usá `mientras`») | `alma ast` produce el AST | Exponer el AST en la API del motor |

Conclusión: **Alma es el contenido y el motor de ejecución; la aplicación se
construye alrededor.** Los ejercicios corren en el dispositivo, sin servidor,
dentro del sandbox de WebAssembly.

## 3. Arquitectura propuesta

```
┌────────────────────────────── App (PWA; luego tiendas con Capacitor) ─────┐
│  Interfaz: TypeScript + framework web     Editor: CodeMirror 6 + gramática │
│  Lecciones / ejercicios / progreso        de Alma (desde editores/vscode-   │
│  Almacenamiento local (IndexedDB)         alma) + barra de tokens táctil    │
│                    │                                                        │
│                    ▼  Web Worker (no bloquea la interfaz)                   │
│        alma.wasm  ── ejecutar(fuente, límites) → {salida, error, ast}       │
└────────────────────────────────────────────────────────────────────────────┘
          ▲ contenido versionado (JSON/Markdown + .alma + .salida)
          │ validado en CI contra el intérprete nativo
┌─────────┴──────────────┐        ┌──────────────────────────────────────┐
│ Repo alma: motor wasm,  │        │ Servicio opcional (fase 2): cuentas, │
│ cursos y su validación  │        │ sincronización, rankings              │
└─────────────────────────┘        └──────────────────────────────────────┘
```

### 3.1 Motor `alma.wasm` (en este repositorio)

- Nuevo destino de construcción `zig build wasm` que compile el intérprete a
  `wasm32-wasi` (o `wasm32-freestanding`) **sin** los módulos `red` y `sistema`
  (exclusión en tiempo de compilación; hoy dependen de `std.Io` y `std.http`).
- API mínima exportada, con entrada y salida en JSON:
  `ejecutar(fuente, {max_pasos, max_bytes, semilla})` →
  `{salida, codigo, error: {mensaje, linea, columna}?, pasos}`; `ast(fuente)`.
- **Presupuesto de pasos**: contador en `puntoSeguro` (ya existe en cada
  sentencia y cabeza de bucle) → error «el programa tardó demasiado». Esto
  también es útil en la CLI (`--limite-pasos`).
- **Tope de memoria**: `memoria_gc` ya cuenta los bytes; superar el tope es
  un error de Alma.
- `matematicas.aleatorio` con semilla fija para que los ejercicios sean
  reproducibles.
- Prueba en CI: ejecutar la batería diferencial del intérprete también sobre
  `alma.wasm` (con Node o `wasmtime`), para garantizar que la app enseña el
  mismo lenguaje que la CLI.

### 3.2 Contenido de los cursos (en este repositorio, versionado con el lenguaje)

```
cursos/fundamentos/
  curso.json                     título, orden de módulos, versión mínima de alma
  01-imprimir/leccion.md         explicación (Markdown corto, con ejemplos)
  01-imprimir/ejercicios.json    tipos, enunciados, opciones, pistas
  01-imprimir/sol-03.alma        solución de cada ejercicio de código
  01-imprimir/sol-03.salida      salida esperada en bytes (formato de pruebas/diferenciales)
```

Toda solución se ejecuta en CI con el intérprete; un curso que no pasa no se
publica. Al cambiar la semántica del lenguaje, la CI detecta qué lecciones
cambian.

### 3.3 Tipos de ejercicio

| Tipo | Ejemplo | Validación |
|---|---|---|
| Opción múltiple | «¿Qué imprime `imprimir(7 / 2)`?» | Respuesta fija, comprobada en CI ejecutando el código |
| Predecir la salida | Leer un programa y escribir lo que imprime | Comparar con la ejecución real |
| Completar huecos | `___ i < 10` → `mientras` (con barra de tokens) | Ejecutar y comparar la salida |
| Ordenar líneas | Reordenar un programa desordenado | Ejecutar y comparar la salida |
| Corregir el error | El programa no compila; el alumno lo arregla | Ejecuta sin error y con la salida esperada |
| Escribir código | «Imprimí los pares del 1 al 10» | Salida esperada + reglas sobre el AST opcionales |
| Proyecto | Varias lecciones construyen un programa | Casos de salida por etapa |

### 3.4 Aplicación (repositorio aparte, propuesta)

- PWA en TypeScript (framework a decidir), funciona sin conexión tras la primera
  carga, y empaquetada con Capacitor para Android/iOS en la fase 3.
- Pantallas: inicio y camino de aprendizaje, lección, ejercicio, resultado,
  zona de práctica libre («Playground»), perfil y logros.
- Progreso local en IndexedDB; sincronización opcional en la fase 2.
- Accesibilidad: tamaños de letra, contraste, lector de pantalla en lecciones.

## 4. Plan de estudios inicial (versión 1)

| # | Módulo | Contenido de Alma | Proyecto de cierre |
|---|---|---|---|
| 1 | Primeros pasos | `imprimir`, textos, comentarios, `principal()` | Tarjeta de presentación |
| 2 | Datos | variables, `fijo`, `entero`, `decimal`, `logico`, `nulo`, `texto()` | Calculadora de propinas |
| 3 | Operaciones | aritmética, división entera y resto, comparaciones, `&&` `||` `!` | ¿Es año bisiesto? |
| 4 | Decisiones | `si` / `sino si` / `sino` | Clasificador de notas |
| 5 | Repetición | `mientras`, `romper`, `continuar`, `para` + `rango` | Tabla de multiplicar |
| 6 | Funciones | parámetros, `retornar`, tipos anotados, recursión | Factorial y Fibonacci |
| 7 | Colecciones | listas, `agregar`, `longitud`, diccionarios, `claves`, `tiene` | Lista de compras |
| 8 | Texto | `cadena.*`, concatenación | Contador de palabras |
| 9 | Tipos propios | `estructura` (valor) vs `modelo` (referencia), métodos, `yo` | Cuenta bancaria |
| 10 | Errores | `intentar` / `capturar` / `lanzar` | Cuenta bancaria robusta |
| 11 | Módulos | `importar … desde`, `exportar` | Proyecto en dos archivos |

Unas 8 lecciones por módulo y 5–7 ejercicios por lección (≈ 90 lecciones).
`red`, `sistema` y async quedan fuera de la versión 1 (no corren en el
navegador o son síncronos).

## 5. Fases y criterios de aceptación

| Fase | Entregables | Criterio de aceptación | Depende de |
|---|---|---|---|
| **0. Requisitos del lenguaje** | Decisiones de semántica abiertas (igualdad de referencias, orden en `x[i] = v`, escapes desconocidos); presupuesto de pasos y de memoria; `zig build wasm` con API JSON; validador de cursos en CI | La batería diferencial pasa igual en `alma.wasm` y en la CLI; un bucle infinito termina con error en < 1 s | Tus decisiones de la §8 |
| **1. MVP web** | Módulos 1–5, cinco tipos de ejercicio, práctica libre, progreso local, sin conexión | 100 % de las soluciones validadas en CI; ejecución de un ejercicio < 100 ms (p95) en un móvil de gama media; prueba con 10–20 principiantes | 0 |
| **2. Retención** | Módulos 6–9, XP, rachas, logros, recordatorios; cuentas y sincronización opcionales | Tasa de finalización de la lección 1→5 medida; sin pérdida de progreso al cambiar de dispositivo | 1 |
| **3. Tiendas** | Apps Android/iOS (Capacitor), notificaciones, módulos 10–11 | Publicación en tiendas; funciona sin conexión | 2 |
| **4. Avanzado** | Proyectos guiados, certificados, contenido de la comunidad, pistas asistidas | A definir con datos de uso | 3 |

## 6. Riesgos

| Riesgo | Mitigación |
|---|---|
| `std.http`/`std.Io` no compilan para wasm | Excluir `red` y `sistema` en tiempo de compilación en el destino wasm |
| El lenguaje cambia y rompe lecciones | Cursos versionados con «alma mínima» y validados en CI contra el intérprete |
| Bucles infinitos o consumo de memoria del alumno | Presupuesto de pasos y de bytes; ejecución en un Web Worker que se puede terminar |
| Mensajes de error demasiado técnicos para principiantes | Capa de pistas por código de error en la app (sin cambiar el compilador) |
| Igualdad de referencias e identidad todavía sin definir | Decidirlas antes de escribir el módulo 9 |
| Sin entrada de usuario (`leer`) | Lecciones basadas en salida; proponer `leer` aparte si hace falta |
| Vocabulario técnico inconsistente entre lecciones | Glosario único en el repositorio de cursos |

## 7. Lugar de cada cosa

| Pieza | Dónde | Por qué |
|---|---|---|
| Motor `alma.wasm`, presupuesto de pasos | `compilador/` (este repo) | Va con la versión del lenguaje |
| Cursos y su validador | `cursos/` (este repo) | Se prueban contra el intérprete en cada cambio |
| Aplicación (interfaz, servicios) | Repositorio nuevo | Otra cadena de herramientas (TypeScript); ritmo de publicación propio |

## 8. Decisiones que necesito de ti

1. **Confirmar el enfoque:** app para *aprender Alma*, con la interfaz en otra
   tecnología y Alma como motor (lo que propone este plan). Alternativa: esperar
   a que Alma tenga capacidades de interfaz o servidor, que hoy no existen.
2. **Plataforma inicial:** PWA web primero y tiendas después (recomendado), o
   apps nativas desde el principio.
3. **Cuentas y sincronización:** solo progreso local en el MVP (recomendado), o
   servicio de cuentas desde el inicio (y con qué proveedor).
4. **Las tres decisiones de semántica abiertas** (auditoría): bloquean los
   módulos 7 y 9.
5. **Nombre y modelo de negocio** (gratuito, freemium como Mimo, educativo).
