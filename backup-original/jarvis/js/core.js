/* =====================================================================
   J.A.R.V.I.S. // core.js
   Orquestación central: reconocimiento de voz (Web Speech API), palabra
   de activación, máquina de estados y síntesis de voz con cola de frases.
   ===================================================================== */
'use strict';

const Core = {
  sayQueue: [],
  watchdog: null,

  // ---------- Reconocimiento de voz ----------
  setupRecognition() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) { J.speech.recognition = null; return; }
    const rec = new SR();
    rec.lang = 'es-ES';
    rec.continuous = true;
    rec.interimResults = true;
    rec.maxAlternatives = 1;

    rec.onstart = () => { J.recActive = true; UI.setChip('mic', true); };
    rec.onend = () => {
      J.recActive = false;
      UI.setChip('mic', J.pausedForSpeech);
      if (!J.pausedForSpeech && J.recognitionWanted) setTimeout(() => Core.startRecognition(), 250);
    };
    rec.onerror = e => {
      if (e.error === 'not-allowed' || e.error === 'service-not-allowed') {
        J.pausedForSpeech = true;
        UI.showError('El acceso al micrófono ha sido denegado por el navegador.',
          ['Autorice el micrófono para este sitio en la configuración del navegador.',
           'En Chrome/Edge: icono del candado junto a la barra de direcciones → Micrófono → Permitir.',
           'Tras el cambio, pulse «Reintentar» para volver a iniciar.']);
      }
      // 'network', 'no-speech' y 'aborted' se tratan en silencio.
    };

    J.speech.recognition = rec;
  },

  startRecognition() {
    if (!J.speech.recognition || J.pausedForSpeech) return;
    J.recognitionWanted = true;
    if (J.recActive) return;
    try { J.speech.recognition.start(); }
    catch (e) { J.recActive = false; }
  },

  stopRecognition() {
    J.recognitionWanted = false;
    if (J.recActive) { try { J.speech.recognition.stop(); } catch (e) { /* sin efecto */ } }
  },

  // Pausa mientras el asistente habla (evita que se escuche a sí mismo).
  pauseForSpeech() {
    J.pausedForSpeech = true;
    this.stopRecognition();
    UI.setChip('mic', false);
  },
  resumeFromSpeech() {
    J.pausedForSpeech = false;
    this.startRecognition();
  },

  // ---------- Palabra de activación ----------
  getWakeWord() { return stripAccents(J.config.wakeWord.toLowerCase()).trim(); },

  hasWakeWord(text) {
    const wk = this.getWakeWord();
    if (!wk) return false;
    const toks = cleanTokens(text).split(/\s+/);
    return toks.indexOf(wk) >= 0;
  },

  stripWake(text) {
    const wk = this.getWakeWord();
    const toks = cleanTokens(text).split(/\s+/);
    const idx = toks.indexOf(wk);
    if (idx >= 0) {
      toks.splice(idx, 1);
      let out = toks.join(' ');
      out = out.replace(/^[\s,]+/, '').trim();
      return out;
    }
    return text;
  },

  // ---------- Manejo de resultados del reconocimiento ----------
  onResult(e) {
    let finalText = '', interim = '';
    for (let i = e.resultIndex; i < e.results.length; i++) {
      const r = e.results[i];
      const t = r[0].transcript;
      if (r.isFinal) finalText += ' ' + t;
      else interim += ' ' + t;
    }
    interim = cleanTokens(interim);
    if (interim && (J.manual || J.armed || this.hasWakeWord(interim))) {
      UI.setInterim(interim);
    }
    const ft = cleanTokens(finalText);
    if (ft) this.handleFinal(ft);
  },

  handleFinal(text) {
    const hasW = this.hasWakeWord(text);
    if (J.standby) {
      if (hasW) {
        this.exitStandby();
        const rest = this.stripWake(text);
        if (rest) this.processUserText(rest);
      }
      return;
    }
    if (J.manual) {
      J.manual = false;
      if (hasW) { const rest = this.stripWake(text); if (rest) this.processUserText(rest); }
      else this.processUserText(text);
      return;
    }
    if (hasW) {
      const rest = this.stripWake(text);
      if (rest.trim()) {
        J.armed = false;
        this.processUserText(rest);
      } else {
        J.armed = true;
        setState('LISTENING');
        this.say(['Sí, @USER@. ¿En qué puedo servirle?']);
      }
      return;
    }
    if (J.armed) {
      J.armed = false;
      this.processUserText(text);
      return;
    }
    // Sin wake word ni activación: se ignora el ruido ambiental.
  },

  // ---------- Procesamiento de un comando ----------
  processUserText(raw) {
    const text = norm(raw).replace(/[.,!?¿¡;]+$/, '').trim();
    if (!text) return;
    UI.logUser(text);
    setState('PROCESSING');
    const d = interpret(text);
    let out = Actions.execute(d);
    let lines = out || d.say || null;
    if (lines) {
      if (typeof lines === 'string') lines = [lines];
      this.say(lines);
    } else {
      // Sin voz: volver al estado anterior.
      setTimeout(() => this._endSpeech(), 150);
    }
  },

  // ---------- Síntesis de voz (cola de frases) ----------
  say(lines) {
    if (lines && lines.length) {
      J.sayQueue.push(...lines);
      this._pump();
    } else {
      this._endSpeech();
    }
  },

  clearQueue() { J.sayQueue = []; },

  _pump() {
    if (J.speaking) return;
    const next = J.sayQueue.shift();
    if (next === undefined) { this._endSpeech(); return; }
    this._speakLine(next);
  },

  _speakLine(line) {
    const text = line.replace(/@USER@/g, J.config.userName);
    UI.logJarvis(text);
    J.speaking = true;
    setState('SPEAKING');
    this.pauseForSpeech();

    if (!J.config.voiceEnabled || !J.speech.synth) {
      setTimeout(() => { J.speaking = false; this._pump(); }, 80 + text.length * 14);
      return;
    }
    const u = new SpeechSynthesisUtterance(text);
    u.lang = J.speech.lang || 'es-ES';
    if (J.speech.voice) u.voice = J.speech.voice;
    u.rate = 0.92;   // ligeramente por debajo de lo normal
    u.pitch = 0.72;  // tono grave, estilo mayordomo
    u.volume = 1;

    u.onstart = () => { J.synthEnergy = 0.7; };
    u.onboundary = () => { J.synthEnergy = 0.6 + Math.random() * 0.4; };
    u.onend = () => { J.synthEnergy = 0; J.speaking = false; this._pump(); };
    u.onerror = () => { J.synthEnergy = 0; J.speaking = false; this._pump(); };

    // Vigilante: si el navegador no emite eventos, fuerza el avance.
    clearTimeout(this.watchdog);
    this.watchdog = setTimeout(() => {
      if (J.speaking) { J.speaking = false; J.synthEnergy = 0; this._pump(); }
    }, Math.max(3500, text.length * 95));

    try { J.speech.synth.speak(u); } catch (e) { J.speaking = false; this._pump(); }
  },

  _endSpeech() {
    J.speaking = false;
    J.synthEnergy = 0;
    setState(J.standby ? 'STANDBY' : 'IDLE');
    this.resumeFromSpeech();
  },

  // ---------- Reposo / despertar ----------
  exitStandby() {
    J.standby = false;
    playChime('activate');
    setState('IDLE');
    UI.logSystem('ASISTENTE DESPERTADO · PALABRA DE ACTIVACIÓN RECIBIDA');
  },

  // ---------- Saludo inicial ----------
  greet() {
    const d = new Date();
    this.say([
      'Bienvenido, @USER@. Son las ' + timeToWords(d.getHours(), d.getMinutes()) + ' y todos los sistemas están en línea.',
      '¿En qué puedo ayudarle?'
    ]);
    UI.logSystem('NÚCLEO ARC REACTOR · OPERATIVO');
    UI.logSystem('MÓDULO DE VOZ · SINCRONIZADO');
    UI.logSystem('RECONOCIMIENTO DE VOZ · ACTIVO');
    playChime('boot');
  }
};
