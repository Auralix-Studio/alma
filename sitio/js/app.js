/**
 * ALMA — Controlador Principal de la Aplicación Web
 */

document.addEventListener('DOMContentLoaded', () => {
  // 1. Navegación por pestañas principales (SPA)
  const tabBtns = document.querySelectorAll('.nav-tab-btn');
  const viewSections = document.querySelectorAll('.view-section');

  function cambiarVista(vistaId) {
    tabBtns.forEach(btn => {
      btn.classList.toggle('active', btn.getAttribute('data-view') === vistaId);
    });

    viewSections.forEach(sec => {
      sec.classList.toggle('active', sec.id === `view-${vistaId}`);
    });

    // Inicializaciones bajo demanda
    if (vistaId === 'juegos') {
      window.juegoMemoria.iniciar();
      window.juegoCazaBugs.iniciar();
      window.juegoLaberinto.iniciar();
    }

    // Scroll to top
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  tabBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      const vistaId = btn.getAttribute('data-view');
      cambiarVista(vistaId);
    });
  });

  // Permitir enlaces internos con data-goto
  document.addEventListener('click', (e) => {
    const target = e.target.closest('[data-goto]');
    if (target) {
      e.preventDefault();
      const vista = target.getAttribute('data-goto');
      cambiarVista(vista);
      const sub = target.getAttribute('data-sub');
      if (sub && vista === 'docs') {
        window.gestorDocs.mostrarArticulo(sub);
      }
    }
  });

  // 2. Menú Móvil
  const mobileBtn = document.getElementById('mobileMenuBtn');
  const navLinks = document.getElementById('navLinks');
  if (mobileBtn && navLinks) {
    mobileBtn.addEventListener('click', () => {
      navLinks.classList.toggle('mobile-open');
    });
  }

  // 3. Pestañas de Instalación
  const installTabs = document.querySelectorAll('.install-tab-btn');
  const installCommands = {
    win: 'irm https://raw.githubusercontent.com/Auralix-Studio/alma/main/distribucion/instalar.ps1 | iex',
    linux: 'curl -fsSL https://raw.githubusercontent.com/Auralix-Studio/alma/main/distribucion/instalar.sh | sh',
    termux: 'curl -fsSL https://raw.githubusercontent.com/Auralix-Studio/alma/main/distribucion/instalar.sh | sh'
  };

  installTabs.forEach(tab => {
    tab.addEventListener('click', () => {
      installTabs.forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      const os = tab.getAttribute('data-os');
      const cmdEl = document.getElementById('installCommandText');
      if (cmdEl && installCommands[os]) {
        cmdEl.textContent = installCommands[os];
      }
    });
  });

  // 4. Playground / Sandbox de Alma en Vivo
  const editor = document.getElementById('playgroundEditor');
  const terminal = document.getElementById('playgroundTerminal');
  const btnEjecutar = document.getElementById('btnPlaygroundRun');
  const btnLimpiar = document.getElementById('btnPlaygroundClear');
  const selectEjemplos = document.getElementById('playgroundExamples');
  const metaTime = document.getElementById('playgroundTime');
  const metaSteps = document.getElementById('playgroundSteps');

  const ejemplosCodigo = {
    hola: `// ¡Hola Mundo en Alma!
funcion principal()
    imprimir("¡Hola desde el lenguaje Alma!")
    imprimir("Elimina la barrera del inglés sin perder potencia técnica.")
fin`,

    memoria: `// El gran diferenciador de Alma:
// 'estructura' (se copia) vs 'modelo' (se comparte)

estructura Vector3D
    x: decimal
    y: decimal
    z: decimal
fin

modelo Contador
    total: entero

    funcion incrementar()
        total = total + 1
    fin
fin

funcion principal()
    // 1. Prueba de ESTRUCTURA (por valor)
    v1 = Vector3D(1.0, 2.0, 3.0)
    v2 = v1
    v2.x = 99.0
    imprimir("v1.x sigue siendo:")
    imprimir(v1.x)  // 1.0 (v1 no cambió)

    // 2. Prueba de MODELO (por referencia)
    c1 = Contador(0)
    c2 = c1
    c2.incrementar()
    c2.incrementar()
    imprimir("c1.total ahora vale:")
    imprimir(c1.total)  // 2 (c1 se modificó a través de c2)
fin`,

    factorial: `// Recursión y Tipado Gradual
funcion factorial(n: entero) -> entero
    si n <= 1
        retornar 1
    sino
        retornar n * factorial(n - 1)
    fin
fin

funcion principal()
    para i en rango(7)
        imprimir("Factorial de " + texto(i) + " = " + texto(factorial(i)))
    fin
fin`,

    colecciones: `// Listas y Diccionarios
funcion principal()
    imprimir("--- Listas ---")
    numeros = [10, 20, 30]
    agregar(numeros, 40)
    imprimir("Longitud: " + texto(longitud(numeros)))

    total = 0
    para n en numeros
        total = total + n
    fin
    imprimir("Suma total: " + texto(total))

    imprimir("--- Diccionarios ---")
    inventario = {"manzanas": 5, "naranjas": 8}
    inventario["uvas"] = 15

    si tiene(inventario, "manzanas")
        imprimir("Manzanas en stock: " + texto(inventario["manzanas"]))
    fin
fin`,

    errores: `// Manejo de Errores con intentar / capturar
funcion dividir(a: entero, b: entero) -> entero
    si b == 0
        lanzar error("No es posible dividir entre cero.")
    fin
    retornar a / b
fin

funcion principal()
    intentar
        imprimir("Dividiendo 10 entre 2: " + texto(dividir(10, 2)))
        imprimir("Dividiendo 8 entre 0...")
        imprimir(dividir(8, 0))
    capturar (e)
        imprimir("¡Capturamos un error con éxito!")
        imprimir(e.mensaje)
    fin
fin`
  };

  if (selectEjemplos && editor) {
    selectEjemplos.addEventListener('change', (e) => {
      const clave = e.target.value;
      if (ejemplosCodigo[clave]) {
        editor.value = ejemplosCodigo[clave];
      }
    });
  }

  if (btnEjecutar && editor && terminal) {
    btnEjecutar.addEventListener('click', () => {
      const codigo = editor.value;
      terminal.innerHTML = '<span style="color: #64748b;">Ejecutando con el motor cliente de Alma...</span>';

      setTimeout(() => {
        const interprete = new InterpreteAlma();
        const res = interprete.ejecutar(codigo);

        if (res.exito) {
          terminal.innerHTML = res.salida ? 
            `<span style="color: #4ade80;">${escapar(res.salida)}</span>` : 
            '<span style="color: #94a3b8;">(El programa finalizó correctamente sin imprimir salida)</span>';
          window.gamificacion.sumarXP(10, 'Código ejecutado en Playground');
        } else {
          terminal.innerHTML = `<span style="color: #ef4444; font-weight: bold;">Error en ejecución:</span>\n<span style="color: #fca5a5;">${escapar(res.error)}</span>`;
          window.gamificacion.audio.error();
        }

        if (metaTime) metaTime.textContent = `${res.tiempoMs} ms`;
        if (metaSteps) metaSteps.textContent = `${res.pasos} pasos`;
      }, 50);
    });
  }

  if (btnLimpiar && terminal) {
    btnLimpiar.addEventListener('click', () => {
      terminal.innerHTML = '<span style="color: #64748b;">// Terminal lista. Haz clic en "Ejecutar Programa" para correr código Alma.</span>';
      if (metaTime) metaTime.textContent = '0 ms';
      if (metaSteps) metaSteps.textContent = '0 pasos';
    });
  }

  // 5. Navegación interna entre juegos
  const gameNavBtns = document.querySelectorAll('.game-nav-btn');
  const gameSections = document.querySelectorAll('.game-section');

  gameNavBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      gameNavBtns.forEach(b => b.classList.remove('active'));
      gameSections.forEach(s => s.classList.remove('active'));

      btn.classList.add('active');
      const gameId = btn.getAttribute('data-game');
      const sec = document.getElementById(`sec-${gameId}`);
      if (sec) sec.classList.add('active');

      if (gameId === 'memoria') window.juegoMemoria.iniciar();
      if (gameId === 'cazabugs') window.juegoCazaBugs.iniciar();
      if (gameId === 'laberinto') window.juegoLaberinto.iniciar();
    });
  });

  // Ejecutor del laberinto
  const btnRunMaze = document.getElementById('btnRunMaze');
  const btnResetMaze = document.getElementById('btnResetMaze');
  if (btnRunMaze) {
    btnRunMaze.addEventListener('click', () => window.juegoLaberinto.ejecutarCodigo());
  }
  if (btnResetMaze) {
    btnResetMaze.addEventListener('click', () => window.juegoLaberinto.reiniciarDron());
  }

  function escapar(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
});
