/* =====================================================================
   J.A.R.V.I.S. // actions.js
   Ejecución real de las acciones interpretadas: hora, fecha, temporizadores,
   alarmas, cálculos, búsquedas, notas, reporte de sistema, nombre, voz,
   reinicio, reposo, etc.
   ===================================================================== */
'use strict';

const Actions = {

  // Ejecuta un descriptor de acción y devuelve las líneas a decir (o null).
  execute(d) {
    switch (d.action) {
      case 'speak': return null;
      case 'time': return this.time();
      case 'date': return this.date();
      case 'report': return this.report();
      case 'battery': return this.battery();
      case 'weather': return this.weather();
      case 'timer': return this.timer(d.args);
      case 'timerStatus': return this.timerStatus();
      case 'alarm': return this.alarm(d.args);
      case 'cancel': return this.cancel();
      case 'math': return this.math(d.args);
      case 'search': return this.search(d.args);
      case 'note': return this.note(d.args);
      case 'notesList': return this.notesList();
      case 'noteDelete': return this.noteDelete(d.args);
      case 'setName': return this.setName(d.args);
      case 'mute': return this.setMute(true);
      case 'unmute': return this.setMute(false);
      case 'reset': return this.reset();
      case 'standby': return this.standby();
      case 'wake': return this.wake();
      case 'shutup': return this.shutup();
      default: return d.say || null;
    }
  },

  // ---------- Hora y fecha ----------
  time() {
    const d = new Date();
    return ['Son ' + timeToWords(d.getHours(), d.getMinutes()) + ', @USER@.'];
  },
  date() {
    return ['Hoy es ' + dateForSpeech(new Date()) + ', @USER@.'];
  },

  // ---------- Reporte de sistema ----------
  report() {
    const d = new Date();
    const cpu = parseInt(J.el.teleCpu.textContent, 10) || 20;
    const mem = navigator.deviceMemory ? navigator.deviceMemory + ' gigabytes de memoria' : 'memoria no disponible';
    const cores = navigator.hardwareConcurrency ? navigator.hardwareConcurrency + ' núcleos lógicos' : 'núcleos desconocidos';
    let bat = 'Batería: tecnología no disponible en este terminal.';
    if (J.battery) bat = 'Batería del terminal al ' + J.battery.level + ' por ciento, ' + (J.battery.charging ? 'cargando.' : 'con alimentación por batería.');
    const net = navigator.onLine ? 'enlace estable' : 'sin conexión de red';
    const w = J.weather || computeWeather();
    return [
      'Informe de estado del sistema, @USER@.',
      'Son las ' + timeToWords(d.getHours(), d.getMinutes()) + '.',
      'Carga de procesamiento simulada: ' + cpu + ' por ciento. Memoria: ' + mem + ', con ' + cores + '.',
      bat,
      'Red: ' + net + '.',
      'Clima simulado en la zona: ' + w.temp + ' grados, ' + w.cond + '. Humedad del ' + w.hum + ' por ciento, viento de ' + w.wind + ' kilómetros por hora.',
      'Tiempo de actividad: ' + formatDuration(Date.now() - J.startedAt) + '.',
      'Todos los subsistemas en verde, @USER@. Nada que requiera su atención inmediata.'
    ];
  },

  battery() {
    if (!J.battery) return ['El navegador no expone el estado de la batería, @USER@. Pero le aseguro que mi reactor de arco va al máximo.'];
    return ['La batería del terminal está al ' + J.battery.level + ' por ciento y ' + (J.battery.charging ? 'se está cargando.' : 'no se está cargando.') + ' Le sugiero un poco de prudencia, @USER@.'];
  },

  weather() {
    const w = J.weather || computeWeather();
    return ['Clima simulado en la zona, @USER@: ' + w.temp + ' grados, ' + w.cond + '. Humedad del ' + w.hum + ' por ciento, viento de ' + w.wind + ' kilómetros por hora.'];
  },

  // ---------- Temporizadores ----------
  timer(args) {
    const { secs, label, memo } = args;
    const id = Date.now();
    J.timers.push({ id, label, endAt: Date.now() + secs * 1000, total: secs, memo });
    UI.renderTimers();
    const base = 'Temporizador de ' + label + ' activado, @USER@.';
    const extra = memo ? ' Le recordaré: ' + memo + '.' : ' Le avisaré cuando concluya.';
    return [base + extra];
  },

  timerStatus() {
    let best = null;
    J.timers.forEach(t => { if (!best || t.endAt < best.endAt) best = t; });
    if (best) return ['El temporizador más próximo concluye en ' + formatDuration(best.endAt - Date.now()) + ', @USER@.'];
    if (J.alarms.length) {
      const a = J.alarms.slice().sort((x, y) => x.at - y.at)[0];
      return ['Su alarma de ' + a.label + ' sonará en ' + formatDuration(a.at - Date.now()) + ', @USER@.'];
    }
    return ['No hay temporizadores ni alarmas activos, @USER@. Su agenda está impecablemente vacía.'];
  },

  alarm(args) {
    const { h, min } = args;
    const at = new Date();
    at.setHours(h, min, 0, 0);
    if (at <= new Date()) at = new Date(at.getTime() + 86400000);
    J.alarms.push({ id: Date.now(), at: at.getTime(), label: timeToWords(h, min) });
    UI.renderTimers();
    return ['Alarma programada para ' + timeToWords(h, min) + ', @USER@. Le despertaré, si se me permite la expresión.'];
  },

  cancel() {
    const had = J.timers.length + J.alarms.length;
    J.timers = []; J.alarms = [];
    UI.renderTimers();
    return had ? ['Temporizadores y alarmas cancelados, @USER@.'] : ['No había nada que cancelar, @USER@. Un acierto, si me lo permite.'];
  },

  // ---------- Cálculos ----------
  math(args) {
    const { op, a, b, value } = args;
    if (op === 'eval') return ['El resultado es ' + formatNumberForSpeech(value) + ', @USER@.'];
    if (op === 'sqrt') return ['La raíz cuadrada de ' + formatNumberForSpeech(a) + ' es ' + formatNumberForSpeech(Math.sqrt(a)) + ', @USER@.'];
    if (op === 'sq') return [formatNumberForSpeech(a) + ' al cuadrado es ' + formatNumberForSpeech(a * a) + ', @USER@.'];
    if (op === 'pct') return ['El ' + formatNumberForSpeech(a) + ' por ciento de ' + formatNumberForSpeech(b) + ' es ' + formatNumberForSpeech(a * b / 100) + ', @USER@.'];
    return null;
  },

  // ---------- Búsqueda web ----------
  search(args) {
    const q = args.q;
    const url = 'https://www.google.com/search?q=' + encodeURIComponent(q);
    J.searchHistory.unshift({ q, url, t: Date.now() });
    if (J.searchHistory.length > 6) J.searchHistory.pop();
    this.startTelemetryRefresh();
    try {
      const w = window.open(url, '_blank');
      if (!w) UI.logSystem('EL NAVEGADOR BLOQUEÓ LA APERTURA AUTOMÁTICA · ENLACE EN TELEMETRÍA');
    } catch (e) {
      UI.logSystem('EL NAVEGADOR BLOQUEÓ LA APERTURA AUTOMÁTICA · ENLACE EN TELEMETRÍA');
    }
    UI.logSystem('BÚSQUEDA ABIERTA: ' + q.toUpperCase());
    return ['Abriendo resultados de búsqueda para «' + q + '», @USER@.'];
  },
  startTelemetryRefresh() { /* la telemetría se actualiza sola cada segundo */ },

  // ---------- Notas ----------
  note(args) {
    const id = Date.now();
    J.notes.unshift({ id, t: id, text: args.content });
    if (J.notes.length > 50) J.notes.pop();
    Storage.set('notes', J.notes);
    UI.renderNotes();
    const snip = args.content.length > 60 ? args.content.slice(0, 60) + '…' : args.content;
    return ['Nota registrada, @USER@: «' + snip + '».'];
  },

  notesList() {
    if (!J.notes.length) return ['No hay notas registradas, @USER@. Su memoria auxiliar está, con gran elegancia, vacía.'];
    const n = J.notes.length;
    const snip = J.notes[0].text.length > 80 ? J.notes[0].text.slice(0, 80) + '…' : J.notes[0].text;
    return ['Tiene ' + numberToWords(n) + (n === 1 ? ' nota' : ' notas') + ' registradas, @USER@. La más reciente dice: «' + snip + '».'];
  },

  noteDelete(args) {
    if (args.all) {
      J.notes = [];
      Storage.set('notes', J.notes);
      UI.renderNotes();
      return ['Todas las notas han sido borradas, @USER@. Memoria auxiliar purgada.'];
    }
    if (!J.notes.length) return ['No hay notas que borrar, @USER@.'];
    const idx = args.index != null && args.index > 0 ? args.index - 1 : 0;
    if (idx >= J.notes.length) return ['Esa nota no existe, @USER@. Comprobé el índice dos veces, por rigor.'];
    const removed = J.notes.splice(idx, 1);
    Storage.set('notes', J.notes);
    UI.renderNotes();
    return ['Nota borrada: «' + (removed[0].text.slice(0, 50)) + (removed[0].text.length > 50 ? '…' : '') + '». @USER@.'];
  },

  // ---------- Nombre del operador ----------
  setName(args) {
    J.config.userName = args.name;
    J.config.nameSet = true;
    Storage.set('userName', args.name);
    Storage.set('nameSet', true);
    playChime('success');
    return ['Entendido. A partir de ahora me dirigiré a usted como ' + args.name + '.'];
  },

  // ---------- Voz ----------
  setMute(mute) {
    J.config.voiceEnabled = !mute;
    Storage.set('voiceEnabled', J.config.voiceEnabled);
    UI.updateVoiceUI();
    if (mute) {
      if (J.speech.synth) J.speech.synth.cancel();
      Core.clearQueue();
      UI.logSystem('MÓDULO DE VOZ · SILENCIADO');
      return null;
    }
    return ['Voz reactivada, @USER@. Espero no haberla perdido mientras tanto.'];
  },

  // ---------- Reinicio de conversación ----------
  reset() {
    UI.clearLog();
    J.timers = []; J.alarms = [];
    UI.renderTimers();
    J.manual = false; J.armed = false;
    UI.setInterim('');
    UI.logSystem('REGISTRO DE CONVERSACIÓN REINICIADO');
    return ['Conversación reiniciada, @USER@. Mi memoria a corto plazo queda limpia, y mi ego intacto.'];
  },

  // ---------- Reposo ----------
  standby() {
    J.standby = true;
    J.manual = false; J.armed = false;
    playChime('deactivate');
    setState('STANDBY');
    return ['Muy bien, @USER@. Paso a modo de reposo. Diga «' + J.config.wakeWord + '» cuando me necesite.'];
  },
  wake() {
    J.standby = false;
    playChime('activate');
    return ['A su servicio, @USER@. Los sistemas han vuelto a la vida. Nunca se fueron, en realidad.'];
  },

  // ---------- Interrumpir la síntesis ----------
  shutup() {
    if (J.speech.synth) J.speech.synth.cancel();
    Core.clearQueue();
    UI.logSystem('SÍNTESIS DE VOZ INTERRUMPIDA');
    return null;
  }
};

// Comprueba cada segundo si temporizadores/alarmas han concluido.
function tickTimers() {
  const now = Date.now();
  J.timers = J.timers.filter(t => {
    if (now >= t.endAt) {
      playChime('timer');
      Core.say([t.memo ? '@USER@, le recuerdo: ' + t.memo + '.' : '@USER@, el temporizador ha concluido.']);
      UI.logSystem('TEMPORIZADOR FINALIZADO · ' + (t.label || '').toUpperCase());
      return false;
    }
    return true;
  });
  J.alarms = J.alarms.filter(a => {
    if (now >= a.at) {
      playChime('alarm');
      Core.say(['@USER@, es la hora. ' + a.label + '.']);
      UI.logSystem('ALARMA · ' + a.label.toUpperCase());
      return false;
    }
    return true;
  });
  UI.renderTimers();
}
setInterval(tickTimers, 1000);
