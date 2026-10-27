/**
 * ALMA — Motor de Laboratorio Técnico y Telemetría
 * Módulos incluidos:
 * 1. Inspección de Memoria (Valor vs. Referencia)
 * 2. Depuración Semántica (Diagnóstico de Código)
 * 3. Navegación Autónoma de Algoritmos (Canvas 2D)
 *
 * Cero emojis. Estilo técnico y telemetría de sistemas.
 */

class AudioSintetizador {
  constructor() {
    this.ctx = null;
  }

  iniciar() {
    if (!this.ctx) {
      const AudioCtx = window.AudioContext || window.webkitAudioContext;
      if (AudioCtx) this.ctx = new AudioCtx();
    }
    if (this.ctx && this.ctx.state === 'suspended') {
      this.ctx.resume();
    }
  }

  beep(frecuencia = 440, duracion = 0.08, tipo = 'sine') {
    try {
      this.iniciar();
      if (!this.ctx) return;
      const osc = this.ctx.createOscillator();
      const gain = this.ctx.createGain();
      osc.type = tipo;
      osc.frequency.setValueAtTime(frecuencia, this.ctx.currentTime);
      gain.gain.setValueAtTime(0.08, this.ctx.currentTime);
      gain.gain.exponentialRampToValueAtTime(0.001, this.ctx.currentTime + duracion);
      osc.connect(gain);
      gain.connect(this.ctx.destination);
      osc.start();
      osc.stop(this.ctx.currentTime + duracion);
    } catch (e) {}
  }

  acierto() {
    this.beep(520, 0.08, 'triangle');
    setTimeout(() => this.beep(660, 0.12, 'triangle'), 80);
    setTimeout(() => this.beep(780, 0.18, 'triangle'), 160);
  }

  error() {
    this.beep(180, 0.12, 'sawtooth');
    setTimeout(() => this.beep(130, 0.2, 'sawtooth'), 100);
  }

  logro() {
    const notas = [520, 650, 780, 1040];
    notas.forEach((n, idx) => {
      setTimeout(() => this.beep(n, 0.12, 'sine'), idx * 80);
    });
  }
}

class SistemaGamificacion {
  constructor() {
    this.xp = (typeof localStorage !== 'undefined' && localStorage.getItem('alma_xp')) 
      ? parseInt(localStorage.getItem('alma_xp'), 10) 
      : 0;
    this.logros = (typeof localStorage !== 'undefined' && localStorage.getItem('alma_logros')) 
      ? JSON.parse(localStorage.getItem('alma_logros')) 
      : [];
    this.audio = new AudioSintetizador();
    this.actualizarUI();
  }

  sumarXP(puntos, motivo = '') {
    this.xp += puntos;
    if (typeof localStorage !== 'undefined') localStorage.setItem('alma_xp', this.xp);
    this.audio.acierto();
    this.actualizarUI();
    this.mostrarNotificacion(`+${puntos} XP &bull; ${motivo}`);
    this.verificarNivel();
  }

  obtenerNivel() {
    if (this.xp < 100) return { nivel: 1, rango: 'Principiante', min: 0, max: 100 };
    if (this.xp < 300) return { nivel: 2, rango: 'Desarrollador', min: 100, max: 300 };
    if (this.xp < 600) return { nivel: 3, rango: 'Ingeniero de Sistemas', min: 300, max: 600 };
    if (this.xp < 1000) return { nivel: 4, rango: 'Especialista en Memoria', min: 600, max: 1000 };
    return { nivel: 5, rango: 'Arquitecto de Compiladores', min: 1000, max: 2500 };
  }

  desbloquearLogro(id, titulo, desc) {
    if (!this.logros.includes(id)) {
      this.logros.push(id);
      if (typeof localStorage !== 'undefined') {
        localStorage.setItem('alma_logros', JSON.stringify(this.logros));
      }
      this.audio.logro();
      this.mostrarNotificacion(`[LOGRO]: ${titulo}`);
    }
  }

  mostrarNotificacion(texto) {
    if (typeof document === 'undefined') return;
    let toast = document.getElementById('alma-toast');
    if (!toast) {
      toast = document.createElement('div');
      toast.id = 'alma-toast';
      toast.style.cssText = `
        position: fixed;
        bottom: 24px;
        right: 24px;
        background: #0d0b16;
        border: 1px solid rgba(255, 181, 71, 0.35);
        color: #f1f2f6;
        padding: 10px 16px;
        border-radius: 4px;
        font-family: 'JetBrains Mono', monospace;
        font-size: 0.78rem;
        box-shadow: 0 10px 25px rgba(0,0,0,0.7);
        z-index: 10000;
        transition: opacity 0.2s, transform 0.2s;
        opacity: 0;
        transform: translateY(8px);
        display: flex;
        align-items: center;
        gap: 8px;
      `;
      document.body.appendChild(toast);
    }
    toast.innerHTML = `<span class="status-dot status-dot-amber"></span> <div>${texto}</div>`;
    toast.style.opacity = '1';
    toast.style.transform = 'translateY(0)';
    setTimeout(() => {
      toast.style.opacity = '0';
      toast.style.transform = 'translateY(8px)';
    }, 3000);
  }

  actualizarUI() {
    if (typeof document === 'undefined') return;
    const info = this.obtenerNivel();
    const badge = document.getElementById('navXpDisplay');
    if (badge) {
      badge.innerHTML = `<span class="status-dot status-dot-amber"></span> <span>XP: ${this.xp} &bull; NIVEL ${info.nivel}</span>`;
    }
  }

  verificarNivel() {
    if (this.xp >= 100) this.desbloquearLogro('primer_paso', 'Inicialización', '100 XP en el laboratorio');
    if (this.xp >= 300) this.desbloquearLogro('ingeniero', 'Ingeniería Nominal', 'Nivel 2 alcanzado');
    if (this.xp >= 600) this.desbloquearLogro('experto_memoria', 'Control de Heap/Stack', 'Dominio de asignación de memoria');
  }
}

window.gamificacion = new SistemaGamificacion();

/* ==========================================================================
   JUEGO 1: INSPECCIÓN DE MEMORIA (VALOR VS REFERENCIA)
   ========================================================================== */
class JuegoMemoria {
  constructor() {
    this.indicePregunta = 0;
    this.preguntas = [
      {
        codigo: `estructura Vector2D\n    x: entero\n    y: entero\nfin\n\na = Vector2D(10, 20)\nb = a\nb.x = 99\n\n// Valor resultante de a.x:`,
        tipo: 'estructura',
        opciones: ['10', '99', 'nulo', 'Fallo de compilación'],
        correcta: 0,
        explicacion: `Semántica por valor: 'estructura' produce una copia independiente de la memoria en la pila. La mutación de b.x no propaga alteraciones a a.x.`,
        stack: [
          { nombre: '0x7FFC01 &bull; a', valor: '{x: 10, y: 20}', celda: 'Pila: Instancia A' },
          { nombre: '0x7FFC10 &bull; b', valor: '{x: 99, y: 20}', celda: 'Pila: Copia B' }
        ]
      },
      {
        codigo: `modelo Servidor\n    puerto: entero\nfin\n\ns1 = Servidor(8080)\ns2 = s1\ns2.puerto = 3000\n\n// Valor resultante de s1.puerto:`,
        tipo: 'modelo',
        opciones: ['8080', '3000', '0', 'Fallo de puntero'],
        correcta: 1,
        explicacion: `Semántica por referencia: 'modelo' comparte el puntero al heap. Ambas variables direccionan la misma posición de memoria.`,
        stack: [
          { nombre: '0x7FFC20 &bull; s1', valor: 'PTR -> 0x004A80', celda: 'Puntero Heap 1' },
          { nombre: '0x7FFC28 &bull; s2', valor: 'PTR -> 0x004A80', celda: 'Puntero Heap 2 (Compartido)' }
        ]
      },
      {
        codigo: `estructura Color\n    r: entero\nfin\n\nfuncion oscurecer(c: Color)\n    c.r = 0\nfin\n\nmi_color = Color(255)\noscurecer(mi_color)\n\n// Valor de mi_color.r tras el retorno:`,
        tipo: 'estructura',
        opciones: ['0', '255', 'nulo', 'Error'],
        correcta: 1,
        explicacion: `Paso por valor en llamada a función: la estructura se duplica en el marco de activación de la función y se destruye al retornar.`,
        stack: [
          { nombre: '0x7FFC30 &bull; mi_color', valor: '{r: 255}', celda: 'Marco Principal' },
          { nombre: '0x7FFC08 &bull; c (copia)', valor: '{r: 0}', celda: 'Marco de Función (Liberado)' }
        ]
      },
      {
        codigo: `fijo BUFFER_SIZE = 1024\nBUFFER_SIZE = 2048\n\n// Resultado del análisis semántico:`,
        tipo: 'fijo',
        opciones: [
          'Reasignación exitosa a 2048',
          'Silenciado en ejecución',
          'Error semántico: constante fija inmutable',
          'Conversión implícita de tipo'
        ],
        correcta: 2,
        explicacion: `Inmutabilidad estricta: 'fijo' define una constante inmutable evaluada en fase semántica. El compilador rechaza cualquier reasignación.`,
        stack: [
          { nombre: '0x004010 &bull; BUFFER_SIZE', valor: '1024', celda: 'Segmento de Constantes (.rdata)' }
        ]
      }
    ];
  }

  iniciar() {
    this.indicePregunta = 0;
    this.renderizar();
  }

  renderizar() {
    const contenedor = document.getElementById('memoryGameContenido');
    if (!contenedor) return;

    if (this.indicePregunta >= this.preguntas.length) {
      contenedor.innerHTML = `
        <div style="text-align: center; padding: 2.5rem 1.5rem;">
          <div class="tech-badge tech-badge-amber" style="margin-bottom: 1rem;">VERIFICACIÓN COMPLETADA</div>
          <h3 style="font-size: 1.4rem; margin-bottom: 0.75rem; color: #fff;">Protocolo de Memoria Validado</h3>
          <p style="margin-bottom: 1.5rem; max-width: 600px; margin-left: auto; margin-right: auto;">Ha superado las pruebas de predicción de direccionamiento en Pila y Montículo para los tipos <code>estructura</code> y <code>modelo</code>.</p>
          <button class="btn-primary" onclick="window.juegoMemoria.iniciar()">Reiniciar Inspección</button>
        </div>
      `;
      window.gamificacion.desbloquearLogro('maestro_memoria', 'Dominio de Memoria', 'Inspección completada con éxito');
      return;
    }

    const p = this.preguntas[this.indicePregunta];
    contenedor.innerHTML = `
      <div class="memory-game-layout">
        <div>
          <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem;">
            <span class="tech-badge ${p.tipo === 'estructura' ? 'tech-badge-violet' : 'tech-badge-amber'}">
              CASO ${this.indicePregunta + 1} DE ${this.preguntas.length} &bull; ${p.tipo.toUpperCase()}
            </span>
          </div>
          <pre class="code-pre" style="border-radius: 6px;"><code>${this.escaparHtml(p.codigo)}</code></pre>
          <div class="quiz-options-list">
            ${p.opciones.map((op, idx) => `
              <button class="quiz-option-btn" onclick="window.juegoMemoria.responder(${idx})">
                <span style="font-family: var(--font-mono); color: var(--text-dim); margin-right: 8px;">[0${idx + 1}]</span>
                ${this.escaparHtml(op)}
              </button>
            `).join('')}
          </div>
          <div id="memoryFeedback" style="margin-top: 15px; font-family: var(--font-mono); font-size: 0.85rem; line-height: 1.5;"></div>
        </div>

        <div class="memory-viz">
          <div class="memory-lane-title">Estado de Pila (Stack) y Montículo (Heap)</div>
          <div class="memory-lane">
            <div class="memory-cells-container">
              ${p.stack.map(s => `
                <div class="memory-cell">
                  <div class="memory-cell-label">${s.nombre}</div>
                  <div class="memory-cell-val">${s.valor}</div>
                  <div style="font-family: var(--font-mono); font-size: 0.68rem; color: var(--text-dim); margin-top: 4px;">${s.celda}</div>
                </div>
              `).join('')}
            </div>
          </div>
          <div class="doc-callout" style="font-size: 0.82rem; margin-top: 1.5rem;">
            <strong>Principio de Diseño:</strong> Las estructuras operan bajo aislamiento de copia; los modelos operan bajo semántica de puntero compartido.
          </div>
        </div>
      </div>
    `;
  }

  responder(idx) {
    const p = this.preguntas[this.indicePregunta];
    const feedback = document.getElementById('memoryFeedback');
    const botones = document.querySelectorAll('.quiz-option-btn');

    botones.forEach(b => b.disabled = true);

    if (idx === p.correcta) {
      botones[idx].classList.add('correct');
      feedback.innerHTML = `<span style="color: var(--status-success);">[CORRECTO]:</span> ${p.explicacion}`;
      window.gamificacion.sumarXP(25, 'Inspección de memoria correcta');
      setTimeout(() => {
        this.indicePregunta++;
        this.renderizar();
      }, 2400);
    } else {
      botones[idx].classList.add('wrong');
      botones[p.correcta].classList.add('correct');
      feedback.innerHTML = `<span style="color: var(--status-error);">[INCORRECTO]:</span> ${p.explicacion}`;
      window.gamificacion.audio.error();
      setTimeout(() => {
        this.indicePregunta++;
        this.renderizar();
      }, 3400);
    }
  }

  escaparHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
}

/* ==========================================================================
   JUEGO 2: DEPURACIÓN SEMÁNTICA (CAZA-BUGS)
   ========================================================================== */
class JuegoCazaBugs {
  constructor() {
    this.nivel = 0;
    this.niveles = [
      {
        titulo: "Caso 01: Delimitación de Ámbito Abierta",
        lineas: [
          "funcion calcular_doble(x: entero) -> entero",
          "    resultado = x * 2",
          "    retornar resultado",
          "// Fin de bloque no declarado"
        ],
        lineaBug: 3,
        opciones: [
          "Insertar 'fin' para delimitar el cierre de la función",
          "Modificar signatura a 'x: decimal'",
          "Añadir punto y coma al final de x * 2",
          "Utilizar instrucción 'return'"
        ],
        correcta: 0,
        explicacion: "En Alma todos los bloques indentados (funcion, si, mientras, para, estructura, modelo) requieren la palabra de cierre explícita 'fin'."
      },
      {
        titulo: "Caso 02: Mutación de Símbolo Inmutable",
        lineas: [
          "fijo VELOCIDAD_LUZ = 300000",
          "factor = 2",
          "VELOCIDAD_LUZ = 600000",
          "imprimir(VELOCIDAD_LUZ)"
        ],
        lineaBug: 2,
        opciones: [
          "Las constantes 'fijo' son de solo lectura y no admiten reasignación",
          "El identificador debe escribirse en minúsculas",
          "La función imprimir no acepta tipos numéricos",
          "Falta declarar el tipo con 'fijo: entero'"
        ],
        correcta: 0,
        explicacion: "El término 'fijo' define una constante inmutable evaluada estáticamente por el compilador."
      },
      {
        titulo: "Caso 03: Función Intrínseca No Correspondiente",
        lineas: [
          "registros = [10, 20, 30]",
          "registros.append(40)",
          "imprimir(longitud(registros))",
          "imprimir(registros[0])"
        ],
        lineaBug: 1,
        opciones: [
          "Reemplazar por 'agregar(registros, 40)'",
          "Reducir tamaño de lista por exceder capacidad fija",
          "Indexar a partir de base 1",
          "Declarar tipo explícito de colección"
        ],
        correcta: 0,
        explicacion: "La librería estándar utiliza nombres canónicos en español: 'agregar(lista, elemento)' y 'longitud(lista)'."
      }
    ];
  }

  iniciar() {
    this.nivel = 0;
    this.renderizar();
  }

  renderizar() {
    const contenedor = document.getElementById('cazaBugsContenido');
    if (!contenedor) return;

    if (this.nivel >= this.niveles.length) {
      contenedor.innerHTML = `
        <div style="text-align: center; padding: 2.5rem 1.5rem;">
          <div class="tech-badge tech-badge-amber" style="margin-bottom: 1rem;">AUDITORÍA SUPERADA</div>
          <h3 style="font-size: 1.4rem; margin-bottom: 0.75rem; color: #fff;">Diagnósticos de Compilador Superados</h3>
          <p style="margin-bottom: 1.5rem; max-width: 600px; margin-left: auto; margin-right: auto;">Todos los defectos sintácticos y semánticos fueron aislados y corregidos satisfactoriamente.</p>
          <button class="btn-primary" onclick="window.juegoCazaBugs.iniciar()">Reiniciar Auditoría</button>
        </div>
      `;
      window.gamificacion.desbloquearLogro('cazador_bugs', 'Analista de AST', 'Completó los casos de depuración');
      return;
    }

    const n = this.niveles[this.nivel];
    contenedor.innerHTML = `
      <div>
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem;">
          <span style="font-family: var(--font-mono); font-size: 0.85rem; color: #fff; font-weight: 600;">${n.titulo}</span>
          <span class="tech-badge tech-badge-amber">CASO ${this.nivel + 1} DE ${this.niveles.length}</span>
        </div>
        <p style="margin-bottom: 1rem; font-size: 0.88rem; color: var(--text-muted);">
          Seleccione la línea que incumple las especificaciones de compilación de Alma:
        </p>

        <div class="bug-code-display">
          ${n.lineas.map((l, idx) => `
            <div class="bug-code-line" id="bugLine-${idx}" onclick="window.juegoCazaBugs.seleccionarLinea(${idx})">
              <span class="line-num">${idx + 1}</span>
              <span class="line-content">${this.escaparHtml(l)}</span>
            </div>
          `).join('')}
        </div>

        <div id="cazaBugsOpciones" style="display: none; margin-top: 1.5rem;">
          <div style="font-family: var(--font-mono); font-size: 0.8rem; text-transform: uppercase; color: var(--text-dim); margin-bottom: 0.6rem;">
            Resolución Técnica Propuesta
          </div>
          <div class="quiz-options-list">
            ${n.opciones.map((op, idx) => `
              <button class="quiz-option-btn" onclick="window.juegoCazaBugs.resolver(${idx})">
                <span style="font-family: var(--font-mono); color: var(--text-dim); margin-right: 8px;">[0${idx + 1}]</span>
                ${this.escaparHtml(op)}
              </button>
            `).join('')}
          </div>
        </div>
        <div id="cazaBugsFeedback" style="margin-top: 15px; font-family: var(--font-mono); font-size: 0.85rem;"></div>
      </div>
    `;
  }

  seleccionarLinea(idx) {
    document.querySelectorAll('.bug-code-line').forEach(el => el.classList.remove('selected'));
    const n = this.niveles[this.nivel];
    const feedback = document.getElementById('cazaBugsFeedback');
    const panelOpciones = document.getElementById('cazaBugsOpciones');

    const lineaEl = document.getElementById(`bugLine-${idx}`);
    if (lineaEl) lineaEl.classList.add('selected');

    if (idx === n.lineaBug) {
      window.gamificacion.audio.acierto();
      feedback.innerHTML = `<span style="color: var(--status-success);">[DIAGNÓSTICO EXACTO]:</span> Defecto localizado en línea ${idx + 1}. Seleccione corrección abajo.`;
      panelOpciones.style.display = 'block';
    } else {
      window.gamificacion.audio.error();
      feedback.innerHTML = `<span style="color: var(--status-error);">[LÍNEA NOMINAL]:</span> La línea seleccionada cumple las reglas de la gramática.`;
      panelOpciones.style.display = 'none';
    }
  }

  resolver(idx) {
    const n = this.niveles[this.nivel];
    const feedback = document.getElementById('cazaBugsFeedback');
    const botones = document.querySelectorAll('#cazaBugsOpciones .quiz-option-btn');

    botones.forEach(b => b.disabled = true);

    if (idx === n.correcta) {
      botones[idx].classList.add('correct');
      feedback.innerHTML = `<span style="color: var(--status-success);">[CORRECCIÓN APLICADA]:</span> ${n.explicacion}`;
      window.gamificacion.sumarXP(35, 'Defecto de compilación resuelto');
      setTimeout(() => {
        this.nivel++;
        this.renderizar();
      }, 2400);
    } else {
      botones[idx].classList.add('wrong');
      botones[n.correcta].classList.add('correct');
      feedback.innerHTML = `<span style="color: var(--status-error);">[CORRECCIÓN FALLIDA]:</span> ${n.explicacion}`;
      window.gamificacion.audio.error();
      setTimeout(() => {
        this.nivel++;
        this.renderizar();
      }, 3400);
    }
  }

  escaparHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
}

/* ==========================================================================
   JUEGO 3: NAVEGACIÓN AUTÓNOMA (CANVAS 2D)
   ========================================================================== */
class JuegoLaberinto {
  constructor() {
    this.canvas = null;
    this.ctx = null;
    this.tamanoCelda = 42;
    this.dron = { x: 1, y: 1, dir: 1 }; // 0: Norte, 1: Este, 2: Sur, 3: Oeste
    this.meta = { x: 7, y: 7 };
    this.obstaculos = [
      { x: 3, y: 1 }, { x: 3, y: 2 }, { x: 3, y: 3 },
      { x: 5, y: 4 }, { x: 5, y: 5 }, { x: 5, y: 6 },
      { x: 1, y: 4 }, { x: 2, y: 4 }
    ];
    this.animando = false;
    this.acciones = [];
  }

  iniciar() {
    this.canvas = document.getElementById('mazeCanvas');
    if (!this.canvas) return;
    this.ctx = this.canvas.getContext('2d');
    this.reiniciarDron();
    this.dibujar();
  }

  reiniciarDron() {
    this.dron = { x: 1, y: 1, dir: 1 };
    this.animando = false;
    this.acciones = [];
    this.dibujar();
    const status = document.getElementById('mazeStatus');
    if (status) status.innerHTML = '[TELEMETRÍA]: Posición nominal (X: 01, Y: 01, DIR: 90°). Listo para ejecutar trayectoria.';
  }

  dibujar() {
    if (!this.ctx) return;
    const w = this.canvas.width;
    const h = this.canvas.height;
    this.ctx.clearRect(0, 0, w, h);

    // Cuadrícula de radar
    this.ctx.strokeStyle = 'rgba(255, 255, 255, 0.04)';
    this.ctx.lineWidth = 1;
    for (let x = 0; x <= w; x += this.tamanoCelda) {
      this.ctx.beginPath();
      this.ctx.moveTo(x, 0);
      this.ctx.lineTo(x, h);
      this.ctx.stroke();
    }
    for (let y = 0; y <= h; y += this.tamanoCelda) {
      this.ctx.beginPath();
      this.ctx.moveTo(0, y);
      this.ctx.lineTo(w, y);
      this.ctx.stroke();
    }

    // Dibujar obstáculos (Puntos de colisión)
    this.ctx.fillStyle = '#ef4444';
    for (const obs of this.obstaculos) {
      this.ctx.beginPath();
      this.ctx.rect(
        obs.x * this.tamanoCelda + 4,
        obs.y * this.tamanoCelda + 4,
        this.tamanoCelda - 8,
        this.tamanoCelda - 8
      );
      this.ctx.fill();
    }

    // Dibujar Coordenada Objetivo
    this.ctx.fillStyle = '#FFB547';
    this.ctx.beginPath();
    const cx = this.meta.x * this.tamanoCelda + this.tamanoCelda / 2;
    const cy = this.meta.y * this.tamanoCelda + this.tamanoCelda / 2;
    this.ctx.arc(cx, cy, this.tamanoCelda / 3.5, 0, Math.PI * 2);
    this.ctx.fill();

    // Dibujar Rover / Dron
    const dx = this.dron.x * this.tamanoCelda + this.tamanoCelda / 2;
    const dy = this.dron.y * this.tamanoCelda + this.tamanoCelda / 2;
    this.ctx.save();
    this.ctx.translate(dx, dy);
    this.ctx.rotate((this.dron.dir * Math.PI) / 2);

    this.ctx.fillStyle = '#9B85FF';
    this.ctx.beginPath();
    this.ctx.moveTo(0, -this.tamanoCelda / 2.6);
    this.ctx.lineTo(this.tamanoCelda / 3.2, this.tamanoCelda / 3.2);
    this.ctx.lineTo(-this.tamanoCelda / 3.2, this.tamanoCelda / 3.2);
    this.ctx.closePath();
    this.ctx.fill();
    this.ctx.restore();
  }

  ejecutarCodigo() {
    if (this.animando) return;
    this.reiniciarDron();

    const editor = document.getElementById('mazeCodeEditor');
    if (!editor) return;
    const codigo = editor.value;

    const interprete = new InterpreteAlma();
    this.acciones = [];

    interprete.registrarGancho('avanzar', () => {
      this.acciones.push({ tipo: 'avanzar' });
    });
    interprete.registrarGancho('girar_derecha', () => {
      this.acciones.push({ tipo: 'girar_der' });
    });
    interprete.registrarGancho('girar_izquierda', () => {
      this.acciones.push({ tipo: 'girar_izq' });
    });
    interprete.registrarGancho('hay_obstaculo', () => {
      return this.simularHayObstaculo();
    });
    interprete.registrarGancho('no_meta', () => {
      return !(this.dron.x === this.meta.x && this.dron.y === this.meta.y);
    });

    const res = interprete.ejecutar(codigo);
    const status = document.getElementById('mazeStatus');

    if (!res.exito) {
      status.innerHTML = `<span style="color: var(--status-error);">[ERROR DE EVALUACIÓN]: ${res.error}</span>`;
      window.gamificacion.audio.error();
      return;
    }

    this.animando = true;
    this.reproducirSiguienteAccion();
  }

  reproducirSiguienteAccion() {
    if (this.acciones.length === 0) {
      this.animando = false;
      const status = document.getElementById('mazeStatus');
      if (this.dron.x === this.meta.x && this.dron.y === this.meta.y) {
        status.innerHTML = `<span style="color: var(--status-success);">[OBJETIVO ALCANZADO]: Coordenadas (07, 07) verificadas con éxito.</span>`;
        window.gamificacion.sumarXP(50, 'Navegación completada');
        window.gamificacion.desbloquearLogro('navegante_espacial', 'Navegación Autónoma', 'Llegó a la coordenada objetivo');
      } else {
        status.innerHTML = `<span style="color: var(--status-warning);">[DETENIDO]: Secuencia terminada sin alcanzar el punto objetivo.</span>`;
      }
      return;
    }

    const acc = this.acciones.shift();
    if (acc.tipo === 'avanzar') {
      const deltas = [{ x: 0, y: -1 }, { x: 1, y: 0 }, { x: 0, y: 1 }, { x: -1, y: 0 }];
      const nx = this.dron.x + deltas[this.dron.dir].x;
      const ny = this.dron.y + deltas[this.dron.dir].y;

      const colision = this.obstaculos.some(o => o.x === nx && o.y === ny) || nx < 0 || nx >= 10 || ny < 0 || ny >= 10;
      if (colision) {
        this.animando = false;
        window.gamificacion.audio.error();
        document.getElementById('mazeStatus').innerHTML = `<span style="color: var(--status-error);">[COLISIÓN DETECTADA]: Impacto en sector (${nx}, ${ny}). Trayectoria abortada.</span>`;
        return;
      }
      this.dron.x = nx;
      this.dron.y = ny;
      window.gamificacion.audio.beep(600, 0.04, 'square');
    } else if (acc.tipo === 'girar_der') {
      this.dron.dir = (this.dron.dir + 1) % 4;
      window.gamificacion.audio.beep(380, 0.04, 'sine');
    } else if (acc.tipo === 'girar_izq') {
      this.dron.dir = (this.dron.dir + 3) % 4;
      window.gamificacion.audio.beep(380, 0.04, 'sine');
    }

    this.dibujar();
    setTimeout(() => this.reproducirSiguienteAccion(), 170);
  }

  simularHayObstaculo() {
    const deltas = [{ x: 0, y: -1 }, { x: 1, y: 0 }, { x: 0, y: 1 }, { x: -1, y: 0 }];
    const nx = this.dron.x + deltas[this.dron.dir].x;
    const ny = this.dron.y + deltas[this.dron.dir].y;
    return this.obstaculos.some(o => o.x === nx && o.y === ny) || nx < 0 || nx >= 10 || ny < 0 || ny >= 10;
  }
}

window.juegoMemoria = new JuegoMemoria();
window.juegoCazaBugs = new JuegoCazaBugs();
window.juegoLaberinto = new JuegoLaberinto();
