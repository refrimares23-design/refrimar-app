/* =====================================================================
   J.A.R.V.I.S. // visualizer.js
   Animación del núcleo central (arc reactor) con estados reactivos:
   - REPOSO: pulso lento
   - ESCUCHANDO: anillos concéntricos reaccionan al volumen real del mic
   - PROCESANDO: barrido tipo radar
   - HABLANDO: ecualizador radial sincronizado con la síntesis de voz
   También dibuja el campo de estrellas de fondo.
   ===================================================================== */
'use strict';

const Vis = {
  stars: [],
  starsCv: null,
  coreCv: null,
  ringPhase: 0,

  init() {
    this.starsCv = J.el.starsCanvas;
    this.coreCv = J.el.coreCanvas;
    this.buildStars();
    this.loop();
    window.addEventListener('resize', () => this.buildStars());
  },

  // ---------- Campo de estrellas ----------
  buildStars() {
    if (!this.starsCv) return;
    const dpr = window.devicePixelRatio || 1;
    this.starsCv.width = window.innerWidth * dpr;
    this.starsCv.height = window.innerHeight * dpr;
    const count = Math.min(130, Math.floor(window.innerWidth / 9));
    this.stars = [];
    for (let i = 0; i < count; i++) {
      this.stars.push({
        x: Math.random() * this.starsCv.width,
        y: Math.random() * this.starsCv.height,
        r: Math.random() * 1.4 + 0.3,
        sp: Math.random() * 0.16 + 0.02,
        tw: Math.random() * Math.PI * 2
      });
    }
  },

  drawStars() {
    const cv = this.starsCv;
    if (!cv) return;
    const ctx = cv.getContext('2d');
    const t = performance.now() / 1000;
    ctx.clearRect(0, 0, cv.width, cv.height);
    ctx.fillStyle = '#8fd8ff';
    for (const s of this.stars) {
      s.x -= s.sp;
      s.y += s.sp * 0.25;
      if (s.x < 0) s.x = cv.width;
      if (s.y > cv.height) s.y = 0;
      const a = 0.18 + 0.45 * (0.5 + 0.5 * Math.sin(t * 1.6 + s.tw));
      ctx.globalAlpha = a;
      ctx.beginPath();
      ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  },

  // ---------- Núcleo central ----------
  drawCore() {
    const cv = this.coreCv;
    if (!cv) return;
    const ctx = cv.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const S = cv.getBoundingClientRect().width || 320;
    if (cv.width !== Math.round(S * dpr)) { cv.width = Math.round(S * dpr); cv.height = Math.round(S * dpr); }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, S, S);

    const t = performance.now() / 1000;
    const cx = S / 2, cy = S / 2;
    const st = J.state;
    const idle = st === 'IDLE' || st === 'STANDBY';
    const listening = st === 'LISTENING';
    const speaking = st === 'SPEAKING';
    const processing = st === 'PROCESSING';

    // Resplandor general
    const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, S * 0.5);
    g.addColorStop(0, 'rgba(0,229,255,0.13)');
    g.addColorStop(1, 'rgba(0,229,255,0)');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, S, S);

    // Anillo exterior fijo con marcas de graduación
    ctx.strokeStyle = 'rgba(0,229,255,0.55)';
    ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.arc(cx, cy, S * 0.47, 0, Math.PI * 2); ctx.stroke();
    ctx.strokeStyle = 'rgba(140,220,255,0.6)';
    ctx.lineWidth = 1;
    for (let a = 0; a < 360; a += 6) {
      const rad = (a - 90) * Math.PI / 180;
      const r1 = S * 0.47, r2 = a % 30 === 0 ? S * 0.50 : S * 0.485;
      ctx.beginPath();
      ctx.moveTo(cx + Math.cos(rad) * r1, cy + Math.sin(rad) * r1);
      ctx.lineTo(cx + Math.cos(rad) * r2, cy + Math.sin(rad) * r2);
      ctx.stroke();
    }

    // Anillo punteado rotatorio + arco contrarrotatorio
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(t * 0.15);
    ctx.strokeStyle = 'rgba(0,229,255,0.25)';
    ctx.lineWidth = 1;
    ctx.setLineDash([6, 14]);
    ctx.beginPath(); ctx.arc(0, 0, S * 0.40, 0, Math.PI * 2); ctx.stroke();
    ctx.rotate(-t * 0.40);
    ctx.strokeStyle = 'rgba(255,255,255,0.5)';
    ctx.setLineDash([]);
    ctx.beginPath(); ctx.arc(0, 0, S * 0.335, -Math.PI / 2, Math.PI / 6); ctx.stroke();
    ctx.restore();

    // Bobinas del reactor (triángulo giratorio)
    const coils = 3;
    const coilR = S * 0.115, coilDist = S * 0.26;
    const spin = processing ? t * 1.6 : speaking ? t * 0.5 : t * 0.18;
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(spin);
    ctx.strokeStyle = 'rgba(0,229,255,0.85)';
    for (let i = 0; i < coils; i++) {
      const a = i * Math.PI * 2 / 3 - Math.PI / 2;
      const x = Math.cos(a) * coilDist, y = Math.sin(a) * coilDist;
      ctx.lineWidth = 2;
      ctx.beginPath(); ctx.arc(x, y, coilR, 0, Math.PI * 2); ctx.stroke();
      ctx.lineWidth = 1;
      ctx.beginPath(); ctx.arc(x, y, coilR * 0.45, 0, Math.PI * 2); ctx.stroke();
      ctx.beginPath(); ctx.arc(x, y, coilR * 0.12, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(130,240,255,0.9)'; ctx.fill();
    }
    ctx.strokeStyle = 'rgba(0,229,255,0.35)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let i = 0; i < coils; i++) {
      const a = i * Math.PI * 2 / 3 - Math.PI / 2;
      const x = Math.cos(a) * coilDist, y = Math.sin(a) * coilDist;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.closePath(); ctx.stroke();
    ctx.restore();

    // Líneas de mira
    ctx.strokeStyle = 'rgba(0,229,255,0.16)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(cx - S * 0.47, cy); ctx.lineTo(cx + S * 0.47, cy);
    ctx.moveTo(cx, cy - S * 0.47); ctx.lineTo(cx, cy + S * 0.47);
    ctx.stroke();

    // Núcleo brillante
    const pulse = idle ? 0.5 + 0.5 * Math.sin(t * 0.6)
      : speaking ? 0.6 + 0.4 * Math.sin(t * 6)
      : 0.7 + 0.3 * Math.sin(t * 2.4);
    let coreR = S * 0.075 * (0.75 + pulse * 0.5 +
      (listening ? J.micLevel * 0.9 : speaking ? J.synthEnergy : processing ? 0.15 * Math.abs(Math.sin(t * 8)) : 0));
    coreR = Math.max(6, coreR);
    const coreAlpha = processing ? '255,255,255,' : listening ? '0,229,255,' : speaking ? '0,255,200,' : '0,229,255,';
    const cg = ctx.createRadialGradient(cx, cy, 0, cx, cy, coreR * 2.4);
    cg.addColorStop(0, 'rgba(' + coreAlpha + '0.95)');
    cg.addColorStop(0.45, 'rgba(' + coreAlpha + '0.40)');
    cg.addColorStop(1, 'rgba(0,229,255,0)');
    ctx.fillStyle = cg;
    ctx.beginPath(); ctx.arc(cx, cy, coreR * 2.4, 0, Math.PI * 2); ctx.fill();
    const inner = ctx.createRadialGradient(cx, cy, 0, cx, cy, coreR);
    inner.addColorStop(0, '#ffffff');
    inner.addColorStop(0.5, 'rgba(' + coreAlpha + '0.9)');
    inner.addColorStop(1, 'rgba(' + coreAlpha + '0.2)');
    ctx.fillStyle = inner;
    ctx.beginPath(); ctx.arc(cx, cy, coreR, 0, Math.PI * 2); ctx.fill();

    // ---------- ESCUCHANDO: anillos reaccionando al micrófono ----------
    if (listening) {
      this.ringPhase = (this.ringPhase + (0.035 + J.micLevel * 0.12)) % 1;
      const rings = 5;
      for (let i = 0; i < rings; i++) {
        const ph = (this.ringPhase + i / rings) % 1;
        const spread = S * 0.32 * (0.55 + J.micLevel);
        const r = S * 0.085 + ph * spread;
        const alpha = (1 - ph) * (0.45 + J.micLevel * 0.5);
        ctx.strokeStyle = 'rgba(0,229,255,' + (alpha * 0.6).toFixed(3) + ')';
        ctx.lineWidth = 1.5;
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke();
      }
      // Arco de nivel
      const arcRad = Math.PI * 1.5;
      ctx.strokeStyle = 'rgba(255,255,255,0.7)';
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(cx, cy, S * 0.47, -arcRad / 2, -arcRad / 2 + arcRad * clamp(J.micLevel, 0, 1));
      ctx.stroke();
    }

    // ---------- PROCESANDO: barrido tipo radar ----------
    if (processing) {
      const sweep = (t * 2.6) % (Math.PI * 2);
      ctx.strokeStyle = 'rgba(255,255,255,0.85)';
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.lineTo(cx + Math.cos(sweep - Math.PI / 2) * S * 0.46, cy + Math.sin(sweep - Math.PI / 2) * S * 0.46);
      ctx.stroke();
      ctx.strokeStyle = 'rgba(0,229,255,0.5)';
      ctx.lineWidth = 4;
      ctx.beginPath();
      ctx.arc(cx, cy, S * 0.46, sweep - Math.PI / 2 - 0.35, sweep - Math.PI / 2);
      ctx.stroke();
      for (let i = 0; i < 4; i++) {
        const a = (t * 1.5 + i * Math.PI / 2) % (Math.PI * 2);
        ctx.beginPath();
        ctx.arc(cx + Math.cos(a) * S * 0.47, cy + Math.sin(a) * S * 0.47, 2.5, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(255,255,255,0.9)';
        ctx.fill();
      }
    }

    // ---------- HABLANDO: ecualizador radial ----------
    if (speaking) {
      const bars = 48;
      const e = J.synthEnergy;
      for (let i = 0; i < bars; i++) {
        const a = i / bars * Math.PI * 2 - Math.PI / 2;
        const wave = 0.5 + 0.5 * Math.sin(t * 9 + i * 0.7);
        const len = (e * (0.25 + 0.75 * wave)) * S * 0.24;
        const r0 = S * 0.24, r1 = r0 + len;
        ctx.strokeStyle = 'rgba(0,229,255,' + (0.35 + e * 0.55).toFixed(3) + ')';
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.moveTo(cx + Math.cos(a) * r0, cy + Math.sin(a) * r0);
        ctx.lineTo(cx + Math.cos(a) * r1, cy + Math.sin(a) * r1);
        ctx.stroke();
      }
    }

    // ---------- REPOSO PROFUNDO ----------
    if (st === 'STANDBY') {
      ctx.strokeStyle = 'rgba(120,150,170,0.28)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.arc(cx, cy, S * 0.13 + 4 * Math.sin(t * 0.4), 0, Math.PI * 2);
      ctx.stroke();
    }
  },

  // ---------- Bucle de animación ----------
  loop() {
    // Nivel del micrófono suavizado
    const raw = readMicLevel();
    J.micLevel += (raw - J.micLevel) * 0.35;
    if (J.state === 'SPEAKING') J.synthEnergy *= 0.90;
    if (J.state !== 'SPEAKING') J.synthEnergy = 0;
    this.drawStars();
    this.drawCore();
    requestAnimationFrame(() => this.loop());
  }
};
