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
