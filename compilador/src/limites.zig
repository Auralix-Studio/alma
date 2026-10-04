//! Límites aprobados en docs/propuestas/PROPUESTA-LIMITES.md y endurecimiento adicional.
pub const sintaxis: usize = 64;
pub const llamadas: usize = 64;
pub const json: usize = 64;
pub const archivo_fuente: usize = 16 * 1024 * 1024; // 16 MB para código fuente/manifiestos
pub const archivo_datos: usize = 100 * 1024 * 1024; // 100 MB para `sistema.leer_archivo`
pub const red_respuesta: usize = 50 * 1024 * 1024;  // 50 MB para `red.obtener`/`publicar`
pub const red_timeout_ms: u32 = 30000;             // reservado: std.http 0.16 no expone timeout (docs/propuestas/PROPUESTA-RED-TLS.md)
pub const anidamiento: usize = 64; // niveles de contenedores al mostrar o serializar valores
