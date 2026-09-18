/* =====================================================================
   J.A.R.V.I.S. // ui.js
   Interfaz: reloj, telemetría, registro tipo terminal con efecto de
   escritura, notas, temporizadores, modal de configuración, panel de
   error, secuencia de arranque y estado visual del núcleo.
   ===================================================================== */
'use strict';

// Cambia el estado visual global del asistente.
function setState(s) {
  J.state = s;
  document.body.dataset.state = s;
  const label = {
    IDLE: 'EN REPOSO',
    LISTENING: 'ESCUCHANDO',
    PROCESSING: 'PROCESANDO',
    SPEAKING: 'HABLANDO',
    STANDBY: 'EN ESPERA · PALABRA DE ACTIVACIÓN'
  }[s] || s;
  J.el.stateLabel.textContent = label;
  J.el.footerState.textContent = 'ESTADO: ' + label;
  if (s !== 'LISTENING') { J.el.interim.textContent = ''; J.el.interim.classList.add('hidden'); }
  else J.el.interim.classList.remove('hidden');
}

const UI = {
  typeQueue: Promise.resolve(),
  sparkData: [],

  // ---------- Referencias del DOM ----------
  cacheEls() {
    const el = J.el;
    el.boot = $('#boot');
    el.bootLines = $('#boot-lines');
    el.btnBoot = $('#btn-boot');
    el.hud = $('#hud');
    el.starsCanvas = $('#bg-stars');
    el.coreCanvas = $('#core-canvas');
    el.stateLabel = $('#state-label');
    el.interim = $('#interim');
    el.micBtn = $('#mic-btn');
    el.wakeWordBtn = $('#wake-word-btn');
    el.hint = $('#hint');
    el.log = $('#log');
    el.footerState = $('#footer-state');
    el.timersBox = $('#timers-box');
    el.clockTime = $('#clock-time');
    el.clockDate = $('#clock-date');
    el.clockSecond = $('#clock-second-line');
    el.chipMic = $('#chip-mic'); el.dotMic = $('#dot-mic');
    el.chipVoice = $('#chip-voice'); el.dotVoice = $('#dot-voice');
    el.chipNet = $('#chip-net'); el.dotNet = $('#dot-net');
    el.btnSettings = $('#btn-settings');
    el.btnMute = $('#btn-mute');
    el.btnReset = $('#btn-reset');
    el.notesList = $('#notes-list');
    el.notesCount = $('#notes-count');
    el.notesEmpty = $('#notes-empty');
    el.teleUptime = $('#tele-uptime');
    el.teleCpu = $('#tele-cpu');
    el.teleMem = $('#tele-mem');
    el.teleBat = $('#tele-bat');
    el.teleNet = $('#tele-net');
    el.teleWeather = $('#tele-weather');
    el.teleCoord = $('#tele-coord');
    el.teleSearch = $('#tele-search');
    el.teleSpark = $('#tele-spark');
    el.settingsModal = $('#settings-modal');
    el.cfgName = $('#cfg-name');
    el.cfgWake = $('#cfg-wake');
    el.cfgVoice = $('#cfg-voice');
    el.btnCfgSave = $('#btn-cfg-save');
    el.btnCfgClearNotes = $('#btn-cfg-clear-notes');
    el.btnCfgClose = $('#btn-cfg-close');
    el.errorPanel = $('#error-panel');
    el.errorMsg = $('#error-msg');
    el.errorList = $('#error-list');
    el.btnErrorRetry = $('#btn-error-retry');
    el.btnErrorClose = $('#btn-error-close');
  },

  // ---------- Reloj y telemetría ----------
  startClock() {
    const secondLines = ['SINCRONIZACIÓN ESTELAR …', 'ENLACE HOLOGRÁFICO ESTABLE …', 'NÚCLEO ARC REACTOR · NIVEL 42', 'SATÉLITE DE COMUNICACIONES · OK', 'SCANNER AMBIENTAL ACTIVO …'];
    let li = 0;
    const tick = () => {
      const d = new Date();
      J.el.clockTime.textContent = fmtClock(d);
      J.el.clockDate.textContent = fmtDate(d);
    };
    tick();
    setInterval(() => { tick(); J.el.clockSecond.textContent = secondLines[li++ % secondLines.length]; }, 4000);
    this.startTelemetry();
  },

  startTelemetry() {
    let cpu = 12 + Math.random() * 10;
    const spark = this.sparkData;
    const sparkCv = J.el.teleSpark;
    const drawSpark = () => {
      if (!sparkCv) return;
      const dpr = window.devicePixelRatio || 1;
      const w = sparkCv.clientWidth || 200, h = 44;
      if (sparkCv.width !== w * dpr) { sparkCv.width = w * dpr; sparkCv.height = h * dpr; }
      const ctx = sparkCv.getContext('2d');
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);
      ctx.beginPath();
      spark.forEach((v, i) => {
        const x = i / (spark.length - 1 || 1) * w;
        const y = h - 4 - (v / 100) * (h - 8);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      ctx.strokeStyle = 'rgba(0,229,255,0.85)';
      ctx.lineWidth = 1.5;
      ctx.stroke();
    };

    const tick = () => {
      // Uptime
      J.el.teleUptime.textContent = fmtUptime(Date.now() - J.startedAt);
      // Carga simulada con paseo aleatorio
      cpu = clamp(cpu + (Math.random() - 0.5) * 10, 4, 96);
      spark.push(cpu);
      if (spark.length > 60) spark.shift();
      drawSpark();
      J.el.teleCpu.textContent = Math.round(cpu) + '%';
      // Memoria
      const mem = navigator.deviceMemory ? navigator.deviceMemory + ' GB' : '--';
      const cores = navigator.hardwareConcurrency ? navigator.hardwareConcurrency + ' NÚCLEOS' : '';
      J.el.teleMem.textContent = (mem + ' ' + cores).trim();
      // Batería (cache)
      J.el.teleBat.textContent = J.battery ? (J.battery.level + '%' + (J.battery.charging ? ' ⚡' : '')) : '--';
      // Red
      J.el.teleNet.textContent = navigator.onLine ? ('OK' + (navigator.connection && navigator.connection.effectiveType ? ' · ' + navigator.connection.effectiveType.toUpperCase() : '')) : 'OFFLINE';
      UI.setChip('net', navigator.onLine);
      // Clima simulado
      if (!J.weather) J.weather = computeWeather();
      J.el.teleWeather.textContent = J.weather.temp + '°C · ' + J.weather.cond.toUpperCase();
      // Última búsqueda
      J.el.teleSearch.innerHTML = J.searchHistory.length
        ? '<a href="' + J.searchHistory[0].url + '" target="_blank" rel="noopener">' + escapeHtml(J.searchHistory[0].q.slice(0, 20)) + '…</a>'
        : '--';
    };
    tick();
    setInterval(tick, 1000);
    setInterval(() => { J.weather = computeWeather(); }, 600000);
  },

  // ---------- Chips de estado ----------
  setChip(name, on, warn) {
    const map = { mic: 'chipMic', voice: 'chipVoice', net: 'chipNet' };
    const chip = J.el[map[name]];
    if (!chip) return;
    chip.classList.toggle('on', !!on);
    chip.classList.toggle('warn', !!warn && !on);
  },

  // ---------- Texto provisional reconocido ----------
  setInterim(text) {
    if (J.state === 'LISTENING' || text) {
      J.el.interim.textContent = text;
      J.el.interim.classList.toggle('hidden', !text);
    }
  },

  // ---------- Registro tipo terminal ----------
  logLine(type, text) {
    const line = document.createElement('div');
    line.className = 'log-line log-' + type;
    const ts = fmtClock(new Date());
    const pre = type === 'user' ? '▸' : type === 'jarvis' ? '◈' : '·';
    line.innerHTML = '<span class="log-ts">[' + ts + ']</span><span class="log-pre">' + pre + '</span><span class="log-text"></span>';
    line.querySelector('.log-text').textContent = text;
    J.el.log.appendChild(line);
    this.trimLog();
    this.scrollLog();
    return line;
  },

  logUser(text) { this.logLine('user', text); },

  logSystem(text) { this.logLine('sys', text); },

  logJarvis(text) {
    const line = this.logLine('jarvis', '');
    const el = line.querySelector('.log-text');
    this.typeInto(el, text, 8);
  },

  // Efecto de escritura tipo terminal (encolado para no solaparse).
  typeInto(el, text, speed) {
    this.typeQueue = this.typeQueue.then(() => new Promise(res => {
      let i = 0;
      el.classList.add('typing');
      const iv = setInterval(() => {
        i += 1;
        el.textContent = text.slice(0, i);
        this.scrollLog();
        if (i >= text.length) {
          clearInterval(iv);
          el.classList.remove('typing');
          res();
        }
      }, speed);
    }));
  },

  trimLog() {
    while (J.el.log.children.length > 400) J.el.log.removeChild(J.el.log.firstChild);
  },
  scrollLog() { J.el.log.scrollTop = J.el.log.scrollHeight; },
  clearLog() { J.el.log.innerHTML = ''; },

  // ---------- Notas ----------
  renderNotes() {
    J.el.notesList.innerHTML = '';
    J.el.notesCount.textContent = J.notes.length;
    J.el.notesEmpty.classList.toggle('hidden', J.notes.length > 0);
    J.notes.forEach((n, i) => {
      const li = document.createElement('li');
      li.style.cssText = 'list-style:none;margin-bottom:10px;padding-bottom:8px;border-bottom:1px solid rgba(255,255,255,0.06);';
      const time = document.createElement('div');
      time.textContent = fmtClock(new Date(n.t));
      time.style.cssText = 'font-family:var(--font-mono);font-size:9px;color:var(--dim2);letter-spacing:1px;';
      const body = document.createElement('div');
      body.textContent = n.text;
      body.style.cssText = 'font-family:var(--font-mono);font-size:11.5px;color:var(--cyan-soft);line-height:1.45;margin:3px 0 4px;';
      const del = document.createElement('button');
      del.textContent = '✕ BORRAR';
      del.style.cssText = 'font-family:var(--font-mono);font-size:9px;color:var(--dim);background:none;border:1px solid rgba(255,255,255,0.12);cursor:pointer;padding:2px 6px;';
      del.onclick = () => { J.notes.splice(i, 1); Storage.set('notes', J.notes); this.renderNotes(); UI.logSystem('NOTA BORRADA'); };
      li.appendChild(time); li.appendChild(body); li.appendChild(del);
      J.el.notesList.appendChild(li);
    });
  },

  // ---------- Temporizadores flotantes ----------
  renderTimers() {
    const box = J.el.timersBox;
    box.innerHTML = '';
    const items = [];
    J.timers.forEach(t => {
      const rem = Math.max(0, t.endAt - Date.now());
      items.push({ id: t.id, kind: 'timer', label: (t.memo || 'TEMPORIZADOR · ' + t.label), time: fmtCountdown(rem), warn: rem < 15000 });
    });
    J.alarms.forEach(a => {
      const rem = Math.max(0, a.at - Date.now());
      items.push({ id: a.id, kind: 'alarm', label: 'ALARMA · ' + a.label, time: fmtCountdown(rem), warn: rem < 60000 });
    });
    if (!items.length) { box.classList.add('hidden'); return; }
    box.classList.remove('hidden');
    items.forEach(it => {
      const div = document.createElement('div');
      div.className = 'timer-item' + (it.warn ? ' warning' : '');
      const lab = document.createElement('span');
      lab.className = 't-label'; lab.textContent = it.label;
      const tm = document.createElement('span');
      tm.className = 't-time'; tm.textContent = it.time;
      const x = document.createElement('button');
      x.className = 't-x'; x.textContent = '✕';
      x.dataset.kind = it.kind; x.dataset.id = it.id;
      div.appendChild(lab); div.appendChild(tm); div.appendChild(x);
      box.appendChild(div);
    });
  },

  // ---------- Palabra de activación ----------
  updateWakeBtn() {
    J.el.wakeWordBtn.textContent = '“' + J.config.wakeWord.toUpperCase() + '”';
  },

  // ---------- Modal de configuración ----------
  openSettings() {
    J.el.cfgName.value = J.config.userName;
    J.el.cfgWake.value = J.config.wakeWord;
    J.el.cfgVoice.checked = J.config.voiceEnabled;
    J.el.settingsModal.classList.remove('hidden');
  },
  closeSettings() { J.el.settingsModal.classList.add('hidden'); },

  // ---------- Panel de error ----------
  showError(msg, reasons) {
    playChime('error');
    J.el.errorMsg.textContent = msg;
    J.el.errorList.innerHTML = '';
    (reasons || []).forEach(r => {
      const li = document.createElement('li');
      li.textContent = r;
      J.el.errorList.appendChild(li);
    });
    J.el.errorPanel.classList.remove('hidden');
  },
  hideError() { J.el.errorPanel.classList.add('hidden'); },

  // ---------- Secuencia de arranque ----------
  bootStarted() {
    J.el.btnBoot.disabled = true;
    J.el.btnBoot.textContent = 'INICIALIZANDO …';
  },
  typeBootLine(text, ok) {
    return new Promise(res => {
      const div = document.createElement('div');
      J.el.bootLines.appendChild(div);
      const type = (i) => {
        if (i > text.length) { if (ok) div.classList.add('ok'); res(); return; }
        div.textContent = text.slice(0, i);
        setTimeout(() => type(i + 1), 7);
      };
      type(0);
    });
  },
  async finishBoot() {
    await sleep(500);
    J.el.boot.classList.add('hidden');
    J.el.hud.classList.remove('hidden');
  }
};

// ---------- Asociación de eventos de interfaz ----------
function bindUI() {
  const el = J.el;

  el.btnSettings.addEventListener('click', () => { playChime('click'); UI.openSettings(); });
  el.btnCfgClose.addEventListener('click', () => { playChime('click'); UI.closeSettings(); });

  el.btnCfgSave.addEventListener('click', () => {
    const name = el.cfgName.value.trim();
    const wake = el.cfgWake.value.trim();
    if (wake) {
      J.config.wakeWord = wake;
      Storage.set('wakeWord', wake);
      UI.updateWakeBtn();
    }
    if (name) {
      J.config.userName = name;
      J.config.nameSet = true;
      Storage.set('userName', name);
      Storage.set('nameSet', true);
    }
    J.config.voiceEnabled = el.cfgVoice.checked;
    Storage.set('voiceEnabled', J.config.voiceEnabled);
    UI.updateVoiceUI();
    playChime('success');
    UI.closeSettings();
    UI.logSystem('CONFIGURACIÓN DEL OPERADOR ACTUALIZADA');
  });

  el.btnCfgClearNotes.addEventListener('click', () => {
    J.notes = [];
    Storage.set('notes', []);
    UI.renderNotes();
    playChime('click');
    UI.logSystem('MEMORIA DE NOTAS VACÍA');
  });

  // Palabra de activación clicable → abre la configuración
  el.wakeWordBtn.addEventListener('click', () => { playChime('click'); UI.openSettings(); });

  // Silenciar / activar voz
  el.btnMute.addEventListener('click', () => {
    const on = !J.config.voiceEnabled;
    J.config.voiceEnabled = on;
    Storage.set('voiceEnabled', on);
    UI.updateVoiceUI();
    if (!on && J.speech.synth) { J.speech.synth.cancel(); Core.clearQueue(); }
    playChime(on ? 'activate' : 'deactivate');
    UI.logSystem(on ? 'MÓDULO DE VOZ · REACTIVADO' : 'MÓDULO DE VOZ · SILENCIADO');
  });

  // Reiniciar conversación
  el.btnReset.addEventListener('click', () => {
    playChime('click');
    Actions.reset();
  });

  // Botón de micrófono → orden directa
  el.micBtn.addEventListener('click', () => {
    if (!J.speech.recognition) {
      UI.showError('El reconocimiento de voz no está disponible en este navegador.', ['Use un navegador reciente con soporte de Web Speech API, como Chrome o Edge.']);
      return;
    }
    if (J.standby) Core.exitStandby();
    if (J.speech.synth) J.speech.synth.cancel();
    if (J.manual) {
      J.manual = false; J.armed = false;
      setState(J.standby ? 'STANDBY' : 'IDLE');
      UI.setInterim('');
      UI.logSystem('ORDEN DIRECTA CANCELADA');
      return;
    }
    J.manual = true;
    J.armed = true;
    playChime('activate');
    Core.startRecognition();
    setState('LISTENING');
    UI.setInterim('');
    Core.say(['Diga, @USER@.']);
  });

  // Cierre de temporizadores flotantes
  el.timersBox.addEventListener('click', e => {
    const x = e.target.closest('.t-x');
    if (!x) return;
    const kind = x.dataset.kind, id = Number(x.dataset.id);
    if (kind === 'timer') J.timers = J.timers.filter(t => t.id !== id);
    else J.alarms = J.alarms.filter(a => a.id !== id);
    UI.renderTimers();
    playChime('click');
  });

  // Panel de error
  el.btnErrorRetry.addEventListener('click', () => { location.reload(); });
  el.btnErrorClose.addEventListener('click', () => {
    UI.hideError();
    UI.logSystem('MODO LIMITADO ACTIVADO · INTERFAZ SIN MÓDULO DE VOZ');
  });

  // Cerrar modal con Escape
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') UI.closeSettings();
  });
}

// Estado de la voz (botón y chip)
UI.updateVoiceUI = function () {
  const on = J.config.voiceEnabled;
  J.el.btnMute.classList.toggle('muted', !on);
  UI.setChip('voice', on);
  if (on && J.speech.synth) J.speech.synth.resume();
};
