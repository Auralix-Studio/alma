# Marca de Alma

Logo elegido: **concepto A · Llama** (decisión del 2026-10-03). «Alma» como una llama
interior: el cuerpo violeta es la llama y el núcleo ámbar, el alma.

| Archivo | Uso |
|---|---|
| `alma-logo.svg` | Logo principal sobre fondo claro |
| `alma-logo-oscuro.svg` | Logo sobre fondo oscuro |
| `alma-logo-mono.svg` | Una tinta (`currentColor`): sellos, documentos, iconos monocromos |
| `alma-icono-app.svg` | Icono de aplicación y de extensión (cuadrado redondeado oscuro) |
| `png/` | Exportaciones de 16, 32, 48, 128, 256, 512 y 1024 px con transparencia |

## Paleta

| Nombre | Hex | Uso |
|---|---|---|
| Violeta Alma | `#6D4AFF` | Color principal sobre fondos claros |
| Violeta claro | `#9B85FF` | Color principal sobre fondos oscuros |
| Ámbar núcleo | `#FFB547` | Acento (núcleo del logo, resaltados) |
| Tinta | `#16131F` | Texto y fondos oscuros |

## Regenerar los PNG

Después de editar un SVG:

```
node marca/generar-png.mjs
```

Usa Edge o Chrome sin interfaz y no necesita paquetes de npm. Si el navegador
está en otra ruta, defínela con la variable `NAVEGADOR`.

## Estado

Es un boceto de trabajo: conviene que un diseñador lo refine (proporciones de la
llama y del núcleo, versión con texto «alma») antes de difundir la app.
