/**
 * ALMA — Gestor de Documentación y Búsqueda en Vivo
 */

class GestorDocumentacion {
  constructor() {
    this.articulos = [];
    this.iniciar();
  }

  iniciar() {
    this.configurarNavegacionSidebar();
    this.configurarBuscador();
    this.configurarBotonesCopiar();
    this.resaltarSintaxisEnDocs();
  }

  configurarNavegacionSidebar() {
    const items = document.querySelectorAll('.docs-menu-item');
    items.forEach(item => {
      item.addEventListener('click', () => {
        const docId = item.getAttribute('data-doc');
        this.mostrarArticulo(docId);
      });
    });
  }

  mostrarArticulo(docId) {
    // Actualizar sidebar
    document.querySelectorAll('.docs-menu-item').forEach(el => {
      el.classList.toggle('active', el.getAttribute('data-doc') === docId);
    });

    // Mostrar contenido
    document.querySelectorAll('.doc-article').forEach(art => {
      art.classList.toggle('active', art.id === `doc-${docId}`);
    });

    // Scroll arriba en el panel de lectura
    const panel = document.querySelector('.docs-content');
    if (panel) panel.scrollTop = 0;
  }

  configurarBuscador() {
    const input = document.getElementById('docsSearchInput');
    if (!input) return;

    input.addEventListener('input', (e) => {
      const termino = e.target.value.toLowerCase().trim();
      const items = document.querySelectorAll('.docs-menu-item');

      items.forEach(item => {
        const texto = item.textContent.toLowerCase();
        const coincide = texto.includes(termino);
        item.style.display = coincide ? 'block' : 'none';
      });

      // Si hay término y el activo se oculta, seleccionar el primero visible
      if (termino) {
        const primerVisible = Array.from(items).find(i => i.style.display !== 'none');
        if (primerVisible) {
          const docId = primerVisible.getAttribute('data-doc');
          this.mostrarArticulo(docId);
        }
      }
    });
  }

  configurarBotonesCopiar() {
    document.addEventListener('click', (e) => {
      if (e.target.matches('.btn-copy') || e.target.closest('.btn-copy')) {
        const btn = e.target.matches('.btn-copy') ? e.target : e.target.closest('.btn-copy');
        const targetId = btn.getAttribute('data-copy-target');
        const targetEl = document.getElementById(targetId);
        if (targetEl) {
          const texto = targetEl.textContent || targetEl.innerText;
          navigator.clipboard.writeText(texto.trim()).then(() => {
            const original = btn.innerHTML;
            btn.innerHTML = '<span>COPIADO</span>';
            btn.style.borderColor = 'var(--status-success)';
            btn.style.color = 'var(--status-success)';
            setTimeout(() => {
              btn.innerHTML = original;
              btn.style.borderColor = '';
              btn.style.color = '';
            }, 1800);
          });
        }
      }
    });
  }

  resaltarSintaxisEnDocs() {
    const bloques = document.querySelectorAll('pre code.language-alma, pre.code-pre code');
    bloques.forEach(bloque => {
      let html = bloque.textContent;
      html = this.resaltarCodigoAlma(html);
      bloque.innerHTML = html;
    });
  }

  resaltarCodigoAlma(codigo) {
    // Escapar HTML primero
    let seguro = codigo
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');

    // Comentarios //
    seguro = seguro.replace(/(\/\/.*$)/gm, '<span class="comm">$1</span>');

    // Cadenas "texto"
    seguro = seguro.replace(/(".*?"|'.*?')(?!span)/g, '<span class="str">$1</span>');

    // Palabras clave
    const keywords = [
      'funcion', 'estructura', 'modelo', 'si', 'sino si', 'sino', 'mientras', 'para',
      'en', 'fin', 'retornar', 'fijo', 'intentar', 'capturar', 'lanzar', 'importar',
      'desde', 'asincrona', 'esperar', 'hilo', 'yo', 'verdadero', 'falso', 'nulo'
    ];
    keywords.forEach(kw => {
      const reg = new RegExp(`\\b(${kw})\\b(?![^<]*>)`, 'g');
      seguro = seguro.replace(reg, '<span class="kw">$1</span>');
    });

    // Tipos nativos
    const tipos = ['entero', 'decimal', 'texto', 'logico', 'lista', 'diccionario'];
    tipos.forEach(t => {
      const reg = new RegExp(`\\b(${t})\\b(?![^<]*>)`, 'g');
      seguro = seguro.replace(reg, '<span class="typ">$1</span>');
    });

    // Funciones estándar globales
    const funciones = ['imprimir', 'longitud', 'agregar', 'rango', 'tiene', 'claves', 'error', 'texto'];
    funciones.forEach(fn => {
      const reg = new RegExp(`\\b(${fn})\\b(?=\\()(?![^<]*>)`, 'g');
      seguro = seguro.replace(reg, '<span class="fn">$1</span>');
    });

    // Números
    seguro = seguro.replace(/\b(\d+(\.\d+)?)\b(?![^<]*>)/g, '<span class="num">$1</span>');

    return seguro;
  }
}

window.gestorDocs = new GestorDocumentacion();
