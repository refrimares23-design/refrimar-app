/* =====================================================================
   J.A.R.V.I.S. // main.js
   Punto de entrada: carga la configuración persistente, enlaza la
   interfaz y gestiona la secuencia de arranque con los permisos del
   micrófono.
   ===================================================================== */
'use strict';

function loadConfig() {
  J.config.wakeWord = Storage.get('wakeWord', 'jarvis');
  J.config.userName = Storage.get('userName', 'señor');
  J.config.nameSet = Storage.get('nameSet', false);
  J.config.voiceEnabled = Storage.get('voiceEnabled', true);
  J.notes = Storage.get('notes', []);
}

// Secuencia completa de arranque tras el clic del operador.
async function bootSystem() {
  UI.bootStarted();
  UI.typeBootLine('INICIALIZANDO NÚCLEO ARC REACTOR …');

  try {
    await initAudioAndMic();
    UI.typeBootLine('CAPTURANDO SEÑAL DE MICRÓFONO … OK', true);
  } catch (e) {
    UI.typeBootLine('FALLO EN LA CAPTURA DE AUDIO · PERMISO DENEGADO');
  }

  UI.typeBootLine('CARGANDO MÓDULO DE RECONOCIMIENTO DE VOZ …');
  UI.typeBootLine('SINCRONIZANDO SÍNTESIS VOCAL …');

  loadVoices();
  initBattery();
  J.weather = computeWeather();

  Core.setupRecognition();
  if (J.speech.recognition) UI.typeBootLine('RECONOCIMIENTO DE VOZ · LISTO', true);
  else UI.typeBootLine('MÓDULO DE RECONOCIMIENTO · NO DISPONIBLE EN ESTE NAVEGADOR');

  UI.typeBootLine('CALIBRANDO SENSORES AMBIENTALES … OK', true);
  UI.typeBootLine('SISTEMAS LISTOS', true);

  await UI.finishBoot();

  // Arrancar el reconocimiento continuo.
  if (J.speech.recognition) {
    Core.startRecognition();
    UI.updateVoiceUI();
  }

  // Saludo inicial.
  Core.greet();

  // Avisos de fallo, en su caso.
  if (!J.speech.recognition) {
    UI.showError('Este navegador no incluye el módulo de reconocimiento de voz (Web Speech API).',
      ['El asistente requiere reconocimiento y síntesis de voz.',
       'Use un navegador reciente basado en Chromium (Chrome, Edge, Brave) o Safari.',
       'La interfaz holográfica permanece operativa en modo limitado.']);
  } else if (J.standby === false && !J.recActive) {
    setTimeout(() => {
      if (!J.recActive && !J.pausedForSpeech) {
        UI.showError('No se ha podido iniciar el reconocimiento de voz.',
          ['Autorice el micrófono en la configuración del navegador y pulse «Reintentar».',
           'El asistente seguirá funcionando si pulsa el botón del micrófono, si el permiso lo permite.']);
      }
    }, 2500);
  }
}

function init() {
  loadConfig();
  UI.cacheEls();
  UI.updateWakeBtn();
  UI.updateVoiceUI();
  UI.renderNotes();
  UI.renderTimers();
  bindUI();
  UI.startClock();
  Vis.init();

  // Registro inicial en la terminal.
  UI.logSystem('INTERFAZ DE ASISTENCIA J.A.R.V.I.S. v' + J.VERSION + ' INICIALIZADA');
  UI.logSystem('ESPERE LA ORDEN DE ARRANQUE DEL OPERADOR');

  // Botón de arranque.
  J.el.btnBoot.addEventListener('click', bootSystem);
}

// Inicio inmediato (los scripts se cargan al final del body).
init();
