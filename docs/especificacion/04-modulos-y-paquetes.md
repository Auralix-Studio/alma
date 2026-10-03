# Alma — Módulos y Paquetes

> **Documento:** `04-modulos-y-paquetes.md`
> **Componente:** Compilador · Carga de módulos + manifiesto de proyecto
> **Estado:** Borrador de trabajo `v0.1`
> **Fuente de verdad para:** `compilador/src/modulos.zig` y `compilador/src/paquete.zig`

## Módulos (programas multi-archivo)

Un programa Alma puede repartirse en varios archivos `.alma`. Para usar definiciones de
otro archivo:

```alma
importar SIMBOLO desde "ruta"
```

La `ruta` es **relativa al archivo que importa** (se le agrega `.alma` si falta):
`importar cuadrado desde "matematicas"` carga `matematicas.alma` de la misma carpeta.

### Cómo funciona
`alma ejecutar`/`alma analizar` **enlazan** el programa antes de correrlo: parten del
archivo de entrada, cargan recursivamente los módulos referenciados y combinan **las
definiciones** (`funcion`/`estructura`/`modelo`) de cada módulo con el archivo de entrada
completo. La carga se cachea por ruta (evita duplicados y ciclos).

### Semántica v0.1 (honesto)
- El modelo es de **inclusión plana**: se traen **todas** las definiciones de nivel
  superior del módulo (no solo el símbolo nombrado en `importar`), en un espacio de
  nombres compartido. Colisiones de nombres entre módulos → error de redefinición.
- Solo se importan **definiciones**; las sentencias sueltas de nivel superior de un módulo
  (y su eventual `principal`) no se ejecutan al importarlo.
- `importar sistema` (sin `desde`) refiere a la librería estándar incorporada (hoy no-op:
  sus funciones ya son globales).
- **Diferido:** espacios de nombres reales por módulo, `exportar` selectivo estricto y
  posiciones de error que indiquen el archivo.

## Propuesta v0.2 — pendiente de confirmación (2026-10-03)

Esta sección propone reemplazar la inclusión plana; no describe el comportamiento
implementado. La descripción v0.1 anterior se conserva como referencia histórica.
En particular, su comentario de que la biblioteca estándar es un no-op está
desactualizado: la especificación 05 y el intérprete ya usan módulos incorporados.

### Identidad y ciclos

Resolver cada ruta respecto del archivo importador, añadir `.alma` cuando falte
y obtener una ruta absoluta canónica mediante el sistema de archivos antes de
consultar la caché. Normalizar `.`/`..` y resolver enlaces simbólicos/junctions.
En Windows, respetar la identidad y sensibilidad a mayúsculas del sistema de
archivos, sin convertir indiscriminadamente las rutas a minúsculas. No deduplicar
por contenido. Los hard links quedan fuera de esta primera garantía.

Registrar también el archivo de entrada. Cada módulo tiene estados `cargando` y
`cargado`: una arista hacia `cargando` es error, una hacia `cargado` reutiliza la
misma unidad. Informar `ciclo de importación: A -> B -> A` y la posición del
`importar` que cierra el ciclo. Rechazar todo ciclo, incluso si solo contiene
funciones; no sustituirlo por una redefinición ni ignorarlo silenciosamente.

### Aislamiento y visibilidad

- Cada archivo posee su entorno global. Una función conserva el entorno de su
  archivo de definición; sus nombres no se resuelven en el archivo que la llama.
- `importar S desde "ruta"` liga únicamente `S` en el importador. Los auxiliares,
  constantes e importaciones usados por `S` siguen accesibles en su módulo, sin
  filtrarse al importador. No hay importación comodín ni alias nuevos.
- Propuesta recomendada: solo `exportar funcion`, `exportar estructura` y
  `exportar modelo` son públicos. Una solicitud de nombre privado o inexistente
  es error en el `importar`. Esto rompe ejemplos actuales con funciones públicas
  implícitas: se migrarán junto con sus pruebas tras aprobarlo.
- `fijo` de nivel superior es privado. No se amplía todavía la gramática con
  `exportar fijo`. Importar directamente una constante requiere otra decisión.
- Dos módulos pueden tener auxiliares del mismo nombre. Dos enlaces al mismo
  símbolo y módulo en un archivo son idempotentes; dos símbolos distintos con
  el mismo nombre local, o un importado y una declaración local, son error.
- No hay reexportación implícita. `principal` solo se invoca automáticamente en
  el archivo de entrada. Un `principal` de otro módulo es una función ordinaria,
  accesible desde fuera únicamente si está exportada e importada explícitamente.

### Inicialización

Procesar importaciones de módulos y de biblioteca estándar en el entorno del
archivo correspondiente. Registrar primero las funciones y tipos; evaluar los
`fijo` una vez, en orden de fuente, después de inicializar las dependencias.
Una referencia a un `fijo` todavía no inicializado produce un error de Alma,
también cuando ocurre indirectamente dentro de una función. `fijo` conserva la
semántica existente: impide reasignar el enlace, sin añadir inmutabilidad profunda.

En módulos importados se admiten declaraciones de funciones/tipos, importaciones
y `fijo`; las demás sentencias de nivel superior se diagnostican en vez de
ignorarlas. El archivo de entrada conserva sus sentencias ejecutables. Un fallo
de inicialización aborta la carga/ejecución; no se ejecuta `principal` después.
`analizar` resuelve y valida, pero no ejecuta inicializadores ni sus efectos.
La primera implementación admite `importar` solo a nivel superior; apariciones
dentro de funciones o bloques se diagnostican expresamente.

### Integración y pruebas de aceptación

El cargador debe devolver unidades y enlaces de símbolos, con posiciones de
origen. El analizador y el intérprete usarán el mismo grafo; la IR asignará IDs
estables por módulo y símbolo, sin renombrar texto indiscriminadamente. El backend
C rechazará usos de biblioteca/valores fuera de su subconjunto con un diagnóstico
explícito. Esta corrección no promete compilar la biblioteca estándar completa.

Casos obligatorios: función que usa `matematicas` y un `fijo` privados; dos
módulos con un auxiliar homónimo; pedir solo uno de dos exports; pedir un privado
o un nombre inexistente; conflicto local; importación repetida; grafo en diamante
con inicialización única; ciclo directo, indirecto y por la entrada; rutas
`sub/x` y `sub/../sub/x`; enlace simbólico donde la plataforma lo permita;
diagnóstico con archivo original; módulo con `principal` que no se invoca al
importarlo. Ejecutar el subconjunto compartido en intérprete y C.

### Decisión solicitada

Aprobar aislamiento por archivo, exports explícitos, `fijo` privado e
inicialización descrita. Alternativa de compatibilidad: funciones y tipos
públicos implícitos, manteniendo importación selectiva y auxiliares aislados;
esta alternativa no ofrece privacidad explícita y no es la recomendada.
La implementación espera confirmación, según la solicitud de trabajo.

## Paquetes (`alma.paquete`)

Cada proyecto puede tener un manifiesto `alma.paquete`:

```
nombre = mi-proyecto
version = 0.1.0
entrada = principal.alma

[dependencias]
mates = matematicas.alma
```

Formato de líneas: `clave = valor` y secciones `[nombre]`; comentarios con `#` o `//`.

### Comandos
- `alma nuevo <nombre>` crea el proyecto **con** su `alma.paquete`.
- `alma paquete info` muestra los metadatos del manifiesto.
- `alma paquete validar` verifica que el manifiesto esté bien formado, que exista el
  archivo de `entrada` y que existan las rutas de cada dependencia.

### Diferido
Descarga de dependencias remotas (git/registro), *lockfile* con checksums, y resolución
de versiones. Requieren un host de publicación; hoy las dependencias son **locales**.
