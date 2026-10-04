# Alma — Especificación Léxica y Catálogo de Tokens

> **Documento:** `01-lexico-y-tokens.md`
> **Componente:** Compilador · Front-end · Etapa 1 (Lexer / Analizador Léxico)
> **Estado:** Borrador de trabajo `v0.1`
> **Fuente de verdad para:** `compilador/src/lexico/token.zig` y `compilador/src/lexico/lexer.zig`

Este documento define **todos** los tokens que el Lexer de Alma reconoce y las reglas
para producirlos a partir del texto fuente `.alma`. Es el contrato que implementa el
lexer y contra el que se escriben sus tests.

**Convención de origen:**
- 🟢 `[SPEC]` — definido explícitamente en la especificación original de Alma.
- 🟡 `[PROP]` — propuesto por diseño para llenar un hueco de la spec; **sujeto a tu confirmación**.

---

## 1. Modelo léxico general

Alma es un lenguaje de **indentación significativa** (regla del *off-side*) **con
terminador explícito `fin`**. Esto define el comportamiento central del lexer:

1. El lexer produce tokens de **estructura de línea**: `NUEVA_LINEA`, `SANGRIA`,
   `DESANGRIA`.
2. Un aumento de indentación abre un bloque (`SANGRIA`); una reducción lo cierra
   (`DESANGRIA`).
3. La palabra clave **`fin`** aparece **al nivel de indentación del bloque padre** y el
   *parser* la exige para cerrar cada constructo compuesto (`funcion`, `si`, `para`,
   `modelo`, etc.). No es redundante: el compilador **verifica** que `fin` coincida con
   la `DESANGRIA` correspondiente, y reporta error si no.

> **Por qué híbrido y no Python puro:** la indentación da legibilidad y estructura;
> `fin` da un cierre inequívoco que permite (a) mensajes de error precisos ante bloques
> mal cerrados, y (b) constructos multi-cláusula limpios (`si / o si / sino / fin`).

```alma
funcion sumar(a: entero, b: entero) -> entero
    retornar a + b
fin
```

Flujo de tokens (conceptual) para el ejemplo:

```
kw_funcion  ident(sumar)  paren_izq  ident(a)  dos_puntos  ident(entero)  coma
ident(b)  dos_puntos  ident(entero)  paren_der  flecha  ident(entero)  NUEVA_LINEA
SANGRIA
    kw_retornar  ident(a)  mas  ident(b)  NUEVA_LINEA
DESANGRIA
kw_fin  NUEVA_LINEA
FIN_DE_ARCHIVO
```

---

## 2. Codificación y caracteres

- El código fuente se interpreta como **UTF-8**.
- Fin de línea aceptado: `\n` (LF) y `\r\n` (CRLF). El lexer normaliza a un solo
  `NUEVA_LINEA` lógico. 🟡`[PROP]`
- El único carácter de indentación válido es el **espacio** (`U+0020`). El **tabulador
  (`\t`) es error léxico** dentro de la indentación de un renglón. 🟡`[PROP]`
  *(Evita la ambigüedad tabs/espacios de Python; concuerda con la spec "usar espacios".)*

---

## 3. Tokens de estructura de línea

### 3.1 `NUEVA_LINEA`
Marca el fin de una **línea lógica**. Se emite al encontrar `\n`/`\r\n` fuera de un
contexto de continuación (ver 3.4).

- Líneas **en blanco** y líneas que solo contienen un **comentario** no emiten
  `NUEVA_LINEA` ni afectan la indentación (se ignoran para el cálculo de bloques).
- Al llegar a `FIN_DE_ARCHIVO`, si el último token significativo no cerró la línea, se
  sintetiza un `NUEVA_LINEA` implícito.

### 3.2 `SANGRIA` / `DESANGRIA` — algoritmo de la pila de indentación
El lexer mantiene una **pila de niveles de indentación** (en columnas de espacios),
inicializada con `[0]`. Al inicio de cada línea lógica no vacía:

1. Se cuenta la indentación `n` (número de espacios iniciales).
2. Si `n > cima(pila)` → se emite **un** `SANGRIA` y se apila `n`.
3. Si `n < cima(pila)` → se desapila y se emite **un** `DESANGRIA` por cada nivel
   descartado, hasta que `cima(pila) == n`. Si nunca coincide → **error de
   indentación inconsistente**.
4. Si `n == cima(pila)` → no se emite nada.

- El **ancho** de indentación es flexible (la spec permite 2 o 4 espacios): cualquier
  aumento consistente abre bloque. Lo que se exige es **consistencia**: cada bloque más
  profundo que su padre, y cada cierre debe alinear con un nivel existente en la pila.
- 🟡`[PROP]` `alma formatear` / `alma analizar` imponen además el estilo canónico
  (4 espacios recomendado, o 2) como regla de *lint*, no de gramática.
- Al `FIN_DE_ARCHIVO` se emiten los `DESANGRIA` pendientes para cerrar la pila a `0`.

### 3.3 `FIN_DE_ARCHIVO`
Token final único. Emite antes los `NUEVA_LINEA`/`DESANGRIA` pendientes.

### 3.4 Unión implícita de líneas
Dentro de paréntesis `()`, corchetes `[]` o llaves `{}` **sin cerrar**, el lexer
**suprime** `NUEVA_LINEA`, `SANGRIA` y `DESANGRIA`. Esto permite literales y llamadas
multilínea sin colisionar con la indentación. 🟡`[PROP]`

```alma
resultado = sumar(
    valor_a,
    valor_b,
)
```

*(No se contempla continuación explícita con `\` al final de línea en `v0.1`.)*

---

## 4. Comentarios

| Sintaxis | Nombre | Origen | Notas |
|---|---|---|---|
| `// …` | Comentario de línea | 🟢`[SPEC]` | Hasta fin de línea. |
| `/// …` | Comentario de documentación | 🟡`[PROP]` | Alimenta `alma doc`. Precede a la declaración documentada. |
| `//! …` | Doc de módulo | 🟡`[PROP]` | Documenta el archivo/módulo actual. |
| `/* … */` | Comentario de bloque | 🟡`[PROP]` | Anidable. 🟡 |

Los comentarios **no** producen tokens para el parser (salvo que una fase de doc los
recolecte por separado).

---

## 5. Identificadores

- **Inicio:** una letra Unicode (categoría `L*`) o `_`.
- **Continuación:** letras Unicode, dígitos `0-9` o `_`.
- **Se permiten explícitamente** acentos y `ñ`/`Ñ` (`á é í ó ú ü`), coherente con un
  lenguaje en español: `cálculo`, `año`, `contraseña` son identificadores válidos.
  🟢`[SPEC]` *(filosofía)* / 🟡`[PROP]` *(regla Unicode formal)*
- **Distingue mayúsculas/minúsculas** (`Usuario` ≠ `usuario`).
- Token: `identificador` (con el lexema asociado).

---

## 6. Palabras clave (reservadas)

El lexer primero lee un identificador y luego consulta esta tabla; si coincide, emite el
token de palabra clave correspondiente en vez de `identificador`.

### 6.1 Declaración y módulos
| Lexema | Token | Origen | Significado |
|---|---|---|---|
| `funcion` | `kw_funcion` | 🟢`[SPEC]` | Declara función. |
| `retornar` | `kw_retornar` | 🟢`[SPEC]` | Retorno de valor. |
| `fijo` | `kw_fijo` | 🟢`[SPEC]` | Constante inmutable. |
| `estructura` | `kw_estructura` | 🟢`[SPEC]` | Tipo por valor (Stack). |
| `modelo` | `kw_modelo` | 🟢`[SPEC]` | Tipo por referencia (Heap, ARC). |
| `fin` | `kw_fin` | 🟢`[SPEC]` | Cierra bloque. |
| `exportar` | `kw_exportar` | 🟢`[SPEC]` | Expone símbolo del módulo. |
| `importar` | `kw_importar` | 🟢`[SPEC]` | Importa símbolo/módulo. |
| `desde` | `kw_desde` | 🟢`[SPEC]` | Ruta de importación (`importar X desde "…"`). |
| `externa` | `kw_externa` | 🟢`[SPEC]` | FFI (`externa "C" funcion …`). |

### 6.2 Control de flujo
| Lexema | Token | Origen | Significado |
|---|---|---|---|
| `si` | `kw_si` | 🟢`[SPEC]` | If. |
| `sino` | `kw_sino` | 🟢`[SPEC]` | Else (y else-if como `sino si`, ver §11). |
| `para` | `kw_para` | 🟢`[SPEC]` | For-each. |
| `en` | `kw_en` | 🟢`[SPEC]` | `para x en col`. |
| `mientras` | `kw_mientras` | 🟡`[PROP]` | While. |
| `romper` | `kw_romper` | 🟡`[PROP]` | Break. |
| `continuar` | `kw_continuar` | 🟡`[PROP]` | Continue. |

### 6.3 Concurrencia y errores
| Lexema | Token | Origen | Significado |
|---|---|---|---|
| `asincrona` | `kw_asincrona` | 🟢`[SPEC]` | Función asíncrona. |
| `esperar` | `kw_esperar` | 🟢`[SPEC]` | Await. |
| `hilo` | `kw_hilo` | 🟢`[SPEC]` | Lanza hilo nativo. |
| `intentar` | `kw_intentar` | 🟢`[SPEC]` | Try. |
| `capturar` | `kw_capturar` | 🟢`[SPEC]` | Catch. |

### 6.4 Operadores lógicos → símbolos (ver §9) ✅ decidido
AND / OR / NOT se escriben con los **símbolos** `&&` / `||` / `!`, **no** como palabras.
Por lo tanto `y`, `o` y `no` son **identificadores ordinarios** (habilita `Vector3D.y`).

### 6.5 Literales que son palabras clave
| Lexema | Token | Origen |
|---|---|---|
| `verdadero` | `lit_verdadero` | 🟢`[SPEC]` |
| `falso` | `lit_falso` | 🟢`[SPEC]` |
| `nulo` | `lit_nulo` | 🟡`[PROP]` |

> **Nota:** `imprimir` **no** es palabra clave — es una función de la librería estándar
> (`sistema`). Tokeniza como `identificador`.

---

## 7. Tipos primitivos predefinidos (no son palabras clave)

Se tratan como **identificadores predeclarados** por el compilador, no como tokens
reservados. Esto mantiene el conjunto de keywords pequeño y evita rigidez.

`entero` · `decimal` · `texto` · `logico` · `diccionario` — 🟢`[SPEC]`
🟡`[PROP]` a definir más adelante: `lista`, `byte`, enteros de ancho fijo (`entero32`,
`entero64`), `flotante32/64`, etc.

---

## 8. Literales

### 8.1 Enteros — `lit_entero`
- Decimal: `0`, `22`, `1000`. 🟢`[SPEC]`
- 🟡`[PROP]` Separador visual con `_`: `1_000_000`.
- 🟡`[PROP]` Bases: `0x1F` (hex), `0b1010` (binario), `0o17` (octal).

### 8.2 Decimales — `lit_decimal`
- `19.99`, `3.1416`. Requiere dígitos a ambos lados del punto. 🟢`[SPEC]`
- 🟡`[PROP]` Exponente: `1.5e3`, `2.0e-4`.

### 8.3 Texto — `lit_texto`
- Delimitado por comillas dobles: `"Auralix"`. 🟢`[SPEC]`
- Escapes 🟡`[PROP]`: `\n \t \r \\ \" \0`, Unicode `\u{1F600}`.
- La concatenación es con `+` (`"a: " + error.mensaje`) — **no** hay interpolación en
  `v0.1`. 🟡`[PROP]` (interpolación tipo `"Hola {nombre}"` queda como futura).
- 🟡`[PROP]` No hay tipo carácter separado; un carácter es un `texto` de longitud 1.

#### Propuesta de escapes v0.2 (2026-10-03)

**Implementado** (commit `5b0a5a5`): intérprete, IR (backends C y propio) y
pruebas comparten un único decodificador (`compilador/src/numeros.zig`) con
esta lista; `\0` produce un byte NUL que se conserva al imprimir, medir y
concatenar, y JSON lo serializa como `\u0000`. **Pendiente de confirmación:**
rechazar los escapes desconocidos; hoy todos los motores conservan el carácter y
descartan la barra (`"\q"` → `q`). `\u{...}` sigue diferido.

Lista cerrada:

| Escape | Bytes resultantes |
|---|---|
| `\n` | LF, `0A` |
| `\t` | tabulador, `09` |
| `\r` | CR, `0D` |
| `\\` | barra inversa, `5C` |
| `\"` | comilla doble, `22` |
| `\0` | NUL, `00` |

Rechazar un escape desconocido en el análisis léxico con archivo:línea:columna,
en vez de eliminar silenciosamente la barra. `\u{...}` continúa diferido y se
diagnostica como no soportado. Un NUL dentro de un texto cuenta como un byte;
impresión, longitud y concatenación deben conservarlo sin truncar el texto.
JSON usa su propia gramática de escapes: serializar NUL como `\u0000`, nunca
como `\0`. Aprobar esta propuesta antes de cambiar el comportamiento existente.
Véase también [la propuesta numérica](../propuestas/PROPUESTA-NUMEROS.md).

### 8.4 Lógicos y nulo
`verdadero` / `falso` (§6.5) · `nulo` 🟡`[PROP]`.

---

## 9. Operadores

| Lexema | Token | Origen | Uso |
|---|---|---|---|
| `+` | `mas` | 🟢`[SPEC]` | Suma / concatenación de texto. |
| `-` | `menos` | 🟢`[SPEC]` | Resta / negación unaria. |
| `*` | `por` | 🟢`[SPEC]` | Multiplicación. |
| `/` | `entre` | 🟢`[SPEC]` | División. |
| `%` | `modulo` | 🟡`[PROP]` | Módulo. |
| `=` | `asignar` | 🟢`[SPEC]` | Asignación. |
| `==` | `igual` | 🟡`[PROP]` | Igualdad. |
| `!=` | `distinto` | 🟡`[PROP]` | Desigualdad. |
| `<` | `menor` | 🟡`[PROP]` | Menor que. |
| `>` | `mayor` | 🟢`[SPEC]` | Mayor que (`>=` en ejemplos). |
| `<=` | `menor_igual` | 🟡`[PROP]` | Menor o igual. |
| `>=` | `mayor_igual` | 🟢`[SPEC]` | Mayor o igual. |
| `&&` | `y_logico` | ✅ decidido | AND lógico. |
| `\|\|` | `o_logico` | ✅ decidido | OR lógico. |
| `!` | `no_logico` | ✅ decidido | NOT lógico (unario). |
| `+=` `-=` `*=` `/=` | `mas_asignar` … | 🟡`[PROP]` | Asignación compuesta. |
| `->` | `flecha` | 🟢`[SPEC]` | Tipo de retorno de función. |
| `.` | `punto` | 🟢`[SPEC]` | Acceso a miembro (`obj.metodo`). |

---

## 10. Delimitadores

| Lexema | Token | Origen | Uso |
|---|---|---|---|
| `(` | `paren_izq` | 🟢`[SPEC]` | Agrupar / llamada / params. |
| `)` | `paren_der` | 🟢`[SPEC]` | — |
| `,` | `coma` | 🟢`[SPEC]` | Separador de argumentos/campos. |
| `:` | `dos_puntos` | 🟢`[SPEC]` | Anotación de tipo (`edad: entero`). |
| `[` | `corchete_izq` | 🟡`[PROP]` | Índices / literal de lista. |
| `]` | `corchete_der` | 🟡`[PROP]` | — |
| `{` | `llave_izq` | 🟡`[PROP]` | Literal de `diccionario`. |
| `}` | `llave_der` | 🟡`[PROP]` | — |

> Como los bloques usan indentación + `fin`, las llaves `{}` quedan libres para
> literales de datos (diccionarios), no para bloques.

---

## 11. Palabras clave contextuales y ambigüedades conocidas

- **Else-if = `sino si`** ✅: el else-if se escribe con los dos keywords existentes
  `sino si` (tokens `kw_sino` `kw_si`); el parser reconoce la secuencia. Se descartó
  `o si`/`osi` para no reservar la palabra `o`.
- **`y` / `o` / `no`** ✅: son identificadores ordinarios (los operadores lógicos son
  símbolos, §9), lo que mantiene libres nombres comunes como la coordenada `y`.
- **`en`:** solo tiene sentido dentro de `para … en …`; fuera de ahí es error de sintaxis
  (no de lexer).

---

## 12. Apéndice A — Enum `TipoToken` (previo a `token.zig`)

Representación propuesta para la implementación en Zig (nombres en español, `snake_case`):

```zig
pub const TipoToken = enum {
    // — Estructura de línea —
    nueva_linea, sangria, desangria, fin_de_archivo,

    // — Literales —
    identificador, lit_entero, lit_decimal, lit_texto,
    lit_verdadero, lit_falso, lit_nulo,

    // — Palabras clave: declaración y módulos —
    kw_funcion, kw_retornar, kw_fijo, kw_estructura, kw_modelo, kw_fin,
    kw_exportar, kw_importar, kw_desde, kw_externa,

    // — Palabras clave: control de flujo —
    kw_si, kw_sino, kw_para, kw_en, kw_mientras, kw_romper, kw_continuar,

    // — Palabras clave: concurrencia y errores —
    kw_asincrona, kw_esperar, kw_hilo, kw_intentar, kw_capturar,

    // — Operadores —
    mas, menos, por, entre, modulo,
    asignar, igual, distinto, menor, mayor, menor_igual, mayor_igual,
    y_logico, o_logico, no_logico,
    mas_asignar, menos_asignar, por_asignar, entre_asignar,
    flecha, punto,

    // — Delimitadores —
    paren_izq, paren_der, corchete_izq, corchete_der,
    llave_izq, llave_der, coma, dos_puntos,

    // — Error —
    invalido,
};
```

Cada `Token` llevará además: `lexema` (slice del fuente), `linea`, `columna` y offset,
para diagnósticos y para el LSP.

---

## 13. Pendientes / preguntas abiertas

**Resueltas (2026-07-26):**
- ✅ Operadores lógicos = símbolos `&&` / `||` / `!`; `y`/`o`/`no` quedan libres como identificadores.
- ✅ Else-if = `sino si` (descartados `o si` / `osi`).
- ✅ **Modelo híbrido** confirmado: indentación significativa **+** `fin` obligatorio.

**Abiertas:**
1. Confirmar el conjunto **`[PROP]`** de keywords (`mientras`, `romper`, `continuar`,
   `nulo`) y de literales numéricos (bases, `_`, exponente).
2. Sintaxis de literales de **lista** y **diccionario** (definir en el doc de tipos).
