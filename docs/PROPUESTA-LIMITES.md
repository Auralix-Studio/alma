# Límites de profundidad — contrato aprobado

Fecha: 2026-10-03. Límites y conteo aprobados explícitamente por el usuario en
esta fecha. La implementación y su verificación se registran por separado.

La solicitud exige rechazar el exceso de profundidad con errores de Alma.
Las especificaciones 02 y 05 no fijan valores ni cómo contarlos. Se propone
el siguiente contrato para aprobar antes de modificar el compilador.

| Recurso | Máximo propuesto | Qué se cuenta | Error |
|---|---:|---|---|
| Sintaxis | 64 | Niveles activos combinados de bloques y expresiones anidadas; además, altura del AST de expresiones | `límite de profundidad sintáctica excedido`, con archivo:línea:columna |
| Llamadas Alma | 64 | Funciones y métodos activos, incluida `principal`; llamadas nativas incorporadas excluidas | `desbordamiento de pila` |
| JSON | 64 | Contenedores abiertos (objetos y arreglos juntos); valores escalares no añaden profundidad | `JSON inválido: límite de anidamiento excedido` |

El nivel 64 se admite; el intento de entrar en el 65 falla antes de descender.
Los contadores se restauran tanto al retornar normalmente como al propagar errores.
Un error capturado no consume permanentemente el presupuesto de llamadas.
La profundidad es de llamadas activas, no el total de llamadas del programa.

En sintaxis, los niveles internos de precedencia del parser no consumen presupuesto.
Los paréntesis, prefijos unarios y expresiones anidadas en listas, diccionarios,
argumentos e índices sí lo consumen. La altura de cada AST de expresión cuenta
la hoja como uno; cadenas binarias y de accesos también quedan acotadas para
proteger los recorridos recursivos posteriores. Los bloques se cuentan desde uno
para el primer cuerpo indentado; el nivel superior no consume un bloque.

El intérprete entrega el error de llamadas mediante su mecanismo existente de
`intentar`/`capturar`. El runtime C termina con código 1 y diagnóstico de origen,
porque actualmente no compila `intentar`. Ambos usan el mismo máximo. La entrada
sintética de la IR no cuenta como función del usuario. El backend propio conserva
su limitación actual hasta las tareas posteriores: no se declara ya protegido.

Los valores son conservadores y están pendientes de validación en Debug y Release
en Windows y Linux. Un contador limita niveles lógicos, no bytes de stack: marcos
C enormes y combinaciones de expresiones profundas con llamadas aún requieren
medición. No se promete inmunidad ante cualquier agotamiento de stack.

## Implementación y aceptación propuestas

1. Constantes compartidas por parser, intérprete y emisor C; emitir el máximo en
   el C generado para evitar duplicar números independientes en el runtime.
2. Guardas antes de las entradas recursivas, con restauración garantizada;
   altura de expresiones calculada al construir nodos, sin otro recorrido profundo.
3. Pruebas unitarias de frontera (64/65), prefijos unarios, bloques y contadores
   restaurados. Para llamadas: recursión directa, mutua y mediante métodos;
   captura seguida de otra llamada y repetición de llamadas no recursivas.
4. Pruebas CLI aisladas con timeout: recursión infinita interpretada y compilada
   a C, 200.000 paréntesis y JSON con 300.000 `[` (incluido el caso incompleto).
   Exigir error diagnosticado, nunca éxito, timeout ni terminación del SO.
5. JSON: fronteras de objetos/arreglos mezclados y análisis normal después de
   capturar el error. Parser: comprobar archivo:línea:columna en el CLI.

Cada corrección se entregará por separado, mostrando la prueba fallida antes del
cambio y pasada después, junto con `zig build test`.

## Decisión recibida

El usuario aprobó 64 como límite inicial para los tres recursos y el conteo
descrito. No se añade configuración pública en esta primera corrección.
