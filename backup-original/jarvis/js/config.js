/* =====================================================================
   J.A.R.V.I.S. // config.js
   Estado global compartido por todos los módulos y configuración base.
   ===================================================================== */
'use strict';

const J = {
  VERSION: '4.2.1',

  // Estados visuales posibles del núcleo.
  STATES: {
    IDLE:      'IDLE',      // reposo: pulso lento y tenue
    LISTENING: 'LISTENING', // escuchando: anillos reaccionan al micrófono
    PROCESSING:'PROCESSING',// procesando: barrido tipo radar
    SPEAKING:  'SPEAKING',  // hablando: ecualizador radial
    STANDBY:   'STANDBY'    // en espera de la palabra de activación
  },

  state: 'IDLE',

  // Configuración persistente del operador.
  config: {
    wakeWord: 'jarvis',
    userName: 'señor',
    nameSet:  false,
    voiceEnabled: true
  },

  // Banderas de control de voz.
  armed: false,            // listo para recibir un comando tras la palabra de activación
  manual: false,           // modo botón: la próxima frase es un comando directo
  standby: false,          // modo reposo profundo (solo responde a la wake word)
  speaking: false,         // el asistente está hablando
  pausedForSpeech: false,  // reconocimiento pausado mientras el asistente habla
  recognitionWanted: true, // se desea tener el reconocimiento activo
  recActive: false,        // el reconocimiento está realmente corriendo

  // Energía visual: 0..1
  synthEnergy: 0,          // energía sincronizada con la síntesis de voz
  micLevel: 0,             // nivel medio del micrófono (analizador)

  // Datos de sistema.
  startedAt: Date.now(),
  battery: null,           // { level, charging } o null
  weather: null,           // clima simulado
  timers: [],              // temporizadores activos
  alarms: [],              // alarmas activas
  notes: [],               // notas de voz
  searchHistory: [],       // búsquedas recientes

  speech: { recognition: null, synth: null, voice: null, lang: 'es-ES' },
  el: {}                   // referencias a elementos del DOM
};
