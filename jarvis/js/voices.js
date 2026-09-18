/* =====================================================================
   J.A.R.V.I.S. // voices.js
   Selección de la voz sintética más adecuada (masculina, en español)
   y configuración de la síntesis de voz (rate y pitch graves).
   ===================================================================== */
'use strict';

// Carga las voces disponibles y elige la mejor candidata masculina en español.
function loadVoices() {
  const synth = window.speechSynthesis;
  if (!synth) return;
  J.speech.synth = synth;

  const pick = () => {
    const vs = synth.getVoices();
    if (!vs.length) return;
    J.speech.voices = vs;

    const es = vs.filter(v => /^es/i.test(v.lang));
    const prefer = ['male', 'jorge', 'raul', 'luis', 'diego', 'carlos', 'alejandro', 'google', 'daniel', 'pablo', 'juan', 'nicolas', 'santiago', 'sebastian', 'andre', 'oswaldo', 'yago', 'antonio'];
    const score = v => {
      const n = v.name.toLowerCase();
      let s = 0;
      prefer.forEach((k, i) => { if (n.includes(k)) s += (30 - i); });
      if (/female|femenina|woman|maria|paulina|monica|rosa|sonia|helena|ines|laura/i.test(n)) s -= 40;
      return s;
    };
    const sorted = es.slice().sort((a, b) => score(b) - score(a));
    const best = (es.length ? sorted[0] : null) || vs.find(v => /^es/i.test(v.lang)) || vs[0] || null;
    J.speech.voice = best;
    J.speech.lang = best ? best.lang : 'es-ES';
  };

  pick();
  // En algunos navegadores las voces llegan de forma asíncrona.
  if (typeof synth.onvoiceschanged !== 'undefined') {
    synth.onvoiceschanged = pick;
  }
}
