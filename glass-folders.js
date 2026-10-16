/* REFRIMAR · Carpetas de vidrio (adaptación sin React de "Glass Folder Cards").
 * Una carpeta dibujada como objeto: panel trasero con arte generado, los
 * documentos adentro y un panel frontal de vidrio esmerilado.
 *   - Reposo: cerrada.  - Hover/foco: el vidrio se inclina y los documentos asoman.
 *   - Clic / Enter: se abre y los documentos se abren en abanico (cada uno es un enlace).
 *   - Botón +: acción rápida (crear uno nuevo).
 * Uso: RefCarpeta(contenedor, { label, meta, tone, art, seed, files:[{name, meta, href, art}], onAdd, addLabel, width })
 */
(function () {
    'use strict';
    var CSS = ".gf-root {\n  --gf-px: 0;\n  --gf-py: 0;\n  --gf-ease: cubic-bezier(.2, .8, .2, 1);\n  --gf-spring: cubic-bezier(.34, 1.36, .5, 1);\n  --gf-hinge: 0deg;\n  --gf-lift: 42px;\n  --gf-spread: 0px;\n  --gf-fan: 0deg;\n  --gf-stack: 15px;\n  --gf-ink: #141416;\n  --gf-ink-soft: rgba(20, 20, 22, .55);\n  position: relative;\n  display: inline-block;\n  flex: none;\n  vertical-align: top;\n  font-family: ui-sans-serif, system-ui, -apple-system, \"SF Pro Text\", \"Segoe UI\", Roboto, \"Helvetica Neue\", Arial, sans-serif;\n  -webkit-font-smoothing: antialiased;\n  -webkit-tap-highlight-color: transparent;\n  isolation: isolate;\n}\n.gf-root[data-tone=\"dark\"] { --gf-ink: #f5f5f7; --gf-ink-soft: rgba(245, 245, 247, .58); }\n.gf-root:hover, .gf-root:focus-within { --gf-hinge: -11deg; --gf-lift: -34px; --gf-spread: 8px; --gf-fan: 1.4deg; --gf-stack: 10px; }\n.gf-root[data-open] { --gf-hinge: -24deg; --gf-lift: -96px; --gf-spread: 40px; --gf-fan: 5deg; --gf-stack: 30px; }\n\n.gf-stage {\n  position: absolute;\n  left: 0;\n  top: 0;\n  width: 340px;\n  height: 272px;\n  transform-origin: 0 0;\n}\n.gf-tilt {\n  position: absolute;\n  inset: 0;\n  transform: perspective(1400px) rotateX(calc(var(--gf-py) * -3deg)) rotateY(calc(var(--gf-px) * 4deg));\n  transition: transform .9s var(--gf-ease);\n}\n\n.gf-shadow {\n  position: absolute;\n  left: 18px;\n  right: 18px;\n  bottom: -6px;\n  height: 60px;\n  border-radius: 40px;\n  background: rgba(16, 18, 24, .34);\n  filter: blur(22px);\n  transform: translateX(calc(var(--gf-px) * -8px));\n  transition: transform .9s var(--gf-ease), opacity .9s var(--gf-ease);\n}\n.gf-root[data-tone=\"dark\"] .gf-shadow { background: rgba(0, 0, 0, .62); }\n\n.gf-back {\n  position: absolute;\n  inset: 0;\n  overflow: hidden;\n  background: linear-gradient(180deg, #f3f3f4 0%, #e3e3e6 100%);\n}\n.gf-root[data-tone=\"dark\"] .gf-back { background: linear-gradient(180deg, #2a2a2e 0%, #121214 100%); }\n.gf-art {\n  position: absolute;\n  left: -12px;\n  top: -12px;\n  max-width: none;\n  object-fit: cover;\n  transform: translate(calc(var(--gf-px) * -7px), calc(var(--gf-py) * -6px)) scale(1.02);\n  transition: transform 1.1s var(--gf-ease), opacity 1.2s var(--gf-ease), filter 1.2s var(--gf-ease);\n}\ncanvas.gf-art { opacity: 0; filter: blur(14px) saturate(.6); }\ncanvas.gf-art[data-ready] { opacity: 1; filter: none; }\n.gf-back-sheen {\n  position: absolute;\n  inset: 0;\n  background:\n    linear-gradient(180deg, rgba(255, 255, 255, .22) 0%, rgba(255, 255, 255, 0) 22%),\n    radial-gradient(120% 80% at 80% 0%, rgba(255, 255, 255, .16), rgba(255, 255, 255, 0) 60%);\n  pointer-events: none;\n}\n\n.gf-rim {\n  position: absolute;\n  left: 0;\n  top: 0;\n  max-width: none;\n  overflow: visible;\n  pointer-events: none;\n  fill: none;\n}\n.gf-back-rim { width: 340px; height: 272px; }\n.gf-back-rim path { stroke: rgba(255, 255, 255, .45); stroke-width: 1; }\n.gf-root[data-tone=\"dark\"] .gf-back-rim path { stroke: rgba(255, 255, 255, .16); }\n\n/* ---- files ---------------------------------------------------------------- */\n.gf-files {\n  position: absolute;\n  inset: 0;\n  z-index: 5;\n  pointer-events: none;\n  /* nothing hangs out of the bottom of the pocket, however tall the stack */\n  clip-path: inset(-400px -400px 10px -400px);\n}\n.gf-sheet-slot { display: contents; }\n.gf-sheet {\n  all: unset;\n  box-sizing: border-box;\n  position: absolute;\n  left: 34px;\n  top: 96px;\n  width: 272px;\n  height: 184px;\n  border-radius: 16px;\n  overflow: hidden;\n  cursor: pointer;\n  pointer-events: auto;\n  background: linear-gradient(180deg, #ffffff 0%, #f2f2f0 100%);\n  box-shadow:\n    inset 0 1px 0 rgba(255, 255, 255, .9),\n    0 0 0 .5px rgba(0, 0, 0, .1),\n    0 10px 26px -8px rgba(10, 12, 20, .28);\n  transform-origin: 50% 100%;\n  transform:\n    translate(calc(var(--gf-jx) + var(--gf-slot) * var(--gf-spread)), calc(var(--gf-lift) + var(--gf-depth) * var(--gf-stack) * -1))\n    rotate(calc(var(--gf-jr) + var(--gf-slot) * var(--gf-fan)));\n  transition:\n    transform .75s var(--gf-spring) calc(var(--gf-depth) * 40ms),\n    box-shadow .4s var(--gf-ease),\n    translate .9s var(--gf-ease),\n    opacity .9s var(--gf-ease);\n}\n.gf-root[data-tone=\"dark\"] .gf-sheet { background: linear-gradient(180deg, #2c2c30 0%, #1c1c1f 100%); box-shadow: inset 0 1px 0 rgba(255, 255, 255, .14), 0 0 0 .5px rgba(255, 255, 255, .08), 0 12px 28px -8px rgba(0, 0, 0, .7); }\n.gf-sheet--art { background: #1a1a1d; }\n.gf-root[data-open] .gf-sheet:hover,\n.gf-root[data-open] .gf-sheet:focus-visible {\n  transform:\n    translate(calc(var(--gf-jx) + var(--gf-slot) * var(--gf-spread)), calc(var(--gf-lift) + var(--gf-depth) * var(--gf-stack) * -1 - 18px))\n    rotate(calc(var(--gf-slot) * var(--gf-fan) * .6));\n  box-shadow: inset 0 1px 0 rgba(255, 255, 255, .9), 0 0 0 .5px rgba(0, 0, 0, .1), 0 22px 40px -12px rgba(10, 12, 20, .42);\n  transition-delay: 0s;\n}\n.gf-sheet:focus-visible { outline: 2px solid #4c8dff; outline-offset: 2px; }\n.gf-sheet-art {\n  position: absolute;\n  left: 0;\n  top: 0;\n  width: 272px;\n  height: 184px;\n  max-width: none;\n  object-fit: cover;\n  transition: opacity .9s var(--gf-ease), filter .9s var(--gf-ease);\n}\ncanvas.gf-sheet-art { opacity: 0; filter: blur(10px); }\ncanvas.gf-sheet-art[data-ready] { opacity: 1; filter: none; }\n.gf-sheet--art::after {\n  content: \"\";\n  position: absolute;\n  inset: 0;\n  border-radius: inherit;\n  background: linear-gradient(180deg, rgba(0, 0, 0, .42) 0%, rgba(0, 0, 0, 0) 34%);\n  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, .2);\n  pointer-events: none;\n}\n.gf-sheet-head {\n  position: absolute;\n  left: 14px;\n  right: 14px;\n  top: 11px;\n  z-index: 1;\n  display: flex;\n  align-items: baseline;\n  justify-content: space-between;\n  gap: 10px;\n  white-space: nowrap;\n}\n.gf-sheet-name {\n  overflow: hidden;\n  text-overflow: ellipsis;\n  font-size: 12.5px;\n  font-weight: 560;\n  letter-spacing: -.005em;\n  color: #18181b;\n}\n.gf-sheet-meta {\n  flex: none;\n  font-family: ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, monospace;\n  font-size: 10px;\n  letter-spacing: .02em;\n  color: rgba(24, 24, 27, .5);\n}\n.gf-root[data-tone=\"dark\"] .gf-sheet-name, .gf-sheet--art .gf-sheet-name { color: #fafafa; }\n.gf-root[data-tone=\"dark\"] .gf-sheet-meta, .gf-sheet--art .gf-sheet-meta { color: rgba(250, 250, 250, .66); }\n.gf-lines {\n  position: absolute;\n  left: 14px;\n  right: 14px;\n  top: 40px;\n  display: flex;\n  flex-direction: column;\n  gap: 9px;\n}\n.gf-lines i {\n  display: block;\n  height: 5px;\n  border-radius: 3px;\n  background: rgba(24, 24, 27, .08);\n}\n.gf-lines i:first-child { height: 9px; margin-bottom: 4px; background: rgba(24, 24, 27, .14); }\n.gf-root[data-tone=\"dark\"] .gf-lines i { background: rgba(255, 255, 255, .08); }\n.gf-root[data-tone=\"dark\"] .gf-lines i:first-child { background: rgba(255, 255, 255, .16); }\n\n.gf-sheet--drop { animation: gf-drop .85s var(--gf-ease) both; }\n@keyframes gf-drop {\n  0% { translate: 0 -190px; rotate: -9deg; opacity: 0; }\n  35% { opacity: 1; }\n  72% { translate: 0 10px; rotate: 1deg; }\n  100% { translate: 0 0; rotate: 0deg; opacity: 1; }\n}\n\n/* ---- front glass ----------------------------------------------------------- */\n.gf-front {\n  position: absolute;\n  left: 0;\n  top: 74px;\n  width: 340px;\n  height: 198px;\n  z-index: 10;\n  -webkit-backdrop-filter: blur(22px) saturate(1.5);\n  backdrop-filter: blur(22px) saturate(1.5);\n  transform-origin: 50% 100%;\n  transform: perspective(760px) rotateX(var(--gf-hinge));\n  transition: transform .8s var(--gf-spring), translate 1s var(--gf-ease), opacity 1s var(--gf-ease);\n}\n.gf-front--bump { animation: gf-bump .7s var(--gf-ease) .38s both; }\n@keyframes gf-bump {\n  0% { scale: 1; }\n  35% { scale: 1.018 .975; }\n  70% { scale: .996 1.006; }\n  100% { scale: 1; }\n}\n.gf-tint {\n  position: absolute;\n  inset: 0;\n  background:\n    linear-gradient(180deg, rgba(255, 255, 255, .16) 0%, rgba(255, 255, 255, .5) 42%, rgba(252, 252, 252, .93) 100%);\n}\n.gf-root[data-tone=\"dark\"] .gf-tint {\n  background: linear-gradient(180deg, rgba(18, 18, 20, .18) 0%, rgba(14, 14, 16, .62) 46%, rgba(8, 8, 10, .94) 100%);\n}\n.gf-spec {\n  position: absolute;\n  inset: 0;\n  background: radial-gradient(260px 200px at calc(50% + var(--gf-px) * 46%) calc(30% + var(--gf-py) * 40%), rgba(255, 255, 255, .5), rgba(255, 255, 255, 0) 70%);\n  mix-blend-mode: soft-light;\n  opacity: .9;\n  transition: background-position .6s var(--gf-ease);\n  pointer-events: none;\n}\n.gf-root[data-tone=\"dark\"] .gf-spec { mix-blend-mode: screen; opacity: .16; }\n.gf-front-rim { width: 340px; height: 198px; }\n.gf-front-rim path { stroke-width: 2.4; transition: stroke-width .3s var(--gf-ease); }\n.gf-root[data-tone=\"dark\"] .gf-front-rim { opacity: .55; }\n\n.gf-hit {\n  all: unset;\n  position: absolute;\n  inset: 0;\n  z-index: 1;\n  cursor: pointer;\n}\n.gf-hit:focus-visible ~ .gf-label .gf-title { text-decoration: underline; text-decoration-thickness: 1.5px; text-underline-offset: 4px; }\n.gf-front:has(.gf-hit:focus-visible) .gf-front-rim path { stroke-width: 5; }\n\n.gf-label {\n  position: absolute;\n  z-index: 2;\n  display: flex;\n  flex-direction: column;\n  gap: 4px;\n  max-width: 200px;\n  pointer-events: none;\n  color: var(--gf-ink);\n}\n.gf-root[data-place=\"bottom-left\"] .gf-label { left: 28px; bottom: 32px; }\n.gf-root[data-place=\"top-left\"] .gf-label { left: 28px; top: 34px; }\n.gf-root[data-place=\"top-right\"] .gf-label { right: 32px; top: 52px; align-items: flex-start; }\n.gf-title {\n  font-size: 18px;\n  font-weight: 500;\n  line-height: 1.15;\n  letter-spacing: -.012em;\n  overflow: hidden;\n  text-overflow: ellipsis;\n  white-space: nowrap;\n}\n.gf-meta {\n  font-family: ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, monospace;\n  font-size: 12px;\n  letter-spacing: .03em;\n  color: var(--gf-ink-soft);\n  white-space: nowrap;\n  animation: gf-roll .5s var(--gf-ease) both;\n}\n@keyframes gf-roll {\n  from { opacity: 0; translate: 0 7px; filter: blur(3px); }\n  to { opacity: 1; translate: 0 0; filter: blur(0); }\n}\n\n/* ---- the key: + or \u00b7\u00b7\u00b7 ------------------------------------------------------ */\n.gf-key {\n  all: unset;\n  box-sizing: border-box;\n  position: absolute;\n  right: 22px;\n  bottom: 22px;\n  z-index: 12;\n  width: 58px;\n  height: 58px;\n  border-radius: 18px;\n  display: grid;\n  place-items: center;\n  cursor: pointer;\n  transition: transform .35s var(--gf-spring), box-shadow .35s var(--gf-ease), background .35s var(--gf-ease);\n}\n.gf-key:hover { transform: translateY(-2px); }\n.gf-key:active { transform: translateY(0) scale(.93); transition-duration: .12s; }\n.gf-key:focus-visible { outline: 2px solid #4c8dff; outline-offset: 3px; }\n.gf-key--add {\n  color: #fff;\n  background: radial-gradient(120% 90% at 50% 0%, #3a3a3f 0%, #121214 55%, #050506 100%);\n  box-shadow:\n    inset 0 1px 0 rgba(255, 255, 255, .22),\n    inset 0 -3px 8px rgba(0, 0, 0, .7),\n    0 0 0 1px rgba(0, 0, 0, .75),\n    0 14px 22px -8px rgba(0, 0, 0, .55),\n    0 3px 6px -2px rgba(0, 0, 0, .35);\n}\n.gf-root[data-tone=\"dark\"] .gf-key--add {\n  color: #111113;\n  background: radial-gradient(120% 90% at 50% 0%, #ffffff 0%, #ececee 55%, #d2d2d6 100%);\n  box-shadow: inset 0 1px 0 #fff, inset 0 -3px 8px rgba(0, 0, 0, .14), 0 0 0 1px rgba(0, 0, 0, .4), 0 14px 22px -8px rgba(0, 0, 0, .7);\n}\n.gf-key--more {\n  color: #111113;\n  background: linear-gradient(180deg, rgba(255, 255, 255, .92) 0%, rgba(226, 226, 230, .82) 100%);\n  -webkit-backdrop-filter: blur(10px);\n  backdrop-filter: blur(10px);\n  box-shadow:\n    inset 0 1px 0 #fff,\n    inset 0 -2px 4px rgba(0, 0, 0, .06),\n    0 0 0 1px rgba(0, 0, 0, .16),\n    0 10px 18px -8px rgba(0, 0, 0, .3);\n}\n.gf-root[data-tone=\"dark\"] .gf-key--more {\n  color: #f5f5f7;\n  background: linear-gradient(180deg, rgba(255, 255, 255, .16) 0%, rgba(255, 255, 255, .06) 100%);\n  box-shadow: inset 0 1px 0 rgba(255, 255, 255, .22), 0 0 0 1px rgba(255, 255, 255, .1), 0 10px 18px -8px rgba(0, 0, 0, .6);\n}\n.gf-key--more[aria-expanded=\"true\"] { transform: scale(.96); }\n.gf-glyph { display: block; max-width: none; fill: none; stroke: currentColor; stroke-linecap: round; }\n.gf-glyph--plus { width: 26px; height: 26px; stroke-width: 1.6; animation: gf-turn .6s var(--gf-spring); }\n.gf-glyph--more { width: 30px; height: 12px; stroke-width: 1.7; }\n@keyframes gf-turn { from { rotate: -90deg; } to { rotate: 0deg; } }\n\n/* ---- menu ------------------------------------------------------------------- */\n.gf-menu {\n  position: absolute;\n  right: 22px;\n  bottom: 90px;\n  z-index: 20;\n  min-width: 176px;\n  padding: 6px;\n  border-radius: 16px;\n  display: flex;\n  flex-direction: column;\n  background: rgba(252, 252, 253, .72);\n  -webkit-backdrop-filter: blur(24px) saturate(1.6);\n  backdrop-filter: blur(24px) saturate(1.6);\n  box-shadow: inset 0 1px 0 rgba(255, 255, 255, .9), 0 0 0 .5px rgba(0, 0, 0, .14), 0 24px 48px -16px rgba(10, 12, 20, .4);\n  transform-origin: 100% 100%;\n  opacity: 0;\n  visibility: hidden;\n  transform: translateY(6px) scale(.94);\n  transition: opacity .2s var(--gf-ease), transform .32s var(--gf-spring), visibility 0s .32s;\n}\n.gf-menu[data-open] { opacity: 1; visibility: visible; transform: none; transition-delay: 0s; }\n.gf-root[data-tone=\"dark\"] .gf-menu { background: rgba(30, 30, 34, .72); box-shadow: inset 0 1px 0 rgba(255, 255, 255, .1), 0 0 0 .5px rgba(255, 255, 255, .1), 0 24px 48px -16px rgba(0, 0, 0, .8); }\n.gf-menu-item {\n  all: unset;\n  box-sizing: border-box;\n  padding: 9px 12px;\n  border-radius: 10px;\n  font-size: 13.5px;\n  font-weight: 450;\n  color: #18181b;\n  cursor: pointer;\n}\n.gf-root[data-tone=\"dark\"] .gf-menu-item { color: #f4f4f5; }\n.gf-menu-item:hover, .gf-menu-item:focus-visible { background: rgba(24, 24, 27, .07); }\n.gf-root[data-tone=\"dark\"] .gf-menu-item:hover, .gf-root[data-tone=\"dark\"] .gf-menu-item:focus-visible { background: rgba(255, 255, 255, .09); }\n.gf-menu-item--danger { color: #d92d20; }\n.gf-root[data-tone=\"dark\"] .gf-menu-item--danger { color: #ff6b5e; }\n\n/* ---- entrance: the folder assembles itself ---------------------------------- */\n.gf-root:not([data-entered]) .gf-back,\n.gf-root:not([data-entered]) .gf-back-rim { translate: 0 22px; opacity: 0; }\n.gf-root:not([data-entered]) .gf-sheet { translate: 0 -120px; opacity: 0; }\n.gf-root:not([data-entered]) .gf-front { translate: 0 46px; opacity: 0; }\n.gf-root:not([data-entered]) .gf-key { opacity: 0; scale: .6; }\n.gf-root:not([data-entered]) .gf-shadow { opacity: 0; }\n.gf-back, .gf-back-rim { transition: translate 1s var(--gf-ease), opacity .9s var(--gf-ease); }\n.gf-root[data-entered] .gf-sheet { transition-delay: calc(var(--gf-depth) * 40ms), 0s, calc(.18s + var(--gf-depth) * 90ms), calc(.18s + var(--gf-depth) * 90ms); }\n.gf-root[data-entered] .gf-front { transition-delay: 0s, .42s, .42s; }\n.gf-key { transition: transform .35s var(--gf-spring), box-shadow .35s var(--gf-ease), opacity .6s var(--gf-ease) .7s, scale .7s var(--gf-spring) .7s; }\n\n@media (prefers-reduced-motion: reduce) {\n  .gf-root *, .gf-root *::before, .gf-root *::after {\n    transition-duration: 0s !important;\n    transition-delay: 0s !important;\n    animation: none !important;\n  }\n  .gf-tilt { transform: none; }\n}\n\n/* ---- ajustes REFRIMAR ---- */\n.gf-root { font-family: \"Poppins\", \"Inter\", ui-sans-serif, system-ui, \"Segoe UI\", Roboto, Arial, sans-serif; --gf-ink: #0A2540; --gf-ink-soft: rgba(10, 37, 64, .55); }\n.gf-title { font-weight: 700; letter-spacing: -.02em; }\n.gf-meta, .gf-sheet-meta { font-family: \"Inter\", ui-monospace, Menlo, Consolas, monospace; }\n.gf-sheet { text-decoration: none; color: #0A2540; }\n.gf-sheet-name { font-weight: 600; color: #0A2540; }\n.gf-sheet-det { position: absolute; left: 14px; right: 14px; top: 32px; z-index: 1; font-size: 19px; font-weight: 800; letter-spacing: -.02em; color: #0A2540; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }\n.gf-sheet-det + .gf-lines, .gf-sheet:has(.gf-sheet-det) .gf-lines { top: 66px; }\n.gf-sheet:focus-visible, .gf-key:focus-visible { outline-color: #00AAFF; }\n.gf-tint { background: linear-gradient(180deg, rgba(230, 246, 255, .16) 0%, rgba(240, 249, 255, .55) 42%, rgba(250, 253, 255, .94) 100%); }\n.gf-key--add { color: #0A2540; background: radial-gradient(120% 90% at 50% 0%, #6fd2ff 0%, #00AAFF 55%, #0088cc 100%); box-shadow: inset 0 1px 0 rgba(255, 255, 255, .45), inset 0 -3px 8px rgba(0, 60, 100, .35), 0 0 0 1px rgba(0, 80, 130, .45), 0 14px 22px -8px rgba(0, 90, 150, .5), 0 3px 6px -2px rgba(0, 0, 0, .2); }\n.gf-root[data-tone=\"dark\"] { --gf-ink: #E6F6FF; --gf-ink-soft: rgba(230, 246, 255, .62); }\n@media (prefers-reduced-motion: reduce) { .gf-root *, .gf-root { transition-duration: .01ms !important; animation-duration: .01ms !important; } }\n";

    // ---------- arte generado (ruido con dominio deformado, sombreado como líquido) ----------
    var ART_PRESETS = {
        // Paletas REFRIMAR: celeste, marino y hielo
        celeste: { style: 'streak', colors: ['#f4fbff', '#cdeeff', '#5cc8ff', '#00aaff', '#0a2540', '#1f5f99', '#e6f6ff'], scale: 0.7, warp: 1.4, angle: -0.62, gloss: 0.2, veins: 0 },
        marino: { style: 'marble', colors: ['#050d18', '#0a2540', '#1f5f99', '#0b1a2c', '#008fd6', '#33bbff', '#d9f3ff'], scale: 0.62, warp: 3.2, angle: -0.5, gloss: 0.55, veins: 0.55 },
        hielo: { style: 'streak', colors: ['#f7fbfd', '#d9ecf6', '#9fcbe4', '#e8f4fa', '#bcdcee', '#ffffff'], scale: 0.7, warp: 1.6, angle: 0.35, gloss: 0.25, veins: 0 },
        aurora: { style: 'streak', colors: ['#f4efe9', '#e9c2b8', '#c2433f', '#2a1e2a', '#22395e', '#6f97c2', '#e5edf4'], scale: 0.7, warp: 1.4, angle: -0.62, gloss: 0.18, veins: 0 },
        ember: { style: 'marble', colors: ['#07090c', '#16252c', '#3d5f68', '#1a1416', '#a3201a', '#ef4a2b', '#ff8a5c'], scale: 0.62, warp: 3.2, angle: -0.5, gloss: 0.55, veins: 0.6 },
        verdant: { style: 'marble', colors: ['#070b08', '#173024', '#4f7a5a', '#141812', '#a7843a', '#e9cf87', '#fbf3d6'], scale: 0.7, warp: 3.4, angle: 2.1, gloss: 0.5, veins: 0.5 }
    };
    function hexToRgb(hex) { var h = String(hex).trim().replace(/^#/, ''); if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]; var n = /^[0-9a-f]{6}$/i.test(h) ? parseInt(h, 16) : 0x808080; return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; }
    function rng(seed) { var a = seed >>> 0; return function () { a = (a + 0x6d2b79f5) >>> 0; var t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
    function hashString(s) { var h = 2166136261; s = String(s); for (var i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619); return h >>> 0; }
    function makeFbm(seed) {
        var r = rng(seed), perm = new Uint8Array(512), grad = new Float32Array(512), p = [], i;
        for (i = 0; i < 256; i++) p.push(i);
        for (i = 255; i > 0; i--) { var j = Math.floor(r() * (i + 1)), t = p[i]; p[i] = p[j]; p[j] = t; }
        for (i = 0; i < 512; i++) perm[i] = p[i & 255];
        for (i = 0; i < 256; i++) { var a = r() * Math.PI * 2; grad[i * 2] = Math.cos(a); grad[i * 2 + 1] = Math.sin(a); }
        function noise(x, y) {
            var xi = Math.floor(x), yi = Math.floor(y), xf = x - xi, yf = y - yi, X = xi & 255, Y = yi & 255;
            var h00 = perm[X + perm[Y]] * 2, h10 = perm[X + 1 + perm[Y]] * 2, h01 = perm[X + perm[Y + 1]] * 2, h11 = perm[X + 1 + perm[Y + 1]] * 2;
            var d00 = grad[h00] * xf + grad[h00 + 1] * yf, d10 = grad[h10] * (xf - 1) + grad[h10 + 1] * yf, d01 = grad[h01] * xf + grad[h01 + 1] * (yf - 1), d11 = grad[h11] * (xf - 1) + grad[h11 + 1] * (yf - 1);
            var u = xf * xf * xf * (xf * (xf * 6 - 15) + 10), v = yf * yf * yf * (yf * (yf * 6 - 15) + 10);
            return d00 + u * (d10 - d00) + v * (d01 - d00 + u * (d11 - d01 - d10 + d00));
        }
        return function (x, y, oct) { var sum = 0, amp = 0.5; for (var k = 0; k < oct; k++) { sum += amp * noise(x, y); var nx = 1.6 * x + 1.2 * y + 7.1; y = -1.2 * x + 1.6 * y + 3.3; x = nx; amp *= 0.5; } return sum; };
    }
    function createArtJob(width, height, recipe, seed) {
        var w = Math.max(1, Math.round(width)), h = Math.max(1, Math.round(height));
        var colors = recipe.colors.length >= 2 ? recipe.colors : ['#111111', '#eeeeee'];
        var stops = colors.map(function (c, i) { return { t: i / (colors.length - 1), c: hexToRgb(c) }; });
        var scale = recipe.scale == null ? 0.7 : recipe.scale, warp = recipe.warp == null ? 3 : recipe.warp, gloss = recipe.gloss == null ? 0.4 : recipe.gloss, veins = recipe.veins || 0;
        var streak = recipe.style === 'streak', fbm = makeFbm(seed * 977 + 13), r = rng(seed + 1), ox = r() * 50, oy = r() * 50;
        var angle = (recipe.angle || 0) + (r() - 0.5) * 0.5, ca = Math.cos(angle), sa = Math.sin(angle), m = Math.min(w, h);
        var gw = Math.ceil(w / 2) + 3, gh = Math.ceil(h / 2) + 3, G = new Float32Array(gw * gh), GQ = new Float32Array(gw * gh);
        var F = new Float32Array(w * h), Q = new Float32Array(w * h), pixels = new Uint8ClampedArray(w * h * 4), row = 0;
        function field(gy) {
            for (var gx = 0; gx < gw; gx++) {
                var u = ((gx - 1) * 2 - w / 2) / m, v = ((gy - 1) * 2 - h / 2) / m;
                var px = (u * ca - v * sa) * scale, py = (u * sa + v * ca) * scale;
                if (streak) { px *= 0.14; py *= 2.2; }
                px += ox; py += oy;
                var qx = fbm(px, py, 3), qy = fbm(px + 5.2, py + 1.3, 3);
                var rx = fbm(px + warp * qx + 1.7, py + warp * qy + 9.2, 3), ry = fbm(px + warp * qx + 8.3, py + warp * qy + 2.8, 3);
                G[gy * gw + gx] = fbm(px + warp * rx, py + warp * ry, 4);
                GQ[gy * gw + gx] = Math.sqrt(qx * qx + qy * qy);
            }
        }
        function upsample() {
            function cr(a, b, c, d) { return (-a + 9 * b + 9 * c - d) / 16; }
            var T = new Float32Array(w * gh), x, y;
            for (var gy = 0; gy < gh; gy++) { var rr = gy * gw; for (x = 0; x < w; x++) { var c0 = (x >> 1) + 1; T[gy * w + x] = x & 1 ? cr(G[rr + c0 - 1], G[rr + c0], G[rr + c0 + 1], G[rr + c0 + 2]) : G[rr + c0]; } }
            for (y = 0; y < h; y++) {
                var c = (y >> 1) + 1;
                for (x = 0; x < w; x++) {
                    F[y * w + x] = y & 1 ? cr(T[(c - 1) * w + x], T[c * w + x], T[(c + 1) * w + x], T[(c + 2) * w + x]) : T[c * w + x];
                    var gx = (x >> 1) + 1, q0 = GQ[c * gw + gx], qxx = x & 1 ? (q0 + GQ[c * gw + gx + 1]) / 2 : q0;
                    var q1 = y & 1 ? (x & 1 ? (GQ[(c + 1) * gw + gx] + GQ[(c + 1) * gw + gx + 1]) / 2 : GQ[(c + 1) * gw + gx]) : qxx;
                    Q[y * w + x] = (qxx + q1) / 2;
                }
            }
        }
        function colorize() {
            var sample = [], stride = Math.max(1, Math.floor(F.length / 4096)), i;
            for (i = 0; i < F.length; i += stride) sample.push(F[i]);
            sample.sort(function (a, b) { return a - b; });
            var lo = sample[Math.floor(sample.length * 0.02)], hi = sample[Math.floor(sample.length * 0.98)], k = 1 / (hi - lo || 1);
            var lx = -0.55, ly = -0.65, lz = 0.52, slope = k * m * 0.012;
            for (var y = 0; y < h; y++) {
                for (var x = 0; x < w; x++) {
                    i = y * w + x;
                    var t = (F[i] - lo) * k; t = t < 0 ? 0 : t > 1 ? 1 : t;
                    var j = 1; while (j < stops.length - 1 && stops[j].t < t) j++;
                    var a = stops[j - 1], b = stops[j], f = (t - a.t) / (b.t - a.t || 1);
                    f = f < 0 ? 0 : f > 1 ? 1 : f; f = f * f * (3 - 2 * f);
                    var gx = (F[x < w - 1 ? i + 1 : i] - F[x > 0 ? i - 1 : i]) * slope, gy = (F[y < h - 1 ? i + w : i] - F[y > 0 ? i - w : i]) * slope;
                    var nd = (-gx * lx - gy * ly + lz) / Math.sqrt(gx * gx + gy * gy + 1);
                    var spec = Math.pow(nd > 0 ? nd : 0, 24) * gloss * 255, silk = 1 + 0.035 * Math.sin(t * 150 + Q[i] * 24);
                    var vein = veins * Math.max(0, 1 - Math.abs(Q[i] - 0.42) * 14) * 0.6, lit = (0.82 + 0.28 * nd) * silk * (1 - vein);
                    pixels[i * 4] = (a.c[0] + (b.c[0] - a.c[0]) * f) * lit + spec;
                    pixels[i * 4 + 1] = (a.c[1] + (b.c[1] - a.c[1]) * f) * lit + spec;
                    pixels[i * 4 + 2] = (a.c[2] + (b.c[2] - a.c[2]) * f) * lit + spec;
                    pixels[i * 4 + 3] = 255;
                }
            }
        }
        function step(rows) {
            if (row >= gh) return true;
            var end = Math.min(gh, row + Math.max(1, rows));
            while (row < end) field(row++);
            if (row < gh) return false;
            upsample(); colorize(); return true;
        }
        return { width: w, height: h, pixels: pixels, step: step };
    }
    function fanSlot(index, count) { return count <= 1 ? 0 : (index / (count - 1)) * 2 - 1; }
    function recipeOf(art) { return typeof art === 'string' ? (ART_PRESETS[art] || ART_PRESETS.celeste) : art; }

    // Un solo pintor compartido: unos ms por cuadro, así varias carpetas no traban la página
    var artCache = {}, queue = [], pumping = false;
    function pump() {
        if (pumping) return; pumping = true;
        function tick() {
            var until = performance.now() + 7;
            while (queue.length && performance.now() < until) {
                var head = queue[0];
                if (head.job.step(4)) {
                    queue.shift();
                    var c = document.createElement('canvas'); c.width = head.job.width; c.height = head.job.height;
                    var cx = c.getContext('2d'); if (cx) cx.putImageData(new ImageData(head.job.pixels, c.width, c.height), 0, 0);
                    head.done(c);
                }
            }
            if (queue.length) requestAnimationFrame(tick); else pumping = false;
        }
        requestAnimationFrame(tick);
    }
    function paint(recipe, seed, w, h, priority) {
        var key = JSON.stringify([recipe, seed, w, h]);
        if (!artCache[key]) artCache[key] = new Promise(function (done) {
            var at = queue.length; while (at > 1 && queue[at - 1].priority > priority) at--;
            queue.splice(at, 0, { job: createArtJob(w, h, recipe, seed), priority: priority, done: done }); pump();
        });
        return artCache[key];
    }
    function artCanvas(art, seed, w, h, density, priority, cls) {
        var c = document.createElement('canvas'); c.className = cls; c.setAttribute('aria-hidden', 'true');
        c.style.width = w + 'px'; c.style.height = h + 'px'; c.style.maxWidth = 'none';
        paint(recipeOf(art), seed, Math.round(w * density), Math.round(h * density), priority).then(function (src) {
            c.width = src.width; c.height = src.height; var x = c.getContext('2d'); if (x) x.drawImage(src, 0, 0); c.setAttribute('data-ready', '');
        });
        return c;
    }

    // ---------- geometría (escenario 340 × 272 escalado al ancho) ----------
    var W = 340, H = 272, HEADROOM = 54, FRONT_TOP = 74, FRONT_H = H - FRONT_TOP, SHEET_W = 272, SHEET_H = 184, MAX_VISIBLE = 4;
    var BACK_PATH = 'M0 56A22 22 0 0 1 22 34L146 34C170 34 172 0 198 0L318 0A22 22 0 0 1 340 22L340 250A22 22 0 0 1 318 272L22 272A22 22 0 0 1 0 250Z';
    var FRONT_PATH = 'M0 22A22 22 0 0 1 22 0L118 0C144 0 146 32 172 32L318 32A22 22 0 0 1 340 54L340 ' + (FRONT_H - 22) + 'A22 22 0 0 1 318 ' + FRONT_H + 'L22 ' + FRONT_H + 'A22 22 0 0 1 0 ' + (FRONT_H - 22) + 'Z';
    var uidN = 0;

    function el(tag, cls, attrs) { var e = document.createElement(tag); if (cls) e.className = cls; if (attrs) for (var k in attrs) e.setAttribute(k, attrs[k]); return e; }
    function svg(tag, attrs) { var e = document.createElementNS('http://www.w3.org/2000/svg', tag); for (var k in attrs) e.setAttribute(k, attrs[k]); return e; }

    function inyectarCSS() { if (document.getElementById('gf-css')) return; var s = document.createElement('style'); s.id = 'gf-css'; s.textContent = CSS; document.head.appendChild(s); }

    window.RefCarpeta = function (contenedor, o) {
        inyectarCSS();
        o = o || {};
        var label = o.label || 'Documentos', tone = o.tone || 'light', art = o.art || 'celeste', seed = o.seed == null ? 3 : o.seed;
        var files = (o.files || []).slice(), width = o.width || 340, k = width / W, place = o.labelPlacement || 'bottom-left';
        var density = Math.min(1.5, Math.max(1, window.devicePixelRatio || 1)) * k, uid = 'gf' + (++uidN), open = false;

        var root = el('div', 'gf-root', { 'data-tone': tone, 'data-place': place });
        root.style.width = width + 'px'; root.style.height = ((H + HEADROOM) * k) + 'px';
        var stage = el('div', 'gf-stage'); stage.style.transform = 'translateY(' + (HEADROOM * k) + 'px) scale(' + k + ')';
        var tilt = el('div', 'gf-tilt');
        tilt.appendChild(el('div', 'gf-shadow', { 'aria-hidden': 'true' }));
        var back = el('div', 'gf-back', { 'aria-hidden': 'true' }); back.style.clipPath = "path('" + BACK_PATH + "')";
        if (art !== 'none') back.appendChild(artCanvas(art, seed, W + 24, H + 24, density, 0, 'gf-art'));
        back.appendChild(el('div', 'gf-back-sheen'));
        tilt.appendChild(back);
        var brim = svg('svg', { 'class': 'gf-rim gf-back-rim', viewBox: '0 0 ' + W + ' ' + H, 'aria-hidden': 'true' }); brim.appendChild(svg('path', { d: BACK_PATH })); tilt.appendChild(brim);

        var front = el('div', 'gf-front'); front.style.clipPath = "path('" + FRONT_PATH + "')";
        front.appendChild(el('div', 'gf-tint', { 'aria-hidden': 'true' })); front.appendChild(el('div', 'gf-spec', { 'aria-hidden': 'true' }));
        var frim = svg('svg', { 'class': 'gf-rim gf-front-rim', viewBox: '0 0 ' + W + ' ' + FRONT_H, 'aria-hidden': 'true' });
        var defs = svg('defs', {}), lg = svg('linearGradient', { id: 'gf-rim-' + uid, x1: '0', y1: '0', x2: '0', y2: '1' });
        [['0', '0.95'], ['0.35', '0.35'], ['1', '0.12']].forEach(function (s) { lg.appendChild(svg('stop', { offset: s[0], 'stop-color': '#fff', 'stop-opacity': s[1] })); });
        defs.appendChild(lg); frim.appendChild(defs); frim.appendChild(svg('path', { d: FRONT_PATH, stroke: 'url(#gf-rim-' + uid + ')' })); front.appendChild(frim);
        var hit = el('button', 'gf-hit', { type: 'button' }); front.appendChild(hit);
        var lab = el('div', 'gf-label'), tit = el('span', 'gf-title'), meta = el('span', 'gf-meta');
        tit.textContent = label; lab.appendChild(tit); lab.appendChild(meta); front.appendChild(lab);
        tilt.appendChild(front);

        var filesBox = el('div', 'gf-files', { role: 'list', 'aria-label': label });
        tilt.appendChild(filesBox);

        if (o.onAdd) {
            var key = el('button', 'gf-key gf-key--add', { type: 'button', 'aria-label': o.addLabel || ('Nuevo en ' + label), title: o.addLabel || 'Nuevo' });
            var plus = svg('svg', { 'class': 'gf-glyph gf-glyph--plus', viewBox: '0 0 24 24', 'aria-hidden': 'true' }); plus.appendChild(svg('path', { d: 'M12 4.5v15M4.5 12h15' }));
            key.appendChild(plus); key.addEventListener('click', function (e) { e.stopPropagation(); o.onAdd(); });
            tilt.appendChild(key);
        }
        stage.appendChild(tilt); root.appendChild(stage); contenedor.appendChild(root);

        function pintarArchivos() {
            filesBox.innerHTML = '';
            var start = Math.max(0, files.length - MAX_VISIBLE), vis = files.slice(start), n = files.length;
            meta.textContent = o.meta || (n ? n + (n === 1 ? ' documento' : ' documentos') : 'Vacía');
            hit.setAttribute('aria-label', (open ? 'Cerrar ' : 'Abrir ') + label + ', ' + n + ' documentos');
            vis.forEach(function (f, v) {
                var slot = fanSlot(v, vis.length), jit = rng(hashString(f.name) + v), pic = !!f.art;
                var wrap = el('div', 'gf-sheet-slot', { role: 'listitem' });
                var s = el(f.href ? 'a' : 'button', 'gf-sheet' + (pic ? ' gf-sheet--art' : ''));
                if (f.href) s.setAttribute('href', f.href); else s.setAttribute('type', 'button');
                s.style.setProperty('--gf-slot', slot); s.style.setProperty('--gf-depth', vis.length - 1 - v);
                s.style.setProperty('--gf-jx', ((jit() - 0.5) * 10).toFixed(2) + 'px'); s.style.setProperty('--gf-jr', ((jit() - 0.5) * 3.2).toFixed(2) + 'deg'); s.style.zIndex = v + 1;
                if (pic) s.appendChild(artCanvas(f.art, hashString(f.name) % 997, SHEET_W, SHEET_H, Math.min(density, 1.25), 1, 'gf-sheet-art'));
                else { var ln = el('span', 'gf-lines', { 'aria-hidden': 'true' }); ['86%', '92%', '64%', '88%', '42%'].forEach(function (w2) { var i = document.createElement('i'); i.style.width = w2; ln.appendChild(i); }); s.appendChild(ln); }
                var hd = el('span', 'gf-sheet-head'), nm = el('span', 'gf-sheet-name'); nm.textContent = f.name; hd.appendChild(nm);
                if (f.meta) { var mt = el('span', 'gf-sheet-meta'); mt.textContent = f.meta; hd.appendChild(mt); }
                s.appendChild(hd);
                if (f.detalle) { var dt = el('span', 'gf-sheet-det'); dt.textContent = f.detalle; s.appendChild(dt); }
                wrap.appendChild(s); filesBox.appendChild(wrap);
            });
            if (!open) filesBox.setAttribute('inert', ''); else filesBox.removeAttribute('inert');
        }
        function ponerOpen(v) {
            open = v; if (v) root.setAttribute('data-open', ''); else root.removeAttribute('data-open');
            hit.setAttribute('aria-expanded', String(v)); pintarArchivos();
        }
        hit.addEventListener('click', function () { ponerOpen(!open); });
        document.addEventListener('keydown', function (e) { if (open && e.key === 'Escape') { ponerOpen(false); hit.focus(); } });
        document.addEventListener('pointerdown', function (e) { if (open && !root.contains(e.target)) ponerOpen(false); });

        // luz y paralaje siguen al puntero
        var raf = 0, px = 0, py = 0;
        function write() { raf = 0; root.style.setProperty('--gf-px', px.toFixed(3)); root.style.setProperty('--gf-py', py.toFixed(3)); }
        root.addEventListener('pointermove', function (e) { if (e.pointerType === 'touch') return; var r = root.getBoundingClientRect(); px = ((e.clientX - r.left) / r.width) * 2 - 1; py = ((e.clientY - r.top) / r.height) * 2 - 1; if (!raf) raf = requestAnimationFrame(write); });
        root.addEventListener('pointerleave', function () { px = 0; py = 0; if (!raf) raf = requestAnimationFrame(write); });

        // entrada: se arma sola la primera vez que se ve
        if ('IntersectionObserver' in window) {
            var io = new IntersectionObserver(function (en) {
                if (!en.some(function (x) { return x.isIntersecting; })) return;
                io.disconnect(); setTimeout(function () { root.setAttribute('data-entered', ''); }, o.appearDelay || 0);
            }, { threshold: 0.25 });
            io.observe(root);
        } else root.setAttribute('data-entered', '');
        pintarArchivos();
        return { setFiles: function (l) { files = (l || []).slice(); pintarArchivos(); }, open: ponerOpen, root: root };
    };
})();
