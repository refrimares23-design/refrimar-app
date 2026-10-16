#!/bin/sh
# Compila REFRIMAR POS para Windows y arma el instalador (necesita Go y NSIS).
set -e
cd "$(dirname "$0")"
GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-H windowsgui -s -w" -o refrimar-pos.exe .
GOOS=windows GOARCH=386   go build -trimpath -ldflags "-H windowsgui -s -w" -o refrimar-pos-32.exe .
makensis refrimar-pos.nsi
mv REFRIMAR-POS-Setup.exe ../../REFRIMAR-POS-Setup.exe
rm -f refrimar-pos.exe refrimar-pos-32.exe
echo "Listo: REFRIMAR-POS-Setup.exe"
# Actualiza pos-version.json (la caja se actualiza sola con este archivo)
VER=$(grep -o 'const VERSION = "[0-9.]*"' main.go | grep -o '[0-9.]*')
SHA=$(sha256sum ../../REFRIMAR-POS-Setup.exe | cut -d' ' -f1)
cat > ../../pos-version.json <<JSON
{
  "version": "$VER",
  "url": "https://refrimar-app.refrimar-es23.workers.dev/REFRIMAR-POS-Setup.exe",
  "sha256": "$SHA",
  "notas": "Versión $VER del programa de la caja."
}
JSON
echo "pos-version.json → $VER"
