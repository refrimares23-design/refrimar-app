/* =====================================================================
   J.A.R.V.I.S. // audio-engine.js
   Web Audio API: contexto de audio, captura del micrófono con un
   AnalyserNode (para las animaciones reactivas) y tonos sintetizados.
   ===================================================================== */
'use strict';

let actx = null;
let micAnalyser = null;

// Crea el contexto de audio y captura el micrófono.
// Debe llamarse desde un gesto del usuario (clic en "Iniciar sistema").
async function initAudioAndMic() {
  const AC = window.AudioContext || window.webkitAudioContext;
  if (!AC) throw new Error('Web Audio API no disponible');
  actx = new AC();
  await actx.resume();

  const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
  const source = actx.createMediaStreamSource(stream);
  micAnalyser = actx.createAnalyser();
  micAnalyser.fftSize = 1024;
  micAnalyser.smoothingTimeConstant = 0.75;
  source.connect(micAnalyser);
  return { actx, analyser: micAnalyser };
}

// Nivel medio del micrófono (0..1) a partir del espectro de frecuencias.
function readMicLevel() {
  if (!micAnalyser) return 0;
  const buf = new Uint8Array(micAnalyser.frequencyBinCount);
  micAnalyser.getByteFrequencyData(buf);
  let s = 0;
  for (let i = 0; i < buf.length; i++) s += buf[i];
  return s / (buf.length * 255);
}

// Tono sintetizado simple con envolvente de ataque/decaimiento.
function tone(freq, dur, type, gain, delay) {
  if (!actx) return;
  const t0 = actx.currentTime + (delay || 0);
  const osc = actx.createOscillator();
  const g = actx.createGain();
  osc.type = type || 'sine';
  osc.frequency.setValueAtTime(freq, t0);
  g.gain.setValueAtTime(0.0001, t0);
  g.gain.exponentialRampToValueAtTime(gain || 0.12, t0 + 0.015);
  g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
  osc.connect(g); g.connect(actx.destination);
  osc.start(t0);
  osc.stop(t0 + dur + 0.05);
}

// Pequeñas secuencias de sonido para distintas situaciones.
function playChime(kind) {
  if (!actx) return;
  switch (kind) {
    case 'boot':     tone(523.25, 0.16, 'sine', 0.10, 0); tone(659.25, 0.16, 'sine', 0.10, 0.12); tone(783.99, 0.30, 'sine', 0.10, 0.24); break;
    case 'activate': tone(880, 0.10, 'sine', 0.09, 0); tone(1318.5, 0.14, 'sine', 0.09, 0.09); break;
    case 'deactivate': tone(660, 0.12, 'sine', 0.08, 0); tone(440, 0.16, 'sine', 0.08, 0.10); break;
    case 'timer':    tone(880, 0.16, 'sine', 0.10, 0); tone(880, 0.16, 'sine', 0.10, 0.22); tone(880, 0.30, 'sine', 0.10, 0.44); break;
    case 'alarm':    tone(987.77, 0.18, 'triangle', 0.11, 0); tone(987.77, 0.18, 'triangle', 0.11, 0.25); tone(987.77, 0.30, 'triangle', 0.11, 0.50); break;
    case 'error':    tone(180, 0.28, 'sawtooth', 0.08, 0); tone(140, 0.30, 'sawtooth', 0.08, 0.16); break;
    case 'click':    tone(1200, 0.06, 'square', 0.04, 0); break;
    case 'success':  tone(880, 0.10, 'sine', 0.09, 0); tone(1174.66, 0.18, 'sine', 0.09, 0.10); break;
  }
}

// Cache de batería (Chrome/Edge). Se actualiza en segundo plano.
function initBattery() {
  if (!navigator.getBattery) { J.battery = null; return; }
  navigator.getBattery().then(b => {
    const sync = () => { J.battery = { level: Math.round(b.level * 100), charging: b.charging }; };
    sync();
    b.addEventListener('levelchange', sync);
    b.addEventListener('chargingchange', sync);
  }).catch(() => { J.battery = null; });
}
