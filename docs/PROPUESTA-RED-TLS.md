# Red, TLS y timeouts — decisión pendiente

Fecha: 2026-10-03. Propuesta; solo se implementó lo descrito en «Hecho».

## Estado

- `red.obtener`/`red.publicar` existen solo en el intérprete, sobre
  `std.http.Client` de Zig 0.16 (HTTP/1.1 y TLS de `std.crypto.tls`).
- **Hecho** (commit `68c48a8`): el cuerpo de la respuesta se lee con un tope
  (`limites.red_respuesta`, 50 MB, configurable con `--limite-red`); las
  cabeceras con CR/LF, `:` en el nombre o nombre vacío se rechazan.
- **Pendiente: timeout.** `std.http.Client.fetch` no acepta timeout y
  `ConnectTcpOptions.timeout` no se propaga a la conexión real en 0.16. Hoy una
  petición a un servidor que no responde bloquea el programa indefinidamente.
  `limites.red_timeout_ms` queda reservado.

## Timeout en el intérprete

| Opción | Coste | Riesgo |
|---|---|---|
| (a) Ejecutar la petición con `io.async` y esperar con un plazo; cancelar la tarea al vencer (`Future.cancel`) | Bajo-medio | Depende de que la implementación `Threaded` de `std.Io` cancele lecturas de socket bloqueadas en ambos sistemas: hay que verificarlo con un servidor local que no responda |
| (b) Opciones de socket (`SO_RCVTIMEO`/`SO_SNDTIMEO`) sobre el handle de la conexión | Medio | Código por plataforma; no cubre la resolución DNS ni el `connect` |
| (c) Hilo vigilante que cierre el socket | Medio | Condiciones de carrera con el pool de conexiones |

**Recomendación: (a)**, con una prueba que levante un servidor TCP local que
acepte y no responda, y compruebe un error capturable antes del plazo + 1 s.

## TLS en el backend propio

| Opción | Coste | Riesgo | Independencia |
|---|---|---|---|
| (i) TLS 1.3 propio (X25519, AES-GCM/ChaCha20-Poly1305, SHA-2, HKDF, X.509 y validación de cadenas) | Muy alto | Criptografía y validación de certificados son la superficie de seguridad más delicada; sin auditoría externa | Total |
| (ii) API del sistema: Windows **WinHTTP** (HTTP + TLS + almacén de certificados + proxy del sistema) | Medio: importaciones de `winhttp.dll` y un envoltorio por llamada | Bajo: la criptografía y la confianza las mantiene el sistema | El programa depende solo del sistema operativo, como ya ocurre con `kernel32` |
| (iii) Linux: no hay TLS en el sistema base; kTLS solo cifra registros (el handshake sigue en espacio de usuario) | — | Cargar OpenSSL/GnuTLS dinámicamente sería una dependencia externa | Contradice el objetivo |
| (iv) Portar el cliente TLS de `std` a Alma durante el autohospedaje | Alto | Igual que (i) pero con código de referencia probado | Total, a largo plazo |

**Recomendación:** Windows con (ii) WinHTTP cuando el backend propio soporte
diccionarios y textos dinámicos; Linux sin `red` nativo hasta (iv); el
intérprete conserva `std.http`. Nunca TLS propio sin revisión externa.

## Decisión solicitada

Aprobar (a) para el timeout del intérprete y (ii)/(iv) para el backend propio.
