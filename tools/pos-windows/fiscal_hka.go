package main

// Protocolo HKA / The Factory (Bixolon SRP-812, HKA80…) por puerto serial.
// Trama: STX + datos + ETX + LRC (XOR de datos y ETX); la impresora responde ACK (06h) o NAK (15h).

import (
	"errors"
	"fmt"
	"log"
	"math"
	"regexp"
	"strings"
	"time"
)

type hkaSerial struct {
	p      Puerto
	puerto string
}

func tramaHKA(cmd string) []byte {
	d := latin1(cmd)
	lrc := byte(0)
	for _, b := range append(append([]byte{}, d...), 0x03) {
		lrc ^= b
	}
	out := append([]byte{0x02}, d...)
	return append(out, 0x03, lrc)
}

func (t *hkaSerial) enviar(cmd string) (bool, string) {
	for i := 0; i < 3; i++ {
		t.p.Purgar()
		t.p.Write(tramaHKA(cmd))
		r, _ := t.p.Leer(1, 6*time.Second)
		log.Printf("HKA > %q resp=%v", cmd, r)
		if len(r) == 1 && r[0] == 0x06 {
			return true, ""
		}
		if len(r) == 1 && r[0] == 0x15 {
			return false, "La impresora rechazó el comando " + cmd
		}
		time.Sleep(400 * time.Millisecond)
	}
	return false, "La impresora no responde en " + t.puerto
}

func (t *hkaSerial) s1() string {
	t.p.Purgar()
	t.p.Write(tramaHKA("S1"))
	limite := time.Now().Add(4 * time.Second)
	buf := []byte{}
	for time.Now().Before(limite) {
		b, _ := t.p.Leer(256, 200*time.Millisecond)
		buf = append(buf, b...)
		i, j := indexByte(buf, 0x02), indexByte(buf, 0x03)
		if i >= 0 && j > i {
			t.p.Write([]byte{0x06})
			return string(buf[i+1 : j])
		}
	}
	return ""
}

var reRifSerial = regexp.MustCompile(`([JVGEP]\d{9})([A-Z0-9]{10})`)

func leerS1(t *hkaSerial, c map[string]interface{}) map[string]interface{} {
	txt := t.s1()
	r := map[string]interface{}{}
	if txt == "" {
		return r
	}
	r["s1"] = txt
	rango := func(k string) (int, int) {
		if l, ok := c[k].([]interface{}); ok && len(l) == 2 {
			return int(num(l[0])), int(num(l[1]))
		}
		return 0, 0
	}
	if a, b := rango("hka_s1_factura"); b > a && len(txt) >= b && esDigitos(txt[a:b]) {
		r["ultima_factura"] = txt[a:b]
	}
	if a, b := rango("hka_s1_nc"); b > a && len(txt) >= b && esDigitos(txt[a:b]) {
		r["ultima_nc"] = txt[a:b]
	}
	if m := reRifSerial.FindStringSubmatch(txt); m != nil {
		r["rif"], r["serial"] = m[1], m[2]
	}
	return r
}

func comandosHKA(d, c map[string]interface{}, nc bool) ([]string, error) {
	cli := mapa(d["cliente"])
	nom := str(cli["nombre"])
	if nom == "" {
		nom = "CONSUMIDOR FINAL"
	}
	cmds := []string{}
	rif := strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(texto(str(cli["rif"]), 16)))
	if rif != "" {
		cmds = append(cmds, "iR*"+rif)
	}
	cmds = append(cmds, "iS*"+strings.ToUpper(texto(nom, 40)))
	if nc {
		fac := soloDigitos.ReplaceAllString(str(d["factura_afectada"]), "")
		if fac == "" {
			return nil, errors.New("la nota de crédito fiscal necesita el número fiscal de la factura")
		}
		if len(fac) < 11 {
			fac = strings.Repeat("0", 11-len(fac)) + fac
		}
		cmds = append(cmds, "iF*"+fac, "iD*"+fechaLocal(str(d["factura_fecha"])).Format("02/01/2006"))
		if s := str(d["factura_serial"]); s != "" {
			cmds = append(cmds, "iI*"+texto(s, 12))
		}
	}
	if ref := str(d["numero_interno"]); ref != "" {
		cmds = append(cmds, "@"+texto("Ref: "+ref+"  Cajero: "+str(d["cajero"]), 40))
	}
	// Monto en divisas y tasa BCV (Providencia 0071 art. 14)
	for i, x := range listaTexto(d["comentarios"]) {
		if i >= 2 {
			break
		}
		if strings.TrimSpace(x) != "" {
			cmds = append(cmds, "@"+texto(x, 40))
		}
	}
	tabla := cm(c, "hka_tasas")
	if nc {
		tabla = cm(c, "hka_tasas_nc")
	}
	items := itemsValidos(d)
	if len(items) == 0 {
		return nil, errors.New("el documento no tiene productos")
	}
	total := 0.0
	for _, it := range items {
		k := claveTasa(it["iva"])
		pre, ok := tabla[k]
		if !ok {
			return nil, fmt.Errorf("la tasa de IVA %s%% no está configurada", k)
		}
		precio, cant := num(it["precio"]), num(it["cantidad"])
		p, err := montoFijo(precio, 8, 2)
		if err != nil {
			return nil, err
		}
		q, err := montoFijo(cant, 5, 3)
		if err != nil {
			return nil, err
		}
		cmds = append(cmds, pre+p+q+texto(str(it["descripcion"]), 40))
		total += math.Round(precio*cant*100) / 100 * (1 + num(it["iva"])/100)
	}
	pagos := []map[string]interface{}{}
	for _, p := range lista(d["pagos"]) {
		if num(p["monto"]) > 0 {
			pagos = append(pagos, p)
		}
	}
	if len(pagos) == 0 {
		pagos = []map[string]interface{}{{"codigo": "01", "monto": total}}
	}
	acum := 0.0
	for i, p := range pagos {
		cod := str(p["codigo"])
		if cod == "" {
			cod = "01"
		}
		if len(cod) < 2 {
			cod = "0" + cod
		}
		cod = cod[len(cod)-2:]
		m := num(p["monto"])
		if i == len(pagos)-1 || acum+m >= total-0.01 {
			cmds = append(cmds, "1"+cod)
			break
		}
		mm, err := montoFijo(m, 10, 2)
		if err != nil {
			return nil, err
		}
		cmds = append(cmds, "2"+cod+mm)
		acum += m
	}
	return cmds, nil
}

func abrirHKA(c map[string]interface{}) (*hkaSerial, error) {
	par := byte('E')
	if s := cs(c, "hka_paridad"); s != "" {
		par = s[0]
	}
	cand := []string{}
	if p := strings.TrimSpace(cs(c, "puerto")); p != "" && strings.ToUpper(p) != "AUTO" {
		cand = []string{p}
	} else {
		if p := cs(c, "puerto_detectado"); p != "" {
			cand = append(cand, p)
		}
		cand = append(cand, listarPuertos()...)
	}
	for _, x := range cand {
		pt, err := abrirPuerto(x, int(cf(c, "baudios")), par)
		if err != nil {
			continue
		}
		t := &hkaSerial{p: pt, puerto: x}
		if len(cand) == 1 || t.s1() != "" {
			if x != cs(c, "puerto_detectado") {
				b := cargarCfg()
				b["puerto_detectado"] = x
				guardarCfg(b)
			}
			return t, nil
		}
		pt.Close()
	}
	return nil, errors.New("no se encontró la impresora fiscal HKA/Bixolon. Revisa que esté encendida y conectada")
}

func atenderHKA(ruta string, d, c map[string]interface{}) (int, map[string]interface{}) {
	if cs(c, "modelo") == "Impresora fiscal PNP" {
		c["modelo"] = "Impresora fiscal HKA / Bixolon"
	}
	if strings.HasPrefix(ruta, "/fiscal/comandos") {
		cmds, err := comandosHKA(d, c, d["nota_credito"] == true)
		if err != nil {
			return 400, map[string]interface{}{"ok": false, "error": err.Error()}
		}
		return 200, map[string]interface{}{"ok": true, "comandos": cmds}
	}
	var cmds []string
	nc := strings.HasPrefix(ruta, "/fiscal/nota_credito")
	if strings.HasPrefix(ruta, "/fiscal/factura") || nc {
		var err error
		if cmds, err = comandosHKA(d, c, nc); err != nil {
			return 400, map[string]interface{}{"ok": false, "error": err.Error()}
		}
	}
	lockFiscal.Lock()
	defer lockFiscal.Unlock()
	t, err := abrirHKA(c)
	if err != nil {
		if strings.HasPrefix(ruta, "/fiscal/estado") {
			return 200, map[string]interface{}{"ok": true, "conectada": false, "modelo": cs(c, "modelo"), "puerto": cs(c, "puerto"), "marca": "hka", "error": err.Error()}
		}
		return 500, map[string]interface{}{"ok": false, "error": err.Error()}
	}
	defer t.p.Close()
	switch {
	case strings.HasPrefix(ruta, "/fiscal/estado"):
		r := leerS1(t, c)
		return 200, map[string]interface{}{"ok": true, "conectada": len(r) > 0, "modelo": cs(c, "modelo"), "puerto": t.puerto, "marca": "hka",
			"serial": r["serial"], "rif": r["rif"], "ultima_factura": r["ultima_factura"], "ultima_nc": r["ultima_nc"]}
	case cmds != nil:
		for _, cmd := range cmds {
			if ok, e := t.enviar(cmd); !ok {
				t.enviar("7")
				return 500, map[string]interface{}{"ok": false, "error": e, "comando": cmd}
			}
		}
		time.Sleep(300 * time.Millisecond)
		r := leerS1(t, c)
		n := r["ultima_factura"]
		if nc {
			n = r["ultima_nc"]
		}
		return 200, map[string]interface{}{"ok": true, "numero_fiscal": n, "serial": r["serial"], "comandos": len(cmds)}
	case strings.HasPrefix(ruta, "/fiscal/reporte"):
		cmd := cs(c, "hka_reporte_x")
		if strings.ToUpper(str(d["tipo"])) == "Z" {
			cmd = cs(c, "hka_reporte_z")
		}
		ok, e := t.enviar(cmd)
		return map[bool]int{true: 200, false: 500}[ok], map[string]interface{}{"ok": ok, "error": nilSiVacio(e)}
	case strings.HasPrefix(ruta, "/fiscal/gaveta"):
		ok, e := t.enviar(cs(c, "hka_gaveta"))
		return map[bool]int{true: 200, false: 500}[ok], map[string]interface{}{"ok": ok, "error": nilSiVacio(e)}
	}
	return 404, map[string]interface{}{"ok": false, "error": "Not Found"}
}
