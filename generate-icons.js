/**
 * Genera iconos PWA para REFRIMAR OS
 * Ejecuta: node generate-icons.js
 * Requiere: npm install canvas (ya está en package.json)
 */
const { createCanvas } = require('canvas');
const fs = require('fs');
const path = require('path');

const sizes = [192, 512];
const outDir = path.join(__dirname, 'icons');

if (!fs.existsSync(outDir)) fs.mkdirSync(outDir);

sizes.forEach(size => {
  const canvas = createCanvas(size, size);
  const ctx = canvas.getContext('2d');

  // Fondo azul REFRIMAR
  ctx.fillStyle = '#0058c3';
  ctx.beginPath();
  ctx.roundRect(0, 0, size, size, size * 0.18);
  ctx.fill();

  // Texto "R"
  ctx.fillStyle = '#ffffff';
  ctx.font = `bold ${size * 0.55}px Arial`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText('R', size / 2, size * 0.48);

  // Línea inferior
  ctx.strokeStyle = 'rgba(255,255,255,0.4)';
  ctx.lineWidth = size * 0.015;
  ctx.beginPath();
  ctx.moveTo(size * 0.25, size * 0.72);
  ctx.lineTo(size * 0.75, size * 0.72);
  ctx.stroke();

  // Subtexto
  ctx.fillStyle = 'rgba(255,255,255,0.7)';
  ctx.font = `bold ${size * 0.08}px Arial`;
  ctx.fillText('REFRIMAR', size / 2, size * 0.82);

  const buf = canvas.toBuffer('image/png');
  fs.writeFileSync(path.join(outDir, `icon-${size}.png`), buf);
  console.log(`Icono ${size}x${size} generado`);
});

console.log('Listo! Iconos en /icons/');
