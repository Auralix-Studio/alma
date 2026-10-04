# Semántica numérica compartida — implementada

Fecha: 2026-10-03. **Estado:** implementada en el intérprete, la IR y el runtime C (commit `5b0a5a5`; JSON en `693c173`) según el encargo que remite a este documento. El backend propio sigue rechazando decimales (ver [memoria nativa](PROPUESTA-MEMORIA-NATIVA.md) §3). La redacción original se conserva abajo como especificación.

## Formato decimal

Conservar `decimal` como binary64. Para cada valor finito distinto de cero,
obtener la menor cantidad de dígitos significativos que, al leerlos con redondeo
al más cercano y empate al par, reconstruyan exactamente sus bits. Entre
candidatos equivalentes, elegir el más cercano al valor exacto; en un empate,
el último dígito par. Esto define shortest round-trip de la significanda.

Presentación canónica: punto ASCII, sin separadores ni dependencia de locale;
notación fija si el exponente decimal normalizado está entre -6 y 20 inclusive,
y científica fuera de ese intervalo. Exponente con `e` minúscula, sin `+` ni
ceros iniciales; sin ceros fraccionarios finales. Un decimal integral puede
imprimirse sin `.0`. El signo de cero se conserva: `0` y `-0`.
La selección fija/científica prioriza legibilidad y uniformidad: no promete
el mínimo número total de caracteres para valores como diez millones.

| Valor | Salida propuesta |
|---|---|
| `0.1 + 0.2` | `0.30000000000000004` |
| `10000000.0` | `10000000` |
| `1.0 / 3.0` | `0.3333333333333333` |
| Cero decimal negativo | `-0` |

`imprimir`, `texto` y JSON comparten el formateador. Para valores no finitos,
proponer `nan`, `inf` y `-inf` en texto; `json.serializar` los rechaza con error
capturable, ya que no son números JSON. El contrato de ida y vuelta es de valor
binary64, no preservación de etiquetas entero/decimal en JSON: el JSON `1` puede
seguir analizándose como entero. Preservar la etiqueta requeriría otro contrato.
Para `-0` en JSON se propone conservar el signo al analizarlo como decimal.
La sintaxis de literales Alma con exponentes sigue diferida; imprimir `1e21`
no implica aceptar ese texto como programa fuente.

No basta cambiar `%g` por `%.17g`: puede recuperar precisión, pero no garantiza
la salida mínima ni las reglas anteriores. Implementar un algoritmo propio sin
dependencias nuevas, con especificación independiente del lenguaje anfitrión,
vectores de bits y resultados compartidos. El intérprete y C tendrán adaptaciones
de ese algoritmo; portar al runtime propio al incorporar decimales. Hoy ese
backend los rechaza: no se anunciará concordancia decimal antes de soportarlos.

## Enteros y comparaciones mixtas

Aceptar `-9223372036854775808`: reconocer la negación directa de la magnitud
9223372036854775808 antes de convertir a `i64`. Los paréntesis de agrupación
no cambian ese caso. Rechazar otras magnitudes fuera de rango durante `analizar`;
`--9223372036854775808` conserva el error de desbordamiento al negar el mínimo.

Comparar entero y decimal por su valor matemático exacto, sin convertir primero
el entero a binary64. Aplicar la misma relación a `==`, `!=`, `<`, `<=`, `>` y
`>=` en ambos órdenes. Así, `9007199254740993 == 9007199254740992.0` es falso y
el entero es mayor. Cero y cero negativo comparan iguales. NaN no es igual ni
ordenable (`!=` verdadero); los infinitos se ordenan fuera de los enteros finitos.

Algoritmo propuesto: clasificar NaN/infinito y rango antes de convertir; para
decimal finito dentro de `[-2^63, 2^63)`, truncar hacia cero a `i64`, comparar
los enteros y, si coinciden, usar el signo de la fracción restante. Fuera de ese
rango se decide directamente. Nunca convertir un decimal fuera de rango a `i64`.
No se modifica en esta tarea el redondeo de la aritmética mixta.

## Pruebas diferenciales

Conjunto versionado de `.alma` con salida esperada en bytes y código de salida;
ejecutar intérprete y C, y propio para casos que soporte. Cada prueba tiene
timeout y compara stdout sin `Trim`, incluyendo NUL y salto final. Si se permite
normalizar CRLF, hacerlo únicamente en casos textuales declarados; para escapes,
comparación binaria exacta. Validar stderr y posiciones en casos de error sin
exigir igualdad textual de diagnósticos que hoy difieren por motor.

Cubrir los ejemplos anteriores, escapes, mínimo/máximo i64, extremos de binary64,
subnormales, ceros con signo, potencias de diez y sus vecinos, NaN/inf y las seis
comparaciones mixtas alrededor de 2^53 y de los extremos i64. Añadir muestreo de
bits con semilla fija para verificar formato/lectura y reproducibilidad. Un caso
no soportado en el backend propio se declara excluido; no cuenta como aprobado.

## Decisión solicitada

Aprobar presentación canónica, cero negativo/no finitos, tratamiento de JSON,
comparación exacta y literal mínimo. La lista de escapes propuesta está en
la sección pendiente de `especificacion/01-lexico-y-tokens.md`.
