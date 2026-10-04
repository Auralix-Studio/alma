# Alma — Librería Estándar

> **Documento:** `05-libreria-estandar.md`
> **Componente:** Runtime · Módulos de la librería estándar
> **Estado:** Borrador de trabajo `v0.1`
> **Fuente de verdad para:** `compilador/src/ejecucion/interprete.zig`

Los módulos se traen con `importar <nombre>` (sin `desde`) y se usan con notación de punto:

```alma
importar matematicas
imprimir(matematicas.raiz(2.0))   // 1.4142135623730951
```

## Funciones globales (siempre disponibles, sin importar)
`imprimir`, `texto(v)` (a texto), `longitud(x)`, `rango(n)`/`rango(a,b)`, `agregar(lista, v)`,
`claves(dicc)`, `tiene(dicc, clave)`, `error(mensaje)`.

## `matematicas`
| Miembro | Descripción |
|---|---|
| `PI`, `E` | constantes |
| `raiz(x)` | raíz cuadrada |
| `potencia(base, exp)` | potencia |
| `absoluto(x)` | valor absoluto (conserva entero/decimal); `absoluto` del mínimo i64 desborda |
| `piso(x)`, `techo(x)`, `redondear(x)` | → entero; NaN, infinito o fuera de i64 es un error capturable |
| `minimo(a, b)`, `maximo(a, b)` | menor / mayor |
| `aleatorio()` | decimal en [0, 1) |

## `cadena` (operaciones de texto)
| Miembro | Descripción |
|---|---|
| `dividir(texto, sep)` | → lista de texto |
| `unir(lista, sep)` | lista de texto → texto |
| `reemplazar(texto, viejo, nuevo)` | reemplaza todas las ocurrencias |
| `mayusculas(texto)`, `minusculas(texto)` | (ASCII) |
| `contiene(texto, sub)` | → logico |
| `recortar(texto)` | quita espacios de los extremos |
| `empieza_con(texto, pre)`, `termina_con(texto, suf)` | → logico |

## `sistema` (entrada/salida)
| Miembro | Descripción |
|---|---|
| `leer_archivo(ruta)` | → texto con el contenido |
| `escribir_archivo(ruta, contenido)` | escribe el archivo |
| `existe(ruta)` | → logico |
| `salir()` / `salir(codigo)` | termina el programa; `codigo` entero entre 0 y 255 |

Las rutas son relativas al directorio de trabajo. Requiere E/S (disponible en `alma ejecutar`).
`leer_archivo` rechaza archivos mayores que el tope de lectura (100 MB por defecto,
`alma ejecutar archivo.alma --limite-lectura=BYTES`). `escribir_archivo` no tiene
sandbox: puede escribir cualquier ruta accesible para el usuario.

## `json`
| Miembro | Descripción |
|---|---|
| `analizar(texto)` | JSON → valor Alma (diccionario/lista/número/texto/logico/nulo) |
| `serializar(valor)` | valor Alma → texto JSON |

`analizar` admite hasta 64 contenedores abiertos, contando conjuntamente objetos
y arreglos. Los escalares no suman profundidad. Entrar en el contenedor 65
produce el error capturable `JSON inválido: límite de anidamiento excedido`.
El contador se restaura al salir, también en errores. `serializar` (y `imprimir`/
`texto`) rechazan más de 64 niveles de anidamiento, lo que también cubre ciclos
(`agregar(l, l)`), con un error capturable.

`analizar` admite los escapes `\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t` y `\uXXXX` (con pares
sustitutos, convertidos a UTF-8); otro escape es `JSON inválido`. Un número sin
punto ni exponente se lee como entero si cabe en i64 (`-0` se lee como decimal
para conservar su signo). `serializar` escapa los bytes de control como `\u00XX`,
escribe los decimales con el formato canónico de
[la propuesta numérica](../propuestas/PROPUESTA-NUMEROS.md) y rechaza `nan`/`inf`.

## `red` (cliente HTTP/HTTPS)
| Miembro | Descripción |
|---|---|
| `obtener(url)` / `obtener(url, cabeceras)` | GET; devuelve `{estado, ok, cuerpo}` |
| `publicar(url, cuerpo)` / `publicar(url, cuerpo, cabeceras)` | POST; devuelve `{estado, ok, cuerpo}` |

`cabeceras` es un diccionario `nombre → valor` (p. ej. `{"Content-Type": "…", "User-Agent": "…"}`).
Sin cabeceras, `publicar` usa `content-type: application/json`.

La respuesta es un diccionario: `estado` (entero, p.ej. 200), `ok` (logico, 2xx),
`cuerpo` (texto). Soporta HTTPS con verificación de certificados del sistema. Combina bien
con `json.analizar(respuesta["cuerpo"])`.

Límites: el cuerpo de la respuesta se acota a 50 MB (`--limite-red=BYTES`); superarlo
es un error capturable. Nombres de cabecera vacíos o con `:`, y nombres o valores con
CR/LF, se rechazan (evita inyección de cabeceras). **No hay timeout** todavía: ver
[la propuesta de red](../propuestas/PROPUESTA-RED-TLS.md). `codificar_url(texto)` codifica todo
byte fuera de `A-Z a-z 0-9 - _ . ~` como `%XX`.

## Representación de módulos
Un módulo importado es un valor de tipo *módulo*: un espacio de nombres con sus miembros
(funciones y constantes). `matematicas.raiz` resuelve el miembro `raiz`; llamarlo lo ejecuta.

## Diferido
`tiempo`/`fecha`, argumentos de línea de comandos, variables de entorno, y más operaciones
de `sistema`; en `red`, timeout y otros métodos (PUT/DELETE). `cadena`
transforma mayúsculas/minúsculas solo en ASCII (Unicode completo pendiente).
