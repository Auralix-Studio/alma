# Documentación de Alma

| Carpeta | Qué contiene | Cuándo leerla |
|---|---|---|
| [`guias/`](guias) | Material para aprender el lenguaje | Primer contacto con Alma |
| [`especificacion/`](especificacion) | Contrato del lenguaje y del compilador (fuente de verdad) | Antes de cambiar el lenguaje o un motor |
| [`propuestas/`](propuestas) | Decisiones de diseño, con su estado (aprobada, implementada o pendiente) | Antes de tomar o revisar una decisión |
| [`planes/`](planes) | Hacia dónde va el proyecto y en qué orden | Para planificar trabajo |
| [`informes/`](informes) | Auditorías, resultados de verificación y estados históricos | Para saber qué se comprobó y cuándo |

## Guías
- [Alma en 5 minutos](guias/tutorial-alma-en-5-minutos.md)

## Especificación
1. [Léxico y tokens](especificacion/01-lexico-y-tokens.md)
2. [Gramática](especificacion/02-gramatica.md)
3. [Análisis semántico](especificacion/03-analisis-semantico.md)
4. [Módulos y paquetes](especificacion/04-modulos-y-paquetes.md)
5. [Librería estándar](especificacion/05-libreria-estandar.md)
6. [Compilación nativa (backend C)](especificacion/06-compilacion-nativa.md)
7. [IR y backend propio](especificacion/07-ir-y-backend-propio.md)

## Propuestas
| Documento | Estado |
|---|---|
| [Límites de profundidad](propuestas/PROPUESTA-LIMITES.md) | Implementada |
| [Semántica numérica](propuestas/PROPUESTA-NUMEROS.md) | Implementada |
| [Memoria del intérprete](propuestas/PROPUESTA-MEMORIA.md) | Implementada (GC) |
| [Memoria del backend propio](propuestas/PROPUESTA-MEMORIA-NATIVA.md) | **Pendiente de decisión** |
| [Backend ELF para Linux](propuestas/PROPUESTA-ELF-LINUX.md) | **Pendiente de decisión** |
| [Red, TLS y timeouts](propuestas/PROPUESTA-RED-TLS.md) | **Pendiente de decisión** |

## Planes
- [Camino a un compilador independiente](planes/PLAN-INDEPENDENCIA.md)
- [Hoja de ruta](planes/HOJA-DE-RUTA.md)
- [Autohospedaje](planes/AUTOHOSPEDAJE.md)
- [Aplicación de aprendizaje estilo Mimo](planes/APP-APRENDIZAJE.md)

## Informes
- [Auditoría 2026-10-03](informes/AUDITORIA.md)
- [Verificación del endurecimiento](informes/INFORME-ENDURECIMIENTO.md)
- [Estado del proyecto (histórico, julio 2026)](informes/ESTADO-DEL-PROYECTO.md)
