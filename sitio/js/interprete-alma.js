/**
 * Intérprete Ligero de Alma para Navegador (JavaScript ESM / Standalone)
 * Capaz de evaluar programas de Alma con límites de seguridad, tipado y soporte
 * para 'estructura' (copia) vs 'modelo' (referencia).
 */

class InterpreteAlma {
  constructor() {
    this.salida = [];
    this.limitePasos = 50000;
    this.pasosEjecutados = 0;
    this.ganchosExternos = {}; // Para juegos: avanzar(), girar(), etc.
  }

  registrarGancho(nombre, fn) {
    this.ganchosExternos[nombre] = fn;
  }

  ejecutar(codigoFuente) {
    this.salida = [];
    this.pasosEjecutados = 0;
    const tiempoInicio = performance.now();

    try {
      const lineas = this.preprocesar(codigoFuente);
      const ambito = this.crearAmbitoGlobal();
      
      // Primera pasada: recolectar estructuras, modelos y funciones
      this.declararSimbolos(lineas, ambito);

      // Si existe 'principal()', ejecutarla; de lo contrario, ejecutar código al vuelo
      if (ambito.funciones['principal']) {
        this.ejecutarFuncion(ambito.funciones['principal'], [], ambito);
      } else {
        this.ejecutarBloque(lineas, 0, lineas.length, ambito);
      }

      const tiempoFin = performance.now();
      return {
        exito: true,
        salida: this.salida.join('\n'),
        pasos: this.pasosEjecutados,
        tiempoMs: (tiempoFin - tiempoInicio).toFixed(2)
      };
    } catch (err) {
      const tiempoFin = performance.now();
      return {
        exito: false,
        error: err.message,
        salida: this.salida.join('\n'),
        pasos: this.pasosEjecutados,
        tiempoMs: (tiempoFin - tiempoInicio).toFixed(2)
      };
    }
  }

  crearAmbitoGlobal() {
    const ambito = {
      padre: null,
      variables: {},
      constantes: new Set(),
      funciones: {},
      tipos: {}, // 'estructura' (valor) o 'modelo' (referencia)
    };

    // Funciones nativas
    ambito.funciones['imprimir'] = {
      nativa: true,
      ejecutar: (...args) => {
        this.salida.push(args.map(a => this.formatearValor(a)).join(' '));
      }
    };

    ambito.funciones['texto'] = {
      nativa: true,
      ejecutar: (v) => this.formatearValor(v)
    };

    ambito.funciones['longitud'] = {
      nativa: true,
      ejecutar: (v) => {
        if (Array.isArray(v) || typeof v === 'string') return v.length;
        if (typeof v === 'object' && v !== null) return Object.keys(v).length;
        return 0;
      }
    };

    ambito.funciones['agregar'] = {
      nativa: true,
      ejecutar: (lista, elem) => {
        if (Array.isArray(lista)) {
          lista.push(this.clonarSiEsValor(elem));
        }
      }
    };

    ambito.funciones['rango'] = {
      nativa: true,
      ejecutar: (n) => {
        const res = [];
        for (let i = 0; i < n; i++) res.push(i);
        return res;
      }
    };

    ambito.funciones['tiene'] = {
      nativa: true,
      ejecutar: (obj, clave) => {
        if (typeof obj === 'object' && obj !== null) {
          return clave in obj;
        }
        return false;
      }
    };

    ambito.funciones['error'] = {
      nativa: true,
      ejecutar: (msg) => ({ __esError: true, mensaje: String(msg) })
    };

    // Registrar ganchos para juegos interactivos si existen
    for (const [nombre, fn] of Object.entries(this.ganchosExternos)) {
      ambito.funciones[nombre] = { nativa: true, ejecutar: fn };
    }

    return ambito;
  }

  preprocesar(codigo) {
    const lineasCrudas = codigo.split(/\r?\n/);
    const resultado = [];
    for (let i = 0; i < lineasCrudas.length; i++) {
      let texto = lineasCrudas[i];
      // Quitar comentarios //
      const idxComentario = texto.indexOf('//');
      if (idxComentario !== -1) {
        texto = texto.substring(0, idxComentario);
      }
      resultado.push({
        numero: i + 1,
        contenido: texto.trim(),
        original: lineasCrudas[i]
      });
    }
    return resultado;
  }

  declararSimbolos(lineas, ambito) {
    let i = 0;
    while (i < lineas.length) {
      const linea = lineas[i].contenido;
      if (linea.startsWith('funcion ')) {
        const match = linea.match(/^funcion\s+([a-zA-Z_ñÑáéíóúÁÉÍÓÚ][a-zA-Z0-9_ñÑáéíóúÁÉÍÓÚ]*)\s*\((.*?)\)/);
        if (match) {
          const nombre = match[1];
          const paramsStr = match[2].trim();
          const params = paramsStr ? paramsStr.split(',').map(p => p.split(':')[0].trim()) : [];
          const inicioCuerpo = i + 1;
          const finCuerpo = this.buscarFin(lineas, i);
          ambito.funciones[nombre] = {
            nativa: false,
            nombre,
            parametros: params,
            lineas: lineas.slice(inicioCuerpo, finCuerpo),
            lineaDef: lineas[i].numero
          };
          i = finCuerpo;
        }
      } else if (linea.startsWith('estructura ') || linea.startsWith('modelo ')) {
        const esModelo = linea.startsWith('modelo ');
        const nombre = linea.split(/\s+/)[1];
        const inicioCuerpo = i + 1;
        const finCuerpo = this.buscarFin(lineas, i);
        const campos = [];
        const metodos = {};

        for (let j = inicioCuerpo; j < finCuerpo; j++) {
          const l = lineas[j].contenido;
          if (l.startsWith('funcion ')) {
            const mMatch = l.match(/^funcion\s+([a-zA-Z_0-9]+)\s*\((.*?)\)/);
            if (mMatch) {
              const mNombre = mMatch[1];
              const mParams = mMatch[2] ? mMatch[2].split(',').map(p => p.split(':')[0].trim()) : [];
              const mFin = this.buscarFin(lineas, j);
              metodos[mNombre] = {
                parametros: mParams,
                lineas: lineas.slice(j + 1, mFin)
              };
              j = mFin;
            }
          } else if (l.includes(':')) {
            campos.push(l.split(':')[0].trim());
          }
        }

        ambito.tipos[nombre] = {
          esModelo, // true = referencia, false = estructura (valor)
          campos,
          metodos
        };

        i = finCuerpo;
      }
      i++;
    }
  }

  buscarFin(lineas, inicio) {
    let profundidad = 1;
    for (let i = inicio + 1; i < lineas.length; i++) {
      const c = lineas[i].contenido;
      if (
        c.startsWith('funcion ') || 
        c.startsWith('si ') || 
        c.startsWith('mientras ') || 
        c.startsWith('para ') || 
        c.startsWith('estructura ') || 
        c.startsWith('modelo ') ||
        c.startsWith('intentar')
      ) {
        profundidad++;
      } else if (c === 'fin' || c.startsWith('fin ')) {
        profundidad--;
        if (profundidad === 0) return i;
      }
    }
    return lineas.length;
  }

  ejecutarBloque(lineas, inicio, fin, ambito) {
    let i = inicio;
    while (i < fin) {
      this.verificarPasos(lineas[i]?.numero || 0);
      const l = lineas[i];
      if (!l || !l.contenido) {
        i++;
        continue;
      }

      const linea = l.contenido;

      // Retornar
      if (linea.startsWith('retornar ') || linea === 'retornar') {
        const expr = linea.substring(8).trim();
        const val = expr ? this.evaluarExpresion(expr, ambito) : null;
        return { esRetorno: true, valor: val };
      }

      // Lanzar error
      if (linea.startsWith('lanzar ')) {
        const expr = linea.substring(7).trim();
        const errObj = this.evaluarExpresion(expr, ambito);
        throw new Error(errObj?.mensaje || String(errObj));
      }

      // Intentar / Capturar
      if (linea.startsWith('intentar')) {
        let idxCapturar = -1;
        let idxFin = -1;
        let prof = 1;
        for (let j = i + 1; j < fin; j++) {
          const c = lineas[j].contenido;
          if (c.startsWith('intentar') || c.startsWith('si ') || c.startsWith('mientras ') || c.startsWith('para ')) prof++;
          if (prof === 1 && c.startsWith('capturar')) idxCapturar = j;
          if (c === 'fin') {
            prof--;
            if (prof === 0) { idxFin = j; break; }
          }
        }

        if (idxCapturar !== -1 && idxFin !== -1) {
          try {
            const res = this.ejecutarBloque(lineas, i + 1, idxCapturar, ambito);
            if (res && res.esRetorno) return res;
          } catch (e) {
            const capMatch = lineas[idxCapturar].contenido.match(/capturar\s*\((.*?)\)/);
            const varNombre = capMatch ? capMatch[1].trim() : 'e';
            const ambitoCatch = this.crearAmbitoHijo(ambito);
            ambitoCatch.variables[varNombre] = { mensaje: e.message };
            const res = this.ejecutarBloque(lineas, idxCapturar + 1, idxFin, ambitoCatch);
            if (res && res.esRetorno) return res;
          }
          i = idxFin + 1;
          continue;
        }
      }

      // Condicional 'si'
      if (linea.startsWith('si ')) {
        const finSi = this.buscarFin(lineas, i);
        const res = this.ejecutarSi(lineas, i, finSi, ambito);
        if (res && res.esRetorno) return res;
        i = finSi + 1;
        continue;
      }

      // Bucle 'mientras'
      if (linea.startsWith('mientras ')) {
        const condExpr = linea.substring(9).trim();
        const finMientras = this.buscarFin(lineas, i);
        while (this.evaluarExpresion(condExpr, ambito)) {
          this.verificarPasos(l.numero);
          const res = this.ejecutarBloque(lineas, i + 1, finMientras, this.crearAmbitoHijo(ambito));
          if (res && res.esRetorno) return res;
        }
        i = finMientras + 1;
        continue;
      }

      // Bucle 'para'
      if (linea.startsWith('para ')) {
        const match = linea.match(/^para\s+([a-zA-Z_0-9]+)\s+en\s+(.*)$/);
        if (match) {
          const varNombre = match[1];
          const coleccion = this.evaluarExpresion(match[2], ambito);
          const finPara = this.buscarFin(lineas, i);

          if (Array.isArray(coleccion)) {
            for (const elem of coleccion) {
              this.verificarPasos(l.numero);
              const ambitoPara = this.crearAmbitoHijo(ambito);
              ambitoPara.variables[varNombre] = elem;
              const res = this.ejecutarBloque(lineas, i + 1, finPara, ambitoPara);
              if (res && res.esRetorno) return res;
            }
          }
          i = finPara + 1;
          continue;
        }
      }

      // Omitir declaraciones de funciones o tipos (ya procesadas)
      if (linea.startsWith('funcion ') || linea.startsWith('estructura ') || linea.startsWith('modelo ')) {
        i = this.buscarFin(lineas, i) + 1;
        continue;
      }

      // Asignación de constante 'fijo'
      if (linea.startsWith('fijo ')) {
        const resto = linea.substring(5).trim();
        const [izq, der] = resto.split('=').map(s => s.trim());
        const valor = this.evaluarExpresion(der, ambito);
        ambito.variables[izq] = this.clonarSiEsValor(valor);
        ambito.constantes.add(izq);
        i++;
        continue;
      }

      // Asignación de variables o llamadas a métodos
      if (linea.includes('=') && !linea.startsWith('si ') && !linea.startsWith('mientras ')) {
        const partes = linea.split('=');
        const izq = partes[0].trim();
        const der = partes.slice(1).join('=').trim();
        const valor = this.evaluarExpresion(der, ambito);

        if (izq.includes('.')) {
          // Asignación de campo: a.x = 99
          const [objName, prop] = izq.split('.');
          const obj = this.resolverVariable(objName, ambito);
          if (obj && typeof obj === 'object') {
            obj[prop] = this.clonarSiEsValor(valor);
          }
        } else if (izq.includes('[')) {
          // Asignación de índice: l[0] = 5 o dic["clave"] = 10
          const m = izq.match(/^(.*?)\[(.*?)\]$/);
          if (m) {
            const obj = this.evaluarExpresion(m[1], ambito);
            const idx = this.evaluarExpresion(m[2], ambito);
            obj[idx] = this.clonarSiEsValor(valor);
          }
        } else {
          // Asignación simple (con o sin anotación de tipo: edad: entero = 22)
          const varNombre = izq.split(':')[0].trim();
          this.asignarVariable(varNombre, valor, ambito);
        }
        i++;
        continue;
      }

      // Expresión suelta (ej. llamada a función: imprimir("hola"), s.iniciar())
      this.evaluarExpresion(linea, ambito);
      i++;
    }

    return null;
  }

  ejecutarSi(lineas, inicio, fin, ambito) {
    let ramaEjecutada = false;
    let i = inicio;

    while (i < fin) {
      const l = lineas[i].contenido;
      if (l.startsWith('si ') || l.startsWith('sino si ')) {
        const condExpr = l.startsWith('si ') ? l.substring(3).trim() : l.substring(8).trim();
        const proxRama = this.buscarSiguienteRama(lineas, i, fin);
        
        if (!ramaEjecutada && this.evaluarExpresion(condExpr, ambito)) {
          const res = this.ejecutarBloque(lineas, i + 1, proxRama, this.crearAmbitoHijo(ambito));
          if (res && res.esRetorno) return res;
          ramaEjecutada = true;
        }
        i = proxRama;
      } else if (l.startsWith('sino')) {
        if (!ramaEjecutada) {
          const res = this.ejecutarBloque(lineas, i + 1, fin, this.crearAmbitoHijo(ambito));
          if (res && res.esRetorno) return res;
          ramaEjecutada = true;
        }
        break;
      } else {
        break;
      }
    }

    return null;
  }

  buscarSiguienteRama(lineas, inicio, fin) {
    let prof = 1;
    for (let j = inicio + 1; j < fin; j++) {
      const c = lineas[j].contenido;
      if (c.startsWith('si ') || c.startsWith('mientras ') || c.startsWith('para ')) prof++;
      if (c === 'fin') prof--;
      if (prof === 1 && (c.startsWith('sino si ') || c.startsWith('sino'))) {
        return j;
      }
    }
    return fin;
  }

  encontrarOperadorPrincipal(expr, operadores) {
    let paren = 0;
    let corchete = 0;
    let enStr = false;
    for (let i = expr.length - 1; i >= 0; i--) {
      const ch = expr[i];
      if (ch === '"' || ch === "'") enStr = !enStr;
      if (!enStr) {
        if (ch === ')') paren++;
        if (ch === '(') paren--;
        if (ch === ']') corchete++;
        if (ch === '[') corchete--;
        if (paren === 0 && corchete === 0) {
          for (const op of operadores) {
            if (expr.startsWith(op, i)) {
              const izq = expr.substring(0, i).trim();
              const der = expr.substring(i + op.length).trim();
              if (izq && der) {
                return { op, izq, der };
              }
            }
          }
        }
      }
    }
    return null;
  }

  evaluarExpresion(expr, ambito) {
    expr = expr.trim();
    if (!expr) return null;

    // Literales booleanos y nulo
    if (expr === 'verdadero') return true;
    if (expr === 'falso') return false;
    if (expr === 'nulo') return null;

    // String literal
    if ((expr.startsWith('"') && expr.endsWith('"')) || (expr.startsWith("'") && expr.endsWith("'"))) {
      return expr.substring(1, expr.length - 1);
    }

    // Array literal [1, 2, 3]
    if (expr.startsWith('[') && expr.endsWith(']')) {
      const contenido = expr.substring(1, expr.length - 1).trim();
      if (!contenido) return [];
      const elems = this.separarArgumentos(contenido);
      return elems.map(e => this.clonarSiEsValor(this.evaluarExpresion(e, ambito)));
    }

    // Diccionario literal {"a": 1}
    if (expr.startsWith('{') && expr.endsWith('}')) {
      const contenido = expr.substring(1, expr.length - 1).trim();
      const obj = {};
      if (!contenido) return obj;
      const pares = this.separarArgumentos(contenido);
      for (const p of pares) {
        const idxDosPuntos = p.indexOf(':');
        if (idxDosPuntos !== -1) {
          const k = p.substring(0, idxDosPuntos).trim();
          const v = p.substring(idxDosPuntos + 1).trim();
          const claveEval = this.evaluarExpresion(k, ambito);
          obj[claveEval] = this.clonarSiEsValor(this.evaluarExpresion(v, ambito));
        }
      }
      return obj;
    }

    // 1. Operadores lógicos (||, &&) fuera de paréntesis
    const opLogico = this.encontrarOperadorPrincipal(expr, ['||', '&&']);
    if (opLogico) {
      const vIzq = this.evaluarExpresion(opLogico.izq, ambito);
      if (opLogico.op === '||') return Boolean(vIzq || this.evaluarExpresion(opLogico.der, ambito));
      if (opLogico.op === '&&') return Boolean(vIzq && this.evaluarExpresion(opLogico.der, ambito));
    }

    // 2. Operadores de comparación (==, !=, <=, >=, <, >) fuera de paréntesis
    const opComp = this.encontrarOperadorPrincipal(expr, ['==', '!=', '<=', '>=', '<', '>']);
    if (opComp) {
      const vIzq = this.evaluarExpresion(opComp.izq, ambito);
      const vDer = this.evaluarExpresion(opComp.der, ambito);
      switch (opComp.op) {
        case '==': return vIzq === vDer;
        case '!=': return vIzq !== vDer;
        case '<=': return vIzq <= vDer;
        case '>=': return vIzq >= vDer;
        case '<': return vIzq < vDer;
        case '>': return vIzq > vDer;
      }
    }

    // 3. Aditivos (+, -) fuera de paréntesis
    const opAditivo = this.encontrarOperadorPrincipal(expr, ['+', '-']);
    if (opAditivo) {
      const vIzq = this.evaluarExpresion(opAditivo.izq, ambito);
      const vDer = this.evaluarExpresion(opAditivo.der, ambito);
      if (opAditivo.op === '+') return vIzq + vDer;
      if (opAditivo.op === '-') return vIzq - vDer;
    }

    // 4. Multiplicativos (*, /, %) fuera de paréntesis
    const opMult = this.encontrarOperadorPrincipal(expr, ['*', '/', '%']);
    if (opMult) {
      const vIzq = this.evaluarExpresion(opMult.izq, ambito);
      const vDer = this.evaluarExpresion(opMult.der, ambito);
      if (opMult.op === '*') return vIzq * vDer;
      if (opMult.op === '/') {
        if (vDer === 0) throw new Error("División entre cero");
        return Math.floor(vIzq / vDer);
      }
      if (opMult.op === '%') return vIzq % vDer;
    }

    // Número literal
    if (!isNaN(expr)) {
      return expr.includes('.') ? parseFloat(expr) : parseInt(expr, 10);
    }

    // Llamada a método: obj.metodo(args)
    if (expr.endsWith(')')) {
      const idxParen = expr.indexOf('(');
      if (idxParen !== -1) {
        const parteIzquierda = expr.substring(0, idxParen).trim();
        const argsStr = expr.substring(idxParen + 1, expr.length - 1).trim();
        const args = argsStr ? this.separarArgumentos(argsStr).map(a => this.evaluarExpresion(a, ambito)) : [];

        if (parteIzquierda.includes('.')) {
          const [objName, metodoNombre] = parteIzquierda.split('.').map(s => s.trim());
          const obj = this.resolverVariable(objName, ambito);
          if (obj && obj.__tipo && obj.__tipo.metodos[metodoNombre]) {
            return this.ejecutarMetodo(obj, obj.__tipo.metodos[metodoNombre], args, ambito);
          }
        } else {
          // Constructor de tipo
          if (ambito.tipos && ambito.tipos[parteIzquierda]) {
            return this.instanciarTipo(ambito.tipos[parteIzquierda], args);
          }
          // Función
          const fn = this.resolverFuncion(parteIzquierda, ambito);
          if (fn) {
            if (fn.nativa) return fn.ejecutar(...args);
            return this.ejecutarFuncion(fn, args, ambito);
          }
        }
      }
    }

    // Acceso a propiedad de objeto: obj.propiedad (sin paréntesis)
    if (expr.includes('.') && !expr.includes('(')) {
      const [objName, prop] = expr.split('.').map(s => s.trim());
      const obj = this.resolverVariable(objName, ambito);
      return obj ? obj[prop] : null;
    }

    // Indexación: coleccion[idx]
    if (expr.includes('[') && expr.endsWith(']')) {
      const m = expr.match(/^(.*?)\[(.*?)\]$/);
      if (m) {
        const obj = this.evaluarExpresion(m[1], ambito);
        const idx = this.evaluarExpresion(m[2], ambito);
        return obj ? obj[idx] : null;
      }
    }

    // Variable simple
    return this.resolverVariable(expr, ambito);
  }

  separarArgumentos(cadena) {
    const args = [];
    let nivelParen = 0;
    let nivelCorchete = 0;
    let enString = false;
    let actual = '';

    for (let i = 0; i < cadena.length; i++) {
      const ch = cadena[i];
      if (ch === '"' || ch === "'") enString = !enString;
      if (!enString) {
        if (ch === '(') nivelParen++;
        if (ch === ')') nivelParen--;
        if (ch === '[') nivelCorchete++;
        if (ch === ']') nivelCorchete--;
        if (ch === ',' && nivelParen === 0 && nivelCorchete === 0) {
          args.push(actual.trim());
          actual = '';
          continue;
        }
      }
      actual += ch;
    }
    if (actual.trim()) args.push(actual.trim());
    return args;
  }

  instanciarTipo(tipoDef, args) {
    const instancia = {
      __esModelo: tipoDef.esModelo,
      __tipo: tipoDef
    };
    for (let i = 0; i < tipoDef.campos.length; i++) {
      const campo = tipoDef.campos[i];
      instancia[campo] = args[i] !== undefined ? this.clonarSiEsValor(args[i]) : null;
    }
    return instancia;
  }

  clonarSiEsValor(val) {
    if (val && typeof val === 'object') {
      // Si es un modelo, NO se clona (es por referencia)
      if (val.__esModelo) {
        return val;
      }
      // Si es estructura (valor), se hace copia profunda
      if (val.__esModelo === false) {
        const copia = { ...val };
        for (const k of Object.keys(copia)) {
          copia[k] = this.clonarSiEsValor(copia[k]);
        }
        return copia;
      }
    }
    return val;
  }

  ejecutarMetodo(instancia, metodo, args, ambitoPadre) {
    const ambitoMetodo = this.crearAmbitoHijo(ambitoPadre);
    ambitoMetodo.variables['yo'] = instancia;
    // self implícito: exponer campos en el ámbito
    for (const [k, v] of Object.entries(instancia)) {
      if (!k.startsWith('__')) {
        ambitoMetodo.variables[k] = v;
      }
    }
    for (let i = 0; i < metodo.parametros.length; i++) {
      ambitoMetodo.variables[metodo.parametros[i]] = args[i];
    }

    const res = this.ejecutarBloque(metodo.lineas, 0, metodo.lineas.length, ambitoMetodo);
    // Sincronizar campos modificados de vuelta a la instancia
    for (const k of Object.keys(instancia)) {
      if (!k.startsWith('__') && ambitoMetodo.variables[k] !== undefined) {
        instancia[k] = ambitoMetodo.variables[k];
      }
    }
    return res && res.esRetorno ? res.valor : null;
  }

  ejecutarFuncion(fn, args, ambitoLlamador) {
    const ambitoFn = this.crearAmbitoHijo(ambitoLlamador);
    for (let i = 0; i < fn.parametros.length; i++) {
      ambitoFn.variables[fn.parametros[i]] = this.clonarSiEsValor(args[i]);
    }
    const res = this.ejecutarBloque(fn.lineas, 0, fn.lineas.length, ambitoFn);
    return res && res.esRetorno ? res.valor : null;
  }

  asignarVariable(nombre, valor, ambito) {
    let curr = ambito;
    while (curr) {
      if (curr.constantes && curr.constantes.has(nombre)) {
        throw new Error(`No se puede reasignar la constante 'fijo ${nombre}'`);
      }
      if (nombre in curr.variables) {
        curr.variables[nombre] = this.clonarSiEsValor(valor);
        return;
      }
      curr = curr.padre;
    }
    // Si no existía, definirla en el ámbito actual
    ambito.variables[nombre] = this.clonarSiEsValor(valor);
  }

  resolverVariable(nombre, ambito) {
    let curr = ambito;
    while (curr) {
      if (nombre in curr.variables) return curr.variables[nombre];
      curr = curr.padre;
    }
    return null;
  }

  resolverFuncion(nombre, ambito) {
    let curr = ambito;
    while (curr) {
      if (curr.funciones && curr.funciones[nombre]) return curr.funciones[nombre];
      curr = curr.padre;
    }
    return null;
  }

  crearAmbitoHijo(padre) {
    return {
      padre,
      variables: {},
      constantes: new Set(),
      funciones: padre.funciones,
      tipos: padre.tipos
    };
  }

  verificarPasos(numLinea) {
    this.pasosEjecutados++;
    if (this.pasosEjecutados > this.limitePasos) {
      throw new Error(`Límite de ejecución excedido en línea ${numLinea}. ¿Bucle infinito?`);
    }
  }

  formatearValor(v) {
    if (v === null || v === undefined) return 'nulo';
    if (typeof v === 'boolean') return v ? 'verdadero' : 'falso';
    if (Array.isArray(v)) return `[${v.map(e => this.formatearValor(e)).join(', ')}]`;
    if (typeof v === 'object') {
      if (v.__esError) return `Error: ${v.mensaje}`;
      if (v.__tipo) {
        const props = Object.entries(v)
          .filter(([k]) => !k.startsWith('__'))
          .map(([k, val]) => `${k}: ${this.formatearValor(val)}`)
          .join(', ');
        return `{${props}}`;
      }
      const props = Object.entries(v).map(([k, val]) => `"${k}": ${this.formatearValor(val)}`).join(', ');
      return `{${props}}`;
    }
    return String(v);
  }
}

// Exportar globalmente para navegador
window.InterpreteAlma = InterpreteAlma;
