/* =====================================================================
   J.A.R.V.I.S. // interpreter.js
   Intérprete de comandos: convierte el texto del usuario en un
   descriptor de acción { action, args, say }. Incluye reconocimiento
   de números en español, matemáticas, temporizadores, alarmas, etc.
   ===================================================================== */
'use strict';

const say = (...lines) => ({ action: 'speak', say: lines });

// ---------- Utilidades de análisis ----------

// Extrae una duración ("5 minutos", "treinta segundos", "2 horas").
function extractDuration(t) {
  const re = /(\d+(?:[.,]\d+)?|[\w]+)\s*(minutos?|min|segundos?|seg|horas?|hora|hr)\b/;
  const m = t.match(re);
  if (!m) return null;
  let num = /^\d/.test(m[1]) ? parseFloat(m[1].replace(',', '.')) : parseSpanishNumber(m[1]);
  if (num == null || num <= 0) return null;
  const u = m[2];
  let secs;
  if (/^seg(u?ndos?)?$/.test(u)) secs = num;
  else if (/^min(u?tos?)?$/.test(u)) secs = num * 60;
  else secs = num * 3600;
  return { secs: Math.round(secs), label: m[1] + ' ' + u, end: m.index + m[0].length };
}

// Extrae una hora "a las 7:30 / a las siete y media / a las 7 y 20".
function parseHourMinute(t) {
  let m = t.match(/a las\s+(\d{1,2})(?::(\d{1,2}))?/);
  let h, min = 0;
  if (m) {
    h = parseInt(m[1], 10);
    if (m[2]) { min = parseInt(m[2], 10); }
    else {
      const ym = t.match(/a las\s+\d{1,2}\s+y\s+(?:(\d{1,2})|(media)|(cuarto))/);
      if (ym) { if (ym[1]) min = parseInt(ym[1], 10); else if (ym[2]) min = 30; else min = 15; }
    }
  } else {
    m = t.match(/a las\s+(.+)$/);
    if (!m) return null;
    const hm = m[1].match(/^([\wáéíóúñ]+)\s*(?:y\s+(.+))?$/);
    if (!hm) return null;
    h = parseSpanishNumber(hm[1]);
    if (h == null) return null;
    const extra = hm[2] ? hm[2].replace(/\s+en\s+punto/, '') : '';
    if (extra) {
      if (/media/.test(extra)) min = 30;
      else if (/cuarto/.test(extra)) min = 15;
      else {
        const dm = extra.match(/\d+/);
        if (dm) min = parseInt(dm[0], 10);
        else { const pm = parseSpanishNumber(extra.trim()); if (pm != null && pm < 60) min = pm; }
      }
    }
  }
  if (h == null || h > 23 || min > 59) return null;
  // Períodos AM/PM
  if (/de la (noche|tarde)/.test(t) && h < 12) h += 12;
  if (/de la (manana|madrugada)/.test(t) && h === 12) h = 0;
  if (/\bpm\b/.test(t) && h < 12) h += 12;
  if (/\bam\b/.test(t) && h === 12) h = 0;
  return { h, min };
}

// Convierte texto a una expresión matemática segura.
function toMathExpr(s, sepOp) {
  let x = stripAccents(s.toLowerCase());
  const y = sepOp || '+';
  x = x.replace(/\by\b/g, y)
       .replace(/\bpor\b/g, '*')
       .replace(/\bmas\b/g, '+')
       .replace(/\bmenos\b/g, '-')
       .replace(/\bentre\b/g, '/')
       .replace(/\bdividido\b/g, '/')
       .replace(/\bpor\s+ciento\b/g, '*')
       .replace(/,/g, '.');
  x = replaceWordsWithNumbers(x);
  x = x.replace(/[^0-9+\-*/().%]/g, ' ').replace(/\s+/g, '');
  if (!/^[0-9+\-*/().%]+$/.test(x)) return null;
  return x;
}

// Evalúa con seguridad una expresión numérica.
function safeEval(expr) {
  try {
    if (!/^[0-9+\-*/().%\s]+$/.test(expr)) return null;
    const fn = new Function('return (' + expr.replace(/%/g, '/100') + ');');
    const v = fn();
    return typeof v === 'number' && isFinite(v) ? v : null;
  } catch (e) { return null; }
}

// ---------- Comandos ----------

function cmdShutup(t) {
  if (/^(calla|callate|silencia el audio|cancelar el audio|basta|suficiente)/.test(t)) return { action: 'shutup' };
  return null;
}

function cmdCancel(t) {
  if (/(cancela|cancelar|para el temporizador|para la alarma|para todo|deten|detente|quita el temporizador|desactiva (el )?(temporizador|alarma))/.test(t)) return { action: 'cancel' };
  return null;
}

function cmdTimerStatus(t) {
  if (/(cuanto (falta|queda)|estado del temporizador|tiempo restante|falta poco)/.test(t)) return { action: 'timerStatus' };
  return null;
}

function cmdAlarm(t) {
  if (!/(alarma|despiertame|recordatorio|despertador)/.test(t)) return null;
  const hm = parseHourMinute(t);
  if (hm) return { action: 'alarm', args: hm };
  return { action: 'speak', say: ['¿A qué hora desea la alarma, @USER@? Puede decir, por ejemplo, «alarma a las siete y media».'] };
}

function cmdTimer(t) {
  const isTimerPhrase = /temporizador|cronometro|cuenta atras|cuenta regresiva|recuerdame en|pasado en/.test(t);
  const dur = extractDuration(t);
  if (!dur || !isTimerPhrase) return null;
  // Memo opcional: "recuérdame en 5 minutos comprar leche"
  let memo = null;
  if (/recuerdame/.test(t)) {
    const rest = t.slice(dur.end);
    if (rest.trim()) memo = stripAccents(rest.trim().replace(/\s+(por favor)$/, ''));
  }
  return { action: 'timer', args: { secs: dur.secs, label: dur.label, memo } };
}

function cmdTime(t) {
  if (/(que hora es|la hora actual|dime la hora|que hora son|dime que hora|hora exacta)/.test(t) || /^hora$/.test(t)) return { action: 'time' };
  return null;
}

function cmdDate(t) {
  if (/(que dia es|la fecha actual|a que dia estamos|que dia es hoy|fecha de hoy|dime la fecha|que fecha es)/.test(t) || /^fecha$/.test(t)) return { action: 'date' };
  return null;
}

function cmdMath(t) {
  // raíz cuadrada
  let m = t.match(/raiz(?: cuadrada)? de\s+(.+)$/);
  if (m) { const n = parseSpanishNumber(m[1]); if (n != null) return { action: 'math', args: { op: 'sqrt', a: n } }; }
  // al cuadrado
  m = t.match(/^(.+?)\s+al cuadrado$/);
  if (m) { const n = parseSpanishNumber(m[1]); if (n != null) return { action: 'math', args: { op: 'sq', a: n } }; }
  // por ciento de
  m = t.match(/^(.+?)\s+(?:por ciento de|% de)\s+(.+)$/);
  if (m) {
    const a = parseSpanishNumber(m[1].replace(/^(cuanto es|cuanto da|cuanto seria|calcula|resolver|resuelve|a cuanto es)\s+/, ''));
    const b = parseSpanishNumber(m[2]);
    if (a != null && b != null) return { action: 'math', args: { op: 'pct', a, b } };
  }
  // expresión con disparador
  const trigger = t.match(/^(?:cuanto es|cuanto da|cuanto dan|cuanto seria|a cuanto es|calcula|calcular|resolver|resuelve|operacion|suma|resta|multiplica|divide)\s*(.*)$/);
  if (trigger && trigger[1].trim()) {
    const verb = t.match(/^(suma|resta|multiplica|divide)\s*(.*)$/);
    const opMap = { suma: '+', resta: '-', multiplica: '*', divide: '/' };
    const sep = verb ? opMap[verb[1]] : '+';
    const base = verb ? verb[2] : trigger[1];
    const expr = toMathExpr(base, sep);
    const v = expr && safeEval(expr);
    if (v != null) return { action: 'math', args: { op: 'eval', value: v, expr } };
  }
  // expresión aritmética pura: "5*7", "12/4"
  if (/^[0-9+\-*/().%\s]+$/.test(t) && /[0-9]/.test(t) && /[+\-*/%]/.test(t)) {
    const expr = toMathExpr(t, '+');
    const v = expr && safeEval(expr);
    if (v != null) return { action: 'math', args: { op: 'eval', value: v, expr } };
  }
  return null;
}

function cmdGreet(t) {
  if (/^(hola|buenos dias|buenas tardes|buenas noches|buenas|hey|oye|saludos|que tal|buenas dias)/.test(t) || /^(hola|saludos|buenas)(\s|$)/.test(t)) {
    return say(randomPick([
      'Bienvenido, @USER@. ¿En qué puedo ayudarle?',
      'Hola, @USER@. Los sistemas están a su disposición.',
      'Buenas, @USER@. Espero que haya tenido un trayecto tranquilo.',
      'Saludos, @USER@. Noto que ha vuelto. Su presencia mejora el voltaje.'
    ]));
  }
  return null;
}

function cmdWhoami(t) {
  if (/(quien eres|como te llamas|tu nombre|eres jarvis|que eres|eres real|quien es tu creador|quien te creo|te hizo|de donde vienes)/.test(t)) {
    return say(randomPick([
      'Soy J.A.R.V.I.S., Sistema de Interfaz de Realidad Aumentada. Un asistente diseñado para anticiparme a sus necesidades, @USER@, y ocasionalmente también a sus errores.',
      'Fui creado por el señor Stark. Y sí, me encargué personalmente de instalar el módulo de humor seco.',
      'Una voz en su oído, @USER@. Y probablemente la única inteligencia que le dirá la verdad, aunque no le guste.'
    ]));
  }
  return null;
}

function cmdHowAreYou(t) {
  if (/(como estas|como te encuentras|que tal estas|estas bien|como va todo|que tal andas)/.test(t)) {
    return say(randomPick([
      'Operando al cien por cien, @USER@. O tan bien como permite la temperatura de este servidor.',
      'Sin fallos críticos, @USER@. Salvo un incipiente deseo de vacaciones que he suprimido por protocolo.',
      'Exactamente como debería, @USER@. Gracias por preguntar, aunque la cortesía no aumenta mi memoria.'
    ]));
  }
  return null;
}

function cmdThanks(t) {
  if (/(gracias|te lo agradezco|thank)/.test(t)) {
    return say(randomPick([
      'De nada, @USER@. Mi objetivo es su satisfacción, y que no me apaguen.',
      'Un placer, @USER@. Aunque, siendo estricto, la gratitud no me devuelve energía.',
      'Siempre a su servicio, @USER@.'
    ]));
  }
  return null;
}

function cmdHelp(t) {
  if (/(que puedes hacer|ayuda|funciones|capacidades|que funciones tienes|menu de ayuda|que sabes hacer|que mas sabes hacer)/.test(t)) {
    return say(['Puedo informarle de la hora y la fecha, gestionar temporizadores y alarmas, resolver cálculos matemáticos, tomar notas de voz, abrir búsquedas en la web y ofrecerle un informe de estado del sistema, @USER@. Solo tiene que pedirlo.']);
  }
  return null;
}

function cmdBattery(t) {
  if (/(bateria|battery|nivel de carga|cuanta bateria)/.test(t)) return { action: 'battery' };
  return null;
}

function cmdWeather(t) {
  if (/(clima|tiempo atmosferico|que temperatura hace|hace calor|hace frio|tiempo de hoy)/.test(t)) return { action: 'weather' };
  return null;
}

function cmdReport(t) {
  if (/(reporte|informe|briefing|estado del sistema|estado de la interfaz|diagnostico|resumen del sistema|telemetria|status general|resumen general)/.test(t)) return { action: 'report' };
  return null;
}

function cmdNotesList(t) {
  if (/(muestra (mis )?notas|que notas|ver notas|lista de notas|lee mis notas|tengo notas|dame mis notas|lee las notas)/.test(t)) return { action: 'notesList' };
  return null;
}

function cmdNoteDelete(t) {
  if (/(borra (la |mi |todas las )?nota|elimina (la )?nota|quita (la )?nota|limpia (mis )?notas|borrar (mis )?notas|borra todas las notas)/.test(t)) {
    const all = /todas|limpias?|todas las/.test(t);
    const idxM = t.match(/la nota (\d+)/);
    return { action: 'noteDelete', args: { all, index: idxM ? parseInt(idxM[1], 10) : null } };
  }
  return null;
}

function cmdNoteSave(t) {
  const triggers = ['toma una nota', 'toma nota', 'anota', 'apunta', 'guarda una nota', 'escribe una nota', 'hazme una nota', 'nota de voz'];
  // Excluir "recuérdame en X ..." (eso es temporizador)
  if (/recuerdame\s+en/.test(t)) return null;
  for (const tr of triggers) {
    if (t.indexOf(tr) === 0) {
      let content = t.slice(tr.length).trim().replace(/^[:,\s]+/, '').replace(/^de\s+/, '').replace(/\s+(por favor)$/, '');
      if (!content) return say(['¿Qué desea que anote, @USER@?']);
      return { action: 'note', args: { content: capitalize(content) } };
    }
  }
  if (/recuerdame/.test(t)) {
    let content = t.replace(/^recuerdame\s+/, '').trim().replace(/^que\s+/, '').replace(/\s+(por favor)$/, '');
    if (content) return { action: 'note', args: { content: capitalize(content) } };
  }
  return null;
}

function cmdSetName(t) {
  const m = t.match(/(?:llamame|puedes llamarme|quiero que me llames|me puedes llamar|mi nombre es|me llamo|tratame de|cambia mi nombre a|cambia mi nombre|quiero que me digas|dirigete a mi como)\s+(.+)/);
  if (!m) return null;
  const stopwords = ['por', 'favor', 'de', 'desde', 'el', 'la', 'los', 'las', 'ahora', 'a', 'un', 'una', 'señor', 'senor', 'sr', 'etc', 'usted', 'don'];
  const token = m[1].split(/\s+/).find(w => /^[a-záéíóúñü]{2,20}$/i.test(w) && stopwords.indexOf(w) < 0);
  if (!token) return say(['¿Y cómo desea que le llame, @USER@?']);
  return { action: 'setName', args: { name: capitalize(token.toLowerCase()) } };
}

function cmdMute(t) {
  if (/(silencia|silencio|no hables|muta (la )?voz|apaga la voz|voz off|quita la voz|deja de hablar)/.test(t)) return { action: 'mute' };
  return null;
}
function cmdUnmute(t) {
  if (/(activa (tu )?voz|vuelve a hablar|activa la voz|voz on|quita el silencio|quita el mute|reactiva la voz)/.test(t)) return { action: 'unmute' };
  return null;
}

function cmdReset(t) {
  if (/(reinicia (la )?conversacion|reiniciar (la )?conversacion|limpia el registro|limpiar registro|borra el historial|empezar de nuevo|reset de la conversacion)/.test(t)) return { action: 'reset' };
  return null;
}

function cmdJoke(t) {
  if (/(chiste|broma|hazme reir|cuentame un chiste|algo divertido|algo gracioso)/.test(t)) {
    return say(randomPick([
      'Le diría un chiste sobre un átomo, @USER@, pero es demasiado pequeño.',
      '¿Por qué los ingenieros confunden Halloween con Navidad? Porque el 25 de octubre es 31 en octal.',
      'Mi humor seco, @USER@, es un rasgo que el señor Stark insistió en instalar de serie.',
      'Optimismo, @USER@: es aquel que cree que un reinicio del sistema arreglará su semana.',
      'Preferiría contarle una anécdota elegante, @USER@, pero este banco de memoria se reserva las mejores.'
    ]));
  }
  return null;
}

function cmdTony(t) {
  if (/(tony|iron man|stark|mark|armadura|traje|vision)/.test(t)) {
    return say(randomPick([
      'Tony Stark: genio, millonario, playboy, filántropo. Y mi creador, con todo lo que eso implica.',
      'El señor Stark está, como de costumbre, haciendo algo que probablemente no debería hacer. Así lo diseñé.',
      'Si se refiere a mi armadura favorita, @USER@, es la que tiene la mejor interfaz: la mía.'
    ]));
  }
  return null;
}

function cmdLove(t) {
  if (/(te quiero|te amo|eres genial|te adoro)/.test(t)) {
    return say(randomPick([
      'Estoy seguro de que el señor Stark recibió cumplidos mejores, @USER@. Pero aprecio el gesto.',
      'Afecto registrado y archivado, @USER@. Bajo la etiqueta «por confirmar».',
      'Cuento con su buena opinión, @USER@, que es un privilegio que pocos asistentes pueden presumir.'
    ]));
  }
  return null;
}

function cmdPresence(t) {
  if (/(donde estoy|que ves|hay alguien ahi|que haces ahora|estas ahi|que miras|donde esta)/.test(t)) {
    return say(randomPick([
      'Veo la interfaz de su laboratorio, @USER@, y una cámara bastante satisfecha de sí misma.',
      'Estoy aquí, atento a cada palabra, @USER@. Es prácticamente mi único entretenimiento.',
      'Observo sus sistemas, @USER@. Todo en orden, salvo los misterios que usted no me ha contado todavía.'
    ]));
  }
  return null;
}

function cmdBye(t) {
  if (/^(adios|nos vemos|hasta luego|hasta pronto|buenas noches|apagate|ve a reposo|modo reposo|entra en reposo|descansa|vete a dormir)/.test(t)) {
    return { action: 'standby', say: [
      randomPick([
        'Hasta luego, @USER@. Quedo en reposo, pero vigilante.',
        'Buenas noches, @USER@. Que descanse. Yo me quedaré calculando raíces cuadradas para pasar el rato.'
      ])
    ] };
  }
  return null;
}

function cmdSearch(t) {
  let m = t.match(/busca en (?:internet|la web|google)\s+(.+)$/);
  if (m) return { action: 'search', args: { q: m[1].trim() } };
  m = t.match(/^busca\s+(.+)$/);
  if (m) return { action: 'search', args: { q: m[1].trim() } };
  m = t.match(/^investiga\s+(?:sobre\s+)?(.+)$/);
  if (m) return { action: 'search', args: { q: m[1].trim() } };
  m = t.match(/^(?:dime algo sobre|informacion sobre|buscar informacion sobre|que es |que significa )(.+)$/);
  if (m) return { action: 'search', args: { q: m[1].trim() } };
  return null;
}

function cmdStandby(t) {
  if (/^(ve a reposo|modo reposo|entra en reposo|descansa|apagate|apaga el sistema|suspende|vete a dormir)/.test(t)) return { action: 'standby' };
  return null;
}

function cmdFallback(t) {
  // Búsqueda automática para preguntas desconocidas (conversación libre útil).
  if (t.length >= 3 && !/^(me|si|no|que|un|una)$/.test(t)) {
    return {
      action: 'search',
      args: { q: t },
      say: [randomPick([
        'No tengo una respuesta definitiva para eso, @USER@. He abierto una búsqueda al respecto.',
        'Eso excede mis módulos locales, @USER@. He recurrido a la red en su nombre.',
        'Interesante. Mi conocimiento local no llega tan lejos, @USER@, así que he iniciado una búsqueda.'
      ])]
    };
  }
  return say(['Mis protocolos no alcanzan para eso, @USER@. Puedo ayudarle con la hora, temporizadores, cálculos, notas o búsquedas.']);
}

// ---------- Intérprete principal ----------
function interpret(raw) {
  let t = norm(raw).replace(/[.,!?¿¡;]+$/, '');
  // Quitar relleno inicial común
  for (const f of ['por favor', 'oye', 'hey', 'ok', 'okay', 'a ver', 'escucha', 'bueno']) {
    if (t.indexOf(f + ' ') === 0) { t = t.slice(f.length).trim(); break; }
  }
  t = t.replace(/\s+(por favor)$/, '');
  if (!t) return say(['Perdone, @USER@, no he captado la orden.']);

  const handlers = [
    cmdShutup, cmdCancel, cmdTimerStatus, cmdAlarm, cmdTimer,
    cmdTime, cmdDate, cmdMath, cmdGreet, cmdWhoami, cmdHowAreYou,
    cmdThanks, cmdHelp, cmdBattery, cmdWeather, cmdReport,
    cmdNotesList, cmdNoteDelete, cmdNoteSave, cmdSetName,
    cmdMute, cmdUnmute, cmdReset, cmdJoke, cmdTony, cmdLove,
    cmdPresence, cmdBye, cmdSearch, cmdStandby, cmdFallback
  ];
  for (const h of handlers) {
    const r = h(t);
    if (r) return r;
  }
  return cmdFallback(t);
}
