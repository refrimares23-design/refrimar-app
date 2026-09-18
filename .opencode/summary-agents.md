## Objective
- Juego "Op-Art Fan" (repo canónico `Pequegg/MAN`, proyecto en `C:\Users\1903c\OneDrive\Documentos\Default Project\Op-Art-Fan`) ONLINE: GitHub Pages + PWA instalable/offline + capa online de Arena vía Firebase. El usuario dejó todo a mi cargo ("no me preguntes nada", "cuando vuelva quiero todo listo").

## Important Details
- **URL en vivo**: `https://pequegg.github.io/MAN/` — GitHub Pages ACTIVO (deploy automático desde rama `main` carpeta raíz, `build_type: legacy`). Cada `git push` a main se publica solo en 1-2 min. Verificado: index con rediseño+panel mundial, manifest (200), sw.js (200), icon-512 (200).
- **PWA** (commit `bc2e5ff`): `manifest.webmanifest`, `sw.js` (cache-first estáticos, red-first navegación, assets bajo demanda; VERSION `opartfan-v1`), íconos generados con node-canvas (`assets/images/icon-{512,192,maskable-512}.png`, `apple-touch-icon.png`), metas instalables (mobile-web-app-capable, apple-*), registro SW al final del body. README con URL, PWA y Firebase.
- **Arena online** (commit `1603da5`): panel **"🌍 Ranking mundial de hoy"** en pantalla Arena (`#arenaWorldPanel`), `renderWorldRank()` + `renderWorldRows(j)` en `js/arena/arena.js` (lee `FIREBASE_URL/arena/daily/<today>.json`, top25 + corona al líder + marca TÚ; fallback local si URL vacía o sin red). Ya llamada desde `renderArena()`.
- firebase-tools 15.30.0 instalado global (npm): `C:\Users\1903c\AppData\Roaming\npm\firebase.cmd`.
- `tools/firebase-online.ps1` = automatiza TODO tras login: instala CLI si falta, `firebase login` (interactivo, abre navegador — UNICA acción que requiere al usuario), crea proyecto gratuito `op-art-fan-<ts>-<n>`, `database:instances:create --region europe-west1`, enlaza (`firebase use`), `firebase deploy --only database` (usa `firebase.json` + `firebase-rules.json` ya commiteados), y patchea `js/config/settings.js` con `var FIREBASE_URL = "https://<id>-default-rtdb.europe-west1.firebasedatabase.app/";`. `.firebaserc` gitignoreado.
- Reglas RTDB prototipo (`firebase-rules.json`): lectura/escritura abiertas SOLO bajo `/arena/*`, resto denegado.
- Git identity: usar `-c user.name="Refrimar Dev" -c user.email="dev@refrimar.com"`.
- Último push: `bc2e5ff..1603da5` "Ranking mundial de Arena + automatización Firebase...". Antes: `b89cb7c` (rediseño), `7c0a9c7` (reestructuración).
- Windows/PowerShell 5.1; `npm.cmd` (npm.ps1 bloqueado por ExecutionPolicy); node-canvas/sharp en temp; firebase CLI en `$env:APPDATA\npm\firebase.cmd` (no está en PATH de sesión nueva automáticamente hasta reabrir terminal).

## Work State
### Completed
- GitHub Pages verificado y funcionando; PWA completa (offline + instalable + íconos); world ranking + script automatizado + firebase.json/rules commiteados; suite tests verde tras cada cambio (smoke 15/15 winErrors 0, budget 172KB, mobile OK, bg 18/18, legacy NO ERRORS); bundle descargable regenerado (Downloads\Op-Art-Fan.html 175209B); push `1603da5` verificado en vivo (panel "Ranking mundial" presente en el HTML servido).

### Active
- (none — solo espera la acción del usuario para activar Firebase)

### Blocked
- **Crear el proyecto Firebase**: imposible sin la cuenta Google del usuario (OAuth interactivo). Todo lo demás automatizado en `tools\firebase-online.ps1`.

## Next Move
- Cuando el usuario vuelva: que ejecute `powershell -ExecutionPolicy Bypass -File tools\firebase-online.ps1` (login Google 1 vez), luego `git add js/config/settings.js && git commit -m "firebase online" && git push`. Tras eso el ranking mundial y los grupos/temporadas se sincronizan entre jugadores. Si pidiera más pulido: re-theme de minijuegos canvas de Arena, medallas de temporada, o activar GitHub Actions. Sin instrucciones nuevas: esperar.

## Relevant Files
- `C:\Users\1903c\OneDrive\Documentos\Default Project\Op-Art-Fan\` — repo, commit `1603da5`.
- `js/arena/arena.js` (renderWorldRank/renderWorldRows, TIERS, mySeasonPts, seasonTier, dayStreak), `js/ui/menu.js` (renderMenuStatus), `js/ui/results.js` (celebrate), `js/config/settings.js` (FIREBASE_URL a patchear).
- `tools/firebase-online.ps1`, `firebase.json`, `firebase-rules.json`, `manifest.webmanifest`, `sw.js`, `assets/images/icon-*.png`.
- `tools/tests/{smoke,mobile,budget,bg}.cjs` — suite (mantener verde).
- `C:\Users\1903c\Downloads\Op-Art-Fan.html` — bundle descargable actualizado.