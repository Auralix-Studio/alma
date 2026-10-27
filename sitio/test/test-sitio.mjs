/**
 * ALMA — Suite de Pruebas Automatizadas de Integración Continua (CI)
 * Ejecuta validaciones de sintaxis, integridad de enlaces, ausencia de emojis
 * y pruebas unitarias de alta cobertura sobre el intérprete de Alma en JS.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const SITIO_DIR = path.resolve(__dirname, '..');

// -----------------------------------------------------------------------------
// 1. Integridad de Archivos y Assets
// -----------------------------------------------------------------------------
test('CI: Integridad estructural de archivos requeridos', () => {
  const archivosRequeridos = [
    'index.html',
    'css/styles.css',
    'js/interprete-alma.js',
    'js/juegos.js',
    'js/docs.js',
    'js/app.js',
    'assets/marca/alma-logo.svg',
    'assets/marca/alma-icono-app.svg'
  ];

  for (const rel of archivosRequeridos) {
    const full = path.join(SITIO_DIR, rel);
    assert.ok(fs.existsSync(full), `Falta el archivo esencial: ${rel}`);
  }
});

// -----------------------------------------------------------------------------
// 2. Verificación de Enlaces y Referencias en index.html
// -----------------------------------------------------------------------------
test('CI: Verificación de referencias y enlaces locales en index.html', () => {
  const htmlPath = path.join(SITIO_DIR, 'index.html');
  const html = fs.readFileSync(htmlPath, 'utf8');

  // Verificar scripts src="..."
  const scriptRegex = /<script\s+src="([^"]+)"/g;
  let match;
  while ((match = scriptRegex.exec(html)) !== null) {
    const src = match[1];
    if (!src.startsWith('http')) {
      const full = path.join(SITIO_DIR, src);
      assert.ok(fs.existsSync(full), `Script referenciado no encontrado: ${src}`);
    }
  }

  // Verificar link href="..."
  const linkRegex = /<link[^>]+href="([^"]+)"/g;
  while ((match = linkRegex.exec(html)) !== null) {
    const href = match[1];
    if (!href.startsWith('http')) {
      const full = path.join(SITIO_DIR, href);
      assert.ok(fs.existsSync(full), `Recurso link no encontrado: ${href}`);
    }
  }

  // Verificar img src="..."
  const imgRegex = /<img[^>]+src="([^"]+)"/g;
  while ((match = imgRegex.exec(html)) !== null) {
    const src = match[1];
    if (!src.startsWith('http')) {
      const full = path.join(SITIO_DIR, src);
      assert.ok(fs.existsSync(full), `Imagen referenciada no encontrada: ${src}`);
    }
  }
});

// -----------------------------------------------------------------------------
// 3. Regla Estricta: Cero Emojis en Código Fuente Web
// -----------------------------------------------------------------------------
test('CI: Regla de diseño técnico: ausencia total de emojis', () => {
  const emojiRegex = /[\uD83C-\uDBFF\uDC00-\uDFFF\u2600-\u27BF]/;
  const archivosTexto = [
    'index.html',
    'css/styles.css',
    'js/interprete-alma.js',
    'js/juegos.js',
    'js/docs.js',
    'js/app.js'
  ];

  for (const rel of archivosTexto) {
    const full = path.join(SITIO_DIR, rel);
    const contenido = fs.readFileSync(full, 'utf8');
    const match = contenido.match(emojiRegex);
    assert.strictEqual(
      match,
      null,
      `Violación de diseño: Se encontró un emoji en ${rel} (${match?.[0]})`
    );
  }
});

// -----------------------------------------------------------------------------
// 4. Pruebas Funcionales del Motor Intérprete de Alma
// -----------------------------------------------------------------------------
test('CI: Motor de Ejecución de Alma en JS', async (t) => {
  // Cargar InterpreteAlma simulando entorno global
  const jsPath = path.join(SITIO_DIR, 'js', 'interprete-alma.js');
  const jsCode = fs.readFileSync(jsPath, 'utf8');
  
  global.window = {};
  const evalFn = new Function('window', jsCode);
  evalFn(global.window);

  const InterpreteAlma = global.window.InterpreteAlma;
  assert.ok(InterpreteAlma, 'InterpreteAlma debe estar definido en window');

  await t.test('Hola Mundo e impresión', () => {
    const interp = new InterpreteAlma();
    const res = interp.ejecutar('imprimir("Hola Alma")');
    assert.strictEqual(res.exito, true);
    assert.strictEqual(res.salida, 'Hola Alma');
  });

  await t.test('Semántica de memoria: estructura (valor) vs modelo (referencia)', () => {
    const interp = new InterpreteAlma();
    const codigo = `
estructura Vector
    x: entero
fin

modelo Contador
    total: entero
fin

funcion principal()
    v1 = Vector(10)
    v2 = v1
    v2.x = 99
    imprimir(v1.x) // debe ser 10 (copia)

    c1 = Contador(10)
    c2 = c1
    c2.total = 99
    imprimir(c1.total) // debe ser 99 (referencia)
fin
    `;
    const res = interp.ejecutar(codigo);
    assert.strictEqual(res.exito, true);
    assert.strictEqual(res.salida, '10\n99');
  });

  await t.test('Aritmética y operadores lógicos', () => {
    const interp = new InterpreteAlma();
    const codigo = `
funcion principal()
    a = 10 + 5 * 2
    b = 20 - 4
    c = 10 > 5 && 3 < 4
    imprimir(a)
    imprimir(b)
    imprimir(c)
fin
    `;
    const res = interp.ejecutar(codigo);
    assert.strictEqual(res.exito, true);
    assert.strictEqual(res.salida, '20\n16\nverdadero');
  });

  await t.test('Recursión: Factorial', () => {
    const interp = new InterpreteAlma();
    const codigo = `
funcion factorial(n: entero) -> entero
    si n <= 1
        retornar 1
    sino
        retornar n * factorial(n - 1)
    fin
fin

funcion principal()
    imprimir(factorial(5))
fin
    `;
    const res = interp.ejecutar(codigo);
    assert.strictEqual(res.exito, true);
    assert.strictEqual(res.salida, '120');
  });

  await t.test('Colecciones: listas y diccionarios', () => {
    const interp = new InterpreteAlma();
    const codigo = `
funcion principal()
    l = [10, 20]
    agregar(l, 30)
    imprimir(longitud(l))
    imprimir(l[0])

    d = {"modulo": "sistema"}
    imprimir(d["modulo"])
    imprimir(tiene(d, "modulo"))
fin
    `;
    const res = interp.ejecutar(codigo);
    assert.strictEqual(res.exito, true);
    assert.strictEqual(res.salida, '3\n10\nsistema\nverdadero');
  });

  await t.test('Constantes inmutables con "fijo"', () => {
    const interp = new InterpreteAlma();
    const codigo = `
funcion principal()
    fijo MAX = 100
    MAX = 200
fin
    `;
    const res = interp.ejecutar(codigo);
    assert.strictEqual(res.exito, false);
    assert.match(res.error, /No se puede reasignar la constante 'fijo MAX'/);
  });

  await t.test('Manejo de excepciones: intentar / capturar / lanzar', () => {
    const interp = new InterpreteAlma();
    const codigo = `
funcion principal()
    intentar
        lanzar error("Fallo crítico simulado")
    capturar (e)
        imprimir(e.mensaje)
    fin
fin
    `;
    const res = interp.ejecutar(codigo);
    assert.strictEqual(res.exito, true);
    assert.strictEqual(res.salida, 'Fallo crítico simulado');
  });

  await t.test('Presupuesto de pasos contra bucles infinitos', () => {
    const interp = new InterpreteAlma();
    interp.limitePasos = 500;
    const codigo = `
funcion principal()
    mientras verdadero
    fin
fin
    `;
    const res = interp.ejecutar(codigo);
    assert.strictEqual(res.exito, false);
    assert.match(res.error, /Límite de ejecución excedido/);
  });
});
