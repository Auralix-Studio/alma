# Ejemplos de Alma

Todos se ejecutan con el intérprete desde la raíz del repositorio:

```
alma ejecutar ejemplos/basicos/factorial.alma
```

| Carpeta | Contenido |
|---|---|
| [`basicos/`](basicos) | Variables, recursión, `estructura`/`modelo`, diccionarios, errores, async |
| [`biblioteca-estandar/`](biblioteca-estandar) | `matematicas`, `cadena`, `sistema`, `json` y `red` |
| [`proyecto-modular/`](proyecto-modular) | Un programa repartido en varios archivos (`importar … desde`) |
| [`aplicaciones/`](aplicaciones) | Programas completos con `alma.paquete` |

`red.alma` y `aplicaciones/descargador-tiktok` necesitan conexión a internet.
De `basicos/`, hoy solo `saludo.alma` y `factorial.alma` se pueden además compilar
con `alma compilar`; el resto usa colecciones, objetos, errores o async, que los
backends nativos todavía no admiten (ver
[la especificación 07](../docs/especificacion/07-ir-y-backend-propio.md)).
