package main

// Balanza por puerto serial (pesables). POR PROBAR con la balanza real.
// La mayoría de balanzas de mostrador (CAS, Toledo/Prix, Systel, Dibal) envían el peso
// solas o lo responden al recibir "W" / ENQ. Se lee una línea con un número y "kg".
//   GET /balanza/detectar  → busca la balanza en los puertos COM (no toca la impresora fiscal)
//   GET /balanza/peso      → peso actual en kg { ok, peso, estable }

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

var rePeso = regexp.MustCompile(`([-+]?\s*\d{1,3}[.,]\d{1,3})\s*(kg|KG|Kg)?`)

func leerPeso(puerto string, baud int) (float64, bool, bool) {
	p, err := abrirPuerto(puerto, baud, 'N')
	if err != nil {
		return 0, false, false
	}
	defer p.Close()
	p.Purgar()
	buf := []byte{}
	escuchar := func(d time.Duration) {
		fin := time.Now().Add(d)
		for time.Now().Before(fin) {
			b, _ := p.Leer(128, 120*time.Millisecond)
			buf = append(buf, b...)
			if len(buf) > 256 {
				return
			}
		}
	}
	escuchar(500 * time.Millisecond) // balanzas que transmiten solas
	for _, cmd := range [][]byte{[]byte("W"), {0x05}, []byte("P\r\n")} {
		if len(buf) > 0 {
			break
		}
		p.Write(cmd)
		escuchar(600 * time.Millisecond)
	}
	txt := string(buf)
	if strings.TrimSpace(txt) == "" {
		return 0, false, false
	}
	// Se prefiere una línea que diga kg
	m := rePeso.FindAllStringSubmatch(txt, -1)
	if len(m) == 0 {
		return 0, false, false
	}
	elegido := m[len(m)-1]
	for _, x := range m {
		if x[2] != "" {
			elegido = x
		}
	}
	n, err := strconv.ParseFloat(strings.ReplaceAll(strings.ReplaceAll(elegido[1], " ", ""), ",", "."), 64)
	if err != nil {
		return 0, false, false
	}
	estable := !strings.Contains(strings.ToUpper(txt), "US") // "US" = inestable en muchas balanzas
	return n, estable, true
}

func atenderBalanza(ruta string) (int, map[string]interface{}) {
	c := cargarCfg()
	baud := int(cf(c, "balanza_baudios"))
	if baud == 0 {
		baud = 9600
	}
	if strings.HasPrefix(ruta, "/balanza/detectar") {
		fiscal := cs(c, "puerto_detectado")
		for _, pt := range listarPuertos() {
			if pt == fiscal || pt == cs(c, "puerto") {
				continue
			}
			if peso, est, ok := leerPeso(pt, baud); ok {
				b := cargarCfg()
				b["balanza_puerto"] = pt
				guardarCfg(b)
				return 200, map[string]interface{}{"ok": true, "puerto": pt, "peso": peso, "estable": est, "por_probar": true}
			}
		}
		return 200, map[string]interface{}{"ok": false, "error": "No se encontró una balanza que envíe peso por los puertos COM"}
	}
	pt := cs(c, "balanza_puerto")
	if pt == "" {
		return 200, map[string]interface{}{"ok": false, "error": "No hay balanza configurada: búscala en Dispositivos"}
	}
	peso, est, ok := leerPeso(pt, baud)
	if !ok {
		return 200, map[string]interface{}{"ok": false, "error": "La balanza no respondió en " + pt}
	}
	return 200, map[string]interface{}{"ok": true, "peso": peso, "estable": est, "puerto": pt}
}
