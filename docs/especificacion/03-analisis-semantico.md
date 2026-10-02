# Alma — Análisis Semántico

> **Documento:** `03-analisis-semantico.md`
> **Componente:** Compilador · Front-end · Etapa 3 (Análisis Semántico)
> **Estado:** Borrador de trabajo `v0.1`
> **Fuente de verdad para:** `compilador/src/semantica/analizador.zig`
> **Comando:** `alma analizar <archivo.alma>`; también obligatorio en `ejecutar` y `compilar`.

El analizador recorre el AST y reporta errores **antes de ejecutar**, mediante
**resolución de nombres** con una pila de ámbitos.

## Modelo de ámbitos

- Coherente con el intérprete, el alcance de las variables es **a nivel de función**:
  los bloques (`si`, `mientras`, `para`, `intentar`) **no** crean un ámbito nuevo.
- Solo crean ámbito nuevo las **funciones** y los **métodos**.
- Las **funciones y tipos de nivel superior se registran primero** (pase 1), de modo que
  la recursión y las referencias hacia adelante funcionan (recursión mutua incluida).
- Las **variables locales no se elevan** (hoisting): se resuelven en orden de aparición,
  igual que las ejecuta el intérprete. Usar una variable antes de asignarla es un error.
- Dentro de un **método**, los nombres de los campos del tipo son visibles (self implícito),
  además de `yo`.

## Comprobaciones (v0.1)

| Comprobación | Ejemplo que la dispara |
|---|---|
| **Nombre no definido** | `imprimir(desconocido)` |
| **Aridad de función** | `sumar(1)` cuando `sumar` toma 2 |
| **Aridad de constructor** | `Punto(1)` cuando `Punto` tiene 2 campos |
| **`retornar` fuera de función** | `retornar 5` en el nivel superior |
| **`romper`/`continuar` fuera de bucle** | `romper` sin un `mientras`/`para` |
| **Reasignar una constante** | `fijo x = 1` seguido de `x = 2` |
| **Redefinición** | dos `funcion f()` de nivel superior |
| **Campo/parámetro duplicado** | `estructura P` con dos campos `x` |

### Chequeo de tipos (gradual)
Solo se comprueban tipos donde el programa los **anota** (parámetros `: tipo`, retorno
`-> tipo`, declaraciones `x: tipo = …`, campos, y constantes `fijo`). Sin anotación el tipo
es `desconocido` y **nunca** produce error — así el código dinámico no genera falsos positivos.

| Comprobación de tipo | Ejemplo que la dispara |
|---|---|
| **Asignar tipo incompatible** | `edad: entero = "hola"` |
| **Argumento de tipo incorrecto** | `saludar(42)` si `saludar(nombre: texto)` |
| **Retorno de tipo incorrecto** | `-> entero` con `retornar "x"` |
| **Operador con tipo inválido** | `"a" - 1`, `si 5`, `texto && logico` |

`entero` y `decimal` se consideran compatibles entre sí (ambos números).

Las funciones de la librería estándar (`imprimir`, `rango`, `longitud`, `agregar`,
`texto`, `claves`, `tiene`, `error`) se registran como nativas y no se comprueba su aridad
ni sus tipos.

## Salida

`alma analizar` imprime cada diagnóstico como `archivo:línea:columna: mensaje` y un
resumen; si no hay problemas, imprime `Sin problemas.` Las posiciones son **a nivel de
sentencia** (línea de la sentencia y su columna de inicio): cada nodo del AST lleva su
posición (`ast.Pos`). El intérprete usa el mismo mecanismo para los errores de ejecución.

## Diferido a versiones posteriores

- **Columna exacta por token** (p. ej. señalar el argumento concreto, no el inicio de la
  sentencia) — requiere propagar posiciones también a los nodos de expresión.
- **Tipos más finos**: acceso a campos según el tipo de la instancia, elementos de listas,
  e inferencia del tipo de variables sin anotar a partir de su primer valor.
- Detección de **código inalcanzable** y variables sin uso.
