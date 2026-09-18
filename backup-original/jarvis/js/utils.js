/* =====================================================================
   J.A.R.V.I.S. // utils.js
   Utilidades generales: helpers de DOM, fechas, números en español y
   persistencia con localStorage.
   ===================================================================== */
'use strict';

// ---------- Helpers de DOM ----------
const $  = (s, r) => (r || document).querySelector(s);
const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));

// ---------- Texto ----------
function stripAccents(s) {
  return s.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
}
// Normaliza para análisis: minúsculas, sin acentos y compacta espacios.
function norm(text) {
  return stripAccents(text).toLowerCase().trim().replace(/\s+/g, ' ');
}
function cleanTokens(text) {
  return norm(text).replace(/[.,;:!?¿¡()"'«»]/g, ' ').replace(/\s+/g, ' ').trim();
}
function randomPick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
function clamp(v, a, b) { return Math.min(b, Math.max(a, v)); }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function capitalize(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }
const pad2 = n => String(n).padStart(2, '0');

// ---------- Fechas ----------
const DOW = ['Domingo', 'Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado'];
const MON = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];

function fmtClock(d) { d = d || new Date(); return pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds()); }

function fmtDate(d) {
  d = d || new Date();
  return DOW[d.getDay()].toUpperCase() + ', ' + d.getDate() + ' DE ' + MON[d.getMonth()].toUpperCase() + ' ' + d.getFullYear();
}
function dateForSpeech(d) {
  d = d || new Date();
  return DOW[d.getDay()].toLowerCase() + ', ' + d.getDate() + ' de ' + MON[d.getMonth()] + ' de ' + numberToWords(d.getFullYear());
}
function fmtUptime(ms) {
  const s = Math.floor(ms / 1000);
  return pad2(Math.floor(s / 3600)) + ':' + pad2(Math.floor((s % 3600) / 60)) + ':' + pad2(s % 60);
}
function fmtCountdown(ms) {
  const s = Math.max(0, Math.round(ms / 1000));
  return pad2(Math.floor(s / 3600)) + ':' + pad2(Math.floor((s % 3600) / 60)) + ':' + pad2(s % 60);
}
function formatDuration(ms) {
  const s = Math.max(0, Math.round(ms / 1000));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const parts = [];
  if (h) parts.push(h === 1 ? '1 hora' : h + ' horas');
  if (m) parts.push(m === 1 ? '1 minuto' : m + ' minutos');
  if (sec || parts.length === 0) parts.push(sec + ' segundos');
  return parts.join(' y ');
}

// ---------- Hora en palabras ----------
function timeToWords(h, m) {
  const h12 = h % 12 === 0 ? 12 : h % 12;
  const period = h < 6 ? 'de la madrugada' : h < 12 ? 'de la mañana' : h < 20 ? 'de la tarde' : 'de la noche';
  const hourWord = h12 === 1 ? 'la una' : 'las ' + numberToWords(h12);
  if (m === 0) return hourWord + ' en punto ' + period;
  if (m === 15) return hourWord + ' y cuarto ' + period;
  if (m === 30) return hourWord + ' y media ' + period;
  if (m === 45) {
    const nh = h === 23 ? 0 : h + 1;
    const nh12 = nh % 12 === 0 ? 12 : nh % 12;
    return (nh12 === 1 ? 'la una' : 'las ' + numberToWords(nh12)) + ' menos cuarto ' + period;
  }
  return hourWord + ' con ' + numberToWords(m) + ' minutos ' + period;
}

// ---------- Números: palabras <-> valor ----------
const UN0 = [null, 'uno', 'dos', 'tres', 'cuatro', 'cinco', 'seis', 'siete', 'ocho', 'nueve', 'diez', 'once', 'doce', 'trece', 'catorce', 'quince', 'dieciséis', 'diecisiete', 'dieciocho', 'diecinueve'];
const TENS = [null, null, 'veinte', 'treinta', 'cuarenta', 'cincuenta', 'sesenta', 'setenta', 'ochenta', 'noventa'];
const TWENTIES = ['veintiuno', 'veintidós', 'veintitrés', 'veinticuatro', 'veinticinco', 'veintiséis', 'veintisiete', 'veintiocho', 'veintinueve'];
const HUND = [null, 'ciento', 'doscientos', 'trescientos', 'cuatrocientos', 'quinientos', 'seiscientos', 'setecientos', 'ochocientos', 'novecientos'];

function underHundred(n) {
  if (n < 20) return UN0[n];
  if (n < 30) return n === 20 ? 'veinte' : TWENTIES[n - 21];
  const u = n % 10;
  return u ? TENS[Math.floor(n / 10)] + ' y ' + UN0[u] : TENS[Math.floor(n / 10)];
}
function underThousand(n) {
  const h = Math.floor(n / 100), r = n % 100;
  if (h === 0) return underHundred(r);
  const hw = h === 1 ? (r === 0 ? 'cien' : 'ciento') : HUND[h];
  return r ? hw + ' ' + underHundred(r) : hw;
}
function numberToWords(n) {
  if (n === 0) return 'cero';
  if (!isFinite(n)) return 'indefinido';
  const neg = n < 0;
  n = Math.abs(Math.floor(n));
  const mill = Math.floor(n / 1000000);
  const mil = Math.floor(n / 1000) % 1000;
  const rest = n % 1000;
  const parts = [];
  if (mill > 0) parts.push(mill === 1 ? 'un millón' : underThousand(mill) + ' millones');
  if (mil > 0) parts.push(mil === 1 ? 'mil' : underThousand(mil) + ' mil');
  if (rest > 0) parts.push(underThousand(rest));
  if (parts.length === 0) parts.push('cero');
  return (neg ? 'menos ' : '') + parts.join(' ');
}
// Habla un número: enteros en palabras, decimales con "coma".
function formatNumberForSpeech(x) {
  if (!isFinite(x)) return 'indefinido';
  const neg = x < 0;
  const ax = Math.abs(x);
  if (Number.isInteger(ax)) return (neg ? 'menos ' : '') + numberToWords(ax);
  const s = ax.toFixed(4).replace(/\.?0+$/, '');
  const sp = s.split('.');
  let out = numberToWords(Number(sp[0]));
  if (sp[1]) out += ' coma ' + sp[1].split('').map(c => numberToWords(Number(c))).join(' ');
  return (neg ? 'menos ' : '') + out;
}

// ---------- Análisis de números en palabras ----------
const NUM_UNITS = { cero: 0, un: 1, uno: 1, una: 1, dos: 2, tres: 3, cuatro: 4, cinco: 5, seis: 6, siete: 7, ocho: 8, nueve: 9 };
const NUM_TENS = {
  diez: 10, once: 11, doce: 12, trece: 13, catorce: 14, quince: 15,
  veinte: 20, veintiun: 21, veintidos: 22, veintitres: 23, veinticuatro: 24, veinticinco: 25,
  veintiseis: 26, veintisiete: 27, veintiocho: 28, veintinueve: 29,
  treinta: 30, cuarenta: 40, cincuenta: 50, sesenta: 60, setenta: 70, ochenta: 80, noventa: 90
};
const NUM_HUND = { cien: 100, ciento: 100, doscientos: 200, trescientos: 300, cuatrocientos: 400, quinientos: 500, seiscientos: 600, setecientos: 700, ochocientos: 800, novecientos: 900 };

// Convierte una cadena como "treinta y dos" o "3,5" a número. Devuelve null si no es un número.
function parseSpanishNumber(str) {
  if (str == null) return null;
  const s = stripAccents(String(str)).trim();
  if (/^[-+]?\d+(?:[.,]\d+)?$/.test(s)) return parseFloat(s.replace(',', '.'));
  const parts = s.split(/\s+/);
  let result = 0, current = 0, decimal = null, has = false;
  for (const p of parts) {
    if (p === 'y') continue;
    if (p === 'punto' || p === 'coma') { decimal = ''; continue; }
    if (p === 'mil') { if (current === 0) current = 1; result += current * 1000; current = 0; has = true; continue; }
    if (p === 'millon' || p === 'millones') { result = (result + current) * 1000000; current = 0; has = true; continue; }
    let v = null;
    if (/^\d+$/.test(p)) v = parseInt(p, 10);
    else if (NUM_UNITS[p] != null) v = NUM_UNITS[p];
    else if (NUM_TENS[p] != null) v = NUM_TENS[p];
    else if (NUM_HUND[p] != null) v = NUM_HUND[p];
    if (v == null) { if (decimal === null) return null; continue; }
    has = true;
    if (decimal !== null) { decimal += String(v); continue; }
    current += v;
  }
  if (decimal !== null) {
    result += current;
    const digits = decimal.replace(/^0+/, '');
    if (digits) result += parseInt(digits, 10) / Math.pow(10, digits.length);
  } else {
    result += current;
  }
  return has ? result : null;
}

// Sustituye números en palabras por dígitos dentro de una cadena ("dos mil" -> "2000").
const isNumToken = p => NUM_UNITS[p] != null || NUM_TENS[p] != null || NUM_HUND[p] != null ||
  p === 'mil' || p === 'millon' || p === 'millones' || /^[\d.,]+$/.test(p);

function replaceWordsWithNumbers(text) {
  const tokens = stripAccents(String(text)).split(/\s+/);
  const out = [];
  let i = 0;
  while (i < tokens.length) {
    if (isNumToken(tokens[i])) {
      const buf = [];
      while (i < tokens.length && isNumToken(tokens[i])) { buf.push(tokens[i]); i++; }
      const v = parseSpanishNumber(buf.join(' '));
      out.push(v != null ? String(v) : buf.join(' '));
    } else {
      out.push(tokens[i]); i++;
    }
  }
  return out.join(' ');
}

// ---------- Persistencia ----------
const Storage = {
  get(key, dflt) {
    try {
      const v = localStorage.getItem('jarvis_' + key);
      return v === null ? dflt : JSON.parse(v);
    } catch (e) { return dflt; }
  },
  set(key, val) {
    try { localStorage.setItem('jarvis_' + key, JSON.stringify(val)); } catch (e) { /* cuota o modo privado */ }
  }
};

// ---------- Clima simulado determinista ----------
function mulberry(a) {
  return function () {
    a |= 0; a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
function computeWeather() {
  const d = new Date();
  const seed = d.getFullYear() * 100000 + (d.getMonth() + 1) * 1000 + d.getDate() * 10 + d.getHours();
  const rnd = mulberry(seed);
  const conds = ['despejado', 'ligeramente nublado', 'nublado', 'viento suave', 'brisa marina', 'bruma ligera', 'despejado con nubes altas'];
  return {
    temp: 14 + Math.round(rnd() * 20),
    cond: conds[Math.floor(rnd() * conds.length)],
    hum: 30 + Math.round(rnd() * 45),
    wind: 4 + Math.round(rnd() * 18)
  };
}
