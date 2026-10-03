# Alma — Gramática Sintáctica (EBNF)

> **Documento:** `02-gramatica.md`
> **Componente:** Compilador · Front-end · Etapa 2 (Parser / AST)
> **Estado:** Borrador de trabajo `v0.1` (subconjunto implementado)
> **Fuente de verdad para:** `compilador/src/sintaxis/ast.zig` y `parser.zig`

El parser es **recursivo-descendente** y consume el flujo de tokens del
[lexer](01-lexico-y-tokens.md). Convenciones EBNF: `{ x }` = cero o más, `[ x ]` =
opcional, `|` = alternativa, `'x'` = token literal, `MAYUS` = token del lexer.

Notación de líneas: `NL` = `nueva_linea`, `IND` = `sangria`, `DED` = `desangria`.

Límite aprobado: 64 niveles activos combinados de bloques y expresiones anidadas,
y altura máxima 64 para cada AST de expresión (hoja = 1). El nivel siguiente
produce error de sintaxis con posición. Los niveles internos de precedencia no
cuentan. Véase [el contrato de límites](../PROPUESTA-LIMITES.md) para el conteo.

---

## 1. Programa y bloques

```ebnf
programa   = { NL } { sentencia } EOF ;
bloque     = IND { NL } { sentencia } DED ;          (* cuerpo indentado *)
```

Todo constructo compuesto sigue el patrón **híbrido**: cabecera `NL`, `bloque`, y
cierre `'fin' NL`. La indentación define el `bloque`; `fin` lo cierra explícitamente.

---

## 2. Sentencias

```ebnf
sentencia  = decl_fija
           | importacion
           | exportacion
           | si | mientras | para | intentar
           | funcion | estructura | modelo
           | 'retornar' [ expresion ] NL
           | 'lanzar' expresion NL
           | 'hilo' expresion NL
           | 'romper' NL
           | 'continuar' NL
           | expr_o_asignacion ;

decl_fija  = 'fijo' IDENT [ ':' IDENT ] '=' expresion NL ;

expr_o_asignacion =
             expresion (                              (* expr como sentencia   *)
               | '=' expresion                        (* asignación            *)
               | ':' IDENT '=' expresion              (* declaración con tipo  *)
             ) NL ;

importacion = 'importar' IDENT [ 'desde' TEXTO ] NL ;
exportacion = 'exportar' ( funcion | estructura | modelo ) ;
```

> `nombre = valor` se representa como **asignación**; la distinción entre *declarar*
> y *reasignar* la resuelve el análisis semántico (Etapa 3). `fijo` sí declara constante.

---

## 3. Control de flujo

```ebnf
si       = 'si' expresion NL bloque
           { 'sino' 'si' expresion NL bloque }        (* else-if = sino si     *)
           [ 'sino' NL bloque ]
           'fin' NL ;

mientras = 'mientras' expresion NL bloque 'fin' NL ;

para     = 'para' IDENT 'en' expresion NL bloque 'fin' NL ;

intentar = 'intentar' NL bloque
           'capturar' '(' IDENT ')' NL bloque
           'fin' NL ;
```

El error atrapado se liga al `IDENT` de `capturar` y expone `.mensaje`. `lanzar`
acepta un valor de error (`error("…")`) o cualquier valor (se convierte a texto).

---

## 4. Funciones y tipos

```ebnf
funcion    = [ 'asincrona' ] 'funcion' IDENT '(' [ params ] ')' [ '->' IDENT ]
             NL bloque 'fin' NL ;
params     = param { ',' param } ;
param      = IDENT [ ':' IDENT ] ;

estructura = 'estructura' IDENT NL IND { campo } DED 'fin' NL ;
modelo     = 'modelo' IDENT NL IND { campo | funcion } DED 'fin' NL ;
campo      = IDENT ':' IDENT NL ;
```

`estructura` = tipo por valor (Stack); `modelo` = tipo por referencia (Heap, ARC).
Léxicamente idénticos aquí; la diferencia semántica se aplica en etapas posteriores.

---

## 5. Expresiones (por precedencia, de menor a mayor)

```ebnf
expresion  = disy ;
disy       = conj   { '||' conj } ;                   (* o_logico   *)
conj       = igual  { '&&' igual } ;                  (* y_logico   *)
igual      = comp   { ( '==' | '!=' ) comp } ;
comp       = term   { ( '<' | '>' | '<=' | '>=' ) term } ;
term       = factor { ( '+' | '-' ) factor } ;
factor     = unario { ( '*' | '/' | '%' ) unario } ;
unario     = ( '!' | '-' | 'esperar' ) unario | postfijo ;
postfijo   = primario { llamada | acceso | indice } ;
llamada    = '(' [ argumentos ] ')' ;
acceso     = '.' IDENT ;
indice     = '[' expresion ']' ;
argumentos = expresion { ',' expresion } ;

primario   = ENTERO | DECIMAL | TEXTO
           | 'verdadero' | 'falso' | 'nulo'
           | IDENT
           | '(' expresion ')'
           | lista | diccionario ;
lista      = '[' [ argumentos ] ']' ;
diccionario = '{' [ par { ',' par } ] '}' ;
par        = expresion ':' expresion ;                (* clave debe evaluar a texto *)
```

Todos los binarios son **asociativos por la izquierda**. `postfijo` encadena llamadas,
accesos e índices: `respuesta.json()`, `error.mensaje`, `datos[0]`, `obj.metodo(a, b)`.

**Construcción de instancias:** reutiliza la sintaxis de `llamada` sobre el nombre del
tipo, con argumentos **posicionales** en orden de declaración de campos:
`Punto(1, 2)`, `Servidor("localhost", 8080)`. *(Decisión de diseño; alternativa a evaluar:
literal con campos nombrados `Punto{ x: 1, y: 2 }`.)*

---

## 6. Estado del intérprete y diferido

**Métodos de `modelo`** ✅: dentro de un método, los nombres de campo resuelven a la
instancia (**self implícito**: `host = h` asigna el campo), y `yo` es el self explícito
(`yo.host`). Ejemplo funcionando: `ejemplos/servidor.alma`.

**Ya funcionan:** `intentar`/`capturar`/`lanzar` (errores) y `asincrona`/`esperar`/`hilo`
(async). En el intérprete, async se resuelve de forma **cooperativa/síncrona**: una función
`asincrona` devuelve una promesa que `esperar` resuelve, y `hilo` ejecuta la tarea en el acto.

**Diferido:** FFI `externa "C"`, métodos en `estructura` (el parser aún solo acepta campos),
ARC real y **paralelismo real** (event loop / hilos del SO) — ambos llegan con el runtime
nativo; por ahora la memoria vive en una arena y la ejecución es síncrona.
