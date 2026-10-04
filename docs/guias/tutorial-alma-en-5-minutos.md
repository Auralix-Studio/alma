# Alma en 5 minutos

Un recorrido rápido por el lenguaje **Alma**. Cada bloque de código se puede guardar en
un archivo `.alma` y ejecutar con `alma ejecutar archivo.alma`.

> **Regla de oro:** los bloques se abren por indentación y se cierran con `fin`. No hay
> punto y coma. Los comentarios empiezan con `//`.

---

## 1. Hola, mundo

```alma
funcion principal()
    imprimir("Hola, mundo")
fin
```

`principal()` es el punto de entrada: si existe, Alma la ejecuta automáticamente.

---

## 2. Variables y tipos

Alma tiene **tipado gradual**: podés dejar que infiera el tipo o anotarlo.

```alma
nombre = "Auralix"        // texto (inferido)
edad: entero = 22         // tipo anotado
precio: decimal = 19.99
activo: logico = verdadero
fijo version = "1.0.0"    // 'fijo' = constante
```

Tipos básicos: `entero`, `decimal`, `texto`, `logico`, `nulo`.

---

## 3. Control de flujo

```alma
funcion principal()
    puntos = 85

    si puntos >= 90
        imprimir("Experto")
    sino si puntos >= 70
        imprimir("Intermedio")
    sino
        imprimir("Novato")
    fin

    i = 1
    mientras i <= 3
        imprimir(i)
        i = i + 1
    fin
fin
```

Los operadores lógicos son símbolos: `&&` (y), `||` (o), `!` (no). Las comparaciones:
`==`, `!=`, `<`, `>`, `<=`, `>=`.

---

## 4. Funciones

```alma
funcion sumar(a: entero, b: entero) -> entero
    retornar a + b
fin

funcion principal()
    imprimir(sumar(2, 3))    // 5
fin
```

Y por supuesto, recursión:

```alma
funcion factorial(n: entero) -> entero
    si n <= 1
        retornar 1
    sino
        retornar n * factorial(n - 1)
    fin
fin
```

---

## 5. Listas

```alma
funcion principal()
    numeros = [10, 20, 30]
    imprimir(numeros[0])          // 10
    agregar(numeros, 40)
    imprimir(longitud(numeros))   // 4

    total = 0
    para n en numeros
        total = total + n
    fin
    imprimir(total)               // 100

    // rango(n) genera [0, 1, …, n-1]
    para i en rango(3)
        imprimir(i)               // 0, 1, 2
    fin
fin
```

---

## 6. Diccionarios

```alma
funcion principal()
    inventario = {"manzanas": 5, "peras": 3}
    imprimir(inventario["peras"])        // 3

    inventario["uvas"] = 12              // agregar una clave
    imprimir(tiene(inventario, "uvas"))  // verdadero

    para fruta en inventario
        imprimir(fruta + ": " + texto(inventario[fruta]))
    fin
fin
```

`texto(valor)` convierte cualquier valor a su representación textual.

---

## 7. El corazón de Alma: `estructura` vs `modelo`

Esta es la característica diferenciadora. Decide cómo se comporta un tipo al copiarlo:

- **`estructura`** → tipo **por valor**: al asignarlo, se **copia**. Ideal para datos como
  vectores, puntos, matemáticas.
- **`modelo`** → tipo **por referencia**: al asignarlo, se **comparte**. Ideal para lógica de
  negocio: usuarios, servidores, conexiones.

```alma
estructura Punto
    x: entero
    y: entero
fin

modelo Caja
    valor: entero
fin

funcion principal()
    // estructura = VALOR (se copia)
    a = Punto(1, 2)
    b = a
    b.x = 99
    imprimir(a.x)   // 1  — 'a' NO cambió

    // modelo = REFERENCIA (se comparte)
    c = Caja(1)
    d = c
    d.valor = 99
    imprimir(c.valor)   // 99  — 'c' SÍ cambió
fin
```

Se construyen llamando al tipo con los campos en orden: `Punto(1, 2)`. Los campos se leen
y escriben con punto: `a.x`, `b.x = 99`.

---

## 8. Métodos

Los `modelo` pueden tener métodos. Dentro de un método, los nombres de campo se refieren a
la instancia (self implícito); `yo` es el self explícito.

```alma
modelo Servidor
    host: texto
    puerto: entero

    funcion iniciar(h: texto, p: entero)
        host = h            // asigna el campo de la instancia
        puerto = p
    fin

    funcion descripcion() -> texto
        retornar host + ":" + texto(puerto)
    fin
fin

funcion principal()
    s = Servidor("", 0)
    s.iniciar("localhost", 8080)
    imprimir(s.descripcion())   // localhost:8080
fin
```

---

## 9. Manejo de errores

```alma
funcion dividir(a: entero, b: entero) -> entero
    si b == 0
        lanzar error("no se puede dividir entre cero")
    fin
    retornar a / b
fin

funcion principal()
    intentar
        imprimir(dividir(10, 2))   // 5
        imprimir(dividir(7, 0))    // lanza un error
    capturar (e)
        imprimir("Error: " + e.mensaje)
    fin
    imprimir("El programa continúa")
fin
```

`intentar` también atrapa errores del propio lenguaje (índice fuera de rango, clave
inexistente, etc.). El error atrapado expone `.mensaje`.

---

## 10. Ejecutar tus programas

Guardá cualquier ejemplo en un archivo, por ejemplo `mi_programa.alma`, y corré:

```bash
alma ejecutar mi_programa.alma
```

Durante el desarrollo del compilador (desde `compilador/`):

```bash
zig build run -- ejecutar ../ruta/a/mi_programa.alma
```

Para inspeccionar cómo ve Alma tu código:

```bash
alma tokens mi_programa.alma    # el flujo de tokens
alma ast    mi_programa.alma    # el árbol de sintaxis
```

---

¡Eso es Alma! Para más detalle, mirá la
[especificación](../especificacion/01-lexico-y-tokens.md) y la
[gramática](../especificacion/02-gramatica.md).
