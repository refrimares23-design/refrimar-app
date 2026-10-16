package main

// Impresoras fiscales venezolanas:
//   PNP (Desarrollos PNP: PF-220, PF-300, PF-950, DT-230…) — protocolo PNP v5.4
//   HKA / The Factory (Bixolon SRP-812, HKA80, Aclas…)      — protocolo TFHKA
// Configuración en %LOCALAPPDATA%\RefrimarPOS\impresora_fiscal.json

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

var lockFiscal sync.Mutex

var cfgBase = map[string]interface{}{
	"marca":             "pnp",
	"modelo":            "Impresora fiscal PNP",
	"puerto":            "AUTO",
	"puerto_detectado":  "",
	"baudios":           9600.0,
	"tasas":             map[string]interface{}{"0": "0000", "16": "1600", "8": "0800", "31": "3100"},
	"largo_descripcion": 20.0,
	"largo_razon":       38.0,
	"largo_rif":         12.0,
	"cmd_reporte_x":     "9|X|T",
	"cmd_reporte_z":     "9|Z|T",
	"cmd_gaveta":        "{",
	"cmd_estado":        "8|N",
	"cmd_serial":        "\u0080",
	"imprimir_pagos":    true,
	"igtf":              false,
	"timeout_s":         4.0,
	"simular":           false,
	// HKA / Bixolon
	"hka_paridad":    "E",
	"hka_tasas":      map[string]interface{}{"0": " ", "16": "!", "8": "\"", "31": "#"},
	"hka_tasas_nc":   map[string]interface{}{"0": "d0", "16": "d1", "8": "d2", "31": "d3"},
	"hka_reporte_x":  "I0X",
	"hka_reporte_z":  "I0Z",
	"hka_gaveta":     "0",
	"hka_s1_factura": []interface{}{21.0, 29.0},
	"hka_s1_nc":      []interface{}{55.0, 63.0},
}

func rutaCfg() string { return filepath.Join(CARPETA, "impresora_fiscal.json") }

func cargarCfg() map[string]interface{} {
	c := map[string]interface{}{}
	for k, v := range cfgBase {
		c[k] = v
	}
	b, err := os.ReadFile(rutaCfg())
	if err != nil {
		guardarCfg(c)
		return c
	}
	extra := map[string]interface{}{}
	if json.Unmarshal(b, &extra) == nil {
		for k, v := range extra {
			c[k] = v
		}
	}
	return c
}

func guardarCfg(c map[string]interface{}) {
	b, _ := json.MarshalIndent(c, "", "  ")
	os.WriteFile(rutaCfg(), b, 0644)
}

func cs(c map[string]interface{}, k string) string {
	if v, ok := c[k].(string); ok {
		return v
	}
	return fmt.Sprint(c[k])
}
func cf(c map[string]interface{}, k string) float64 {
	switch v := c[k].(type) {
	case float64:
		return v
	case string:
		f, _ := strconv.ParseFloat(v, 64)
		return f
	}
	return 0
}
func cb(c map[string]interface{}, k string) bool { v, _ := c[k].(bool); return v }
func cm(c map[string]interface{}, k string) map[string]string {
	out := map[string]string{}
	if m, ok := c[k].(map[string]interface{}); ok {
		for a, b := range m {
			out[a] = fmt.Sprint(b)
		}
	}
	return out
}

// ---------------------------------------------------------------- formato
var reNoAscii = regexp.MustCompile(`[^\x20-\x7E]`)
var acentos = strings.NewReplacer("á", "a", "é", "e", "í", "i", "ó", "o", "ú", "u", "Á", "A", "É", "E", "Í", "I", "Ó", "O", "Ú", "U",
	"ñ", "n", "Ñ", "N", "ü", "u", "Ü", "U", "½", "1/2", "¼", "1/4", "¾", "3/4", "°", "o", "º", "o", "ª", "a", "¿", "", "¡", "")

func texto(s string, largo int) string {
	s = acentos.Replace(s)
	s = reNoAscii.ReplaceAllString(s, "")
	s = strings.TrimSpace(strings.ReplaceAll(s, "|", "/"))
	if largo > 0 && len(s) > largo {
		s = s[:largo]
	}
	return s
}

func sinPunto(v float64, dec int) string {
	return strconv.FormatInt(int64(math.Round(math.Abs(v)*math.Pow10(dec))), 10)
}

func montoFijo(v float64, enteros, dec int) (string, error) {
	t := sinPunto(v, dec)
	if len(t) > enteros+dec {
		return "", fmt.Errorf("monto demasiado grande para la impresora: %v", v)
	}
	return strings.Repeat("0", enteros+dec-len(t)) + t, nil
}

func claveTasa(v interface{}) string {
	f := num(v)
	if math.Abs(f-math.Round(f)) < 1e-9 {
		return strconv.Itoa(int(math.Round(f)))
	}
	return strconv.FormatFloat(f, 'f', -1, 64)
}

func num(v interface{}) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case string:
		f, _ := strconv.ParseFloat(strings.ReplaceAll(x, ",", "."), 64)
		return f
	case int:
		return float64(x)
	}
	return 0
}
func str(v interface{}) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprint(v)
}
func mapa(v interface{}) map[string]interface{} {
	if m, ok := v.(map[string]interface{}); ok {
		return m
	}
	return map[string]interface{}{}
}
func lista(v interface{}) []map[string]interface{} {
	out := []map[string]interface{}{}
	if l, ok := v.([]interface{}); ok {
		for _, x := range l {
			out = append(out, mapa(x))
		}
	}
	return out
}

func fechaLocal(iso string) time.Time {
	if iso == "" {
		return time.Now()
	}
	for _, f := range []string{time.RFC3339Nano, "2006-01-02T15:04:05", "2006-01-02"} {
		if t, err := time.Parse(f, strings.Replace(iso, " ", "T", 1)); err == nil {
			return t.Local()
		}
	}
	return time.Now()
}

var nombreMetodo = map[string]string{"efectivo": "Efectivo Bs", "divisa": "Efectivo $", "pago_movil": "Pago movil", "punto": "Debito",
	"transferencia": "Transferencia", "zelle": "Zelle", "binance": "Binance", "otro": "Otro", "credito": "Credito"}
var metDivisa = map[string]bool{"divisa": true, "zelle": true, "binance": true, "otro": true}
var soloDigitos = regexp.MustCompile(`\D`)

func itemsValidos(d map[string]interface{}) []map[string]interface{} {
	out := []map[string]interface{}{}
	for _, it := range lista(d["items"]) {
		if num(it["cantidad"]) > 0 {
			out = append(out, it)
		}
	}
	return out
}

// ---------------------------------------------------------------- PNP: comandos
func comandosPNP(d map[string]interface{}, c map[string]interface{}, nc bool) ([]string, error) {
	cli := mapa(d["cliente"])
	nom := str(cli["nombre"])
	if nom == "" {
		nom = "CONSUMIDOR FINAL"
	}
	razon := strings.ToUpper(texto(nom, int(cf(c, "largo_razon"))))
	rif := strings.ToUpper(strings.ReplaceAll(texto(str(cli["rif"]), int(cf(c, "largo_rif"))), " ", ""))
	cmds := []string{}
	if nc {
		fac := soloDigitos.ReplaceAllString(str(d["factura_afectada"]), "")
		if fac == "" {
			return nil, errors.New("la nota de crédito fiscal necesita el número fiscal de la factura")
		}
		serial := texto(str(d["factura_serial"]), 12)
		if serial == "" {
			serial = texto(cs(c, "serial"), 12)
		}
		f := fechaLocal(str(d["factura_fecha"]))
		if len(fac) < 8 {
			fac = strings.Repeat("0", 8-len(fac)) + fac
		}
		cmds = append(cmds, strings.Join([]string{"@", razon, rif, fac, serial, f.Format("02012006"), f.Format("150405"), "D"}, "|"))
	} else {
		cmds = append(cmds, strings.Join([]string{"@", razon, rif}, "|"))
	}
	items := itemsValidos(d)
	if len(items) == 0 {
		return nil, errors.New("el documento no tiene productos")
	}
	tasas := cm(c, "tasas")
	for _, it := range items {
		k := claveTasa(it["iva"])
		t, ok := tasas[k]
		if !ok {
			return nil, fmt.Errorf("la tasa de IVA %s%% no está programada (impresora_fiscal.json)", k)
		}
		desc := texto(str(it["descripcion"]), int(cf(c, "largo_descripcion")))
		if desc == "" {
			desc = "PRODUCTO"
		}
		cmds = append(cmds, strings.Join([]string{"B", desc, sinPunto(num(it["cantidad"]), 3), sinPunto(num(it["precio"]), 2), t, "M"}, "|"))
	}
	lineas := []string{}
	if ref := str(d["numero_interno"]); ref != "" {
		lineas = append(lineas, texto("Ref "+ref+" Caj "+str(d["cajero"]), 40))
	}
	if cb(c, "imprimir_pagos") && !nc {
		actual := ""
		for _, p := range lista(d["pagos"]) {
			m := num(p["monto"])
			if m <= 0 {
				continue
			}
			n := nombreMetodo[str(p["metodo"])]
			if n == "" {
				n = "Pago"
			}
			x := n + " " + strings.Replace(strconv.FormatFloat(m, 'f', 2, 64), ".", ",", 1)
			if len(actual)+len(x)+3 > 40 && actual != "" {
				lineas = append(lineas, actual)
				actual = ""
			}
			if actual == "" {
				actual = x
			} else {
				actual += " / " + x
			}
		}
		if actual != "" {
			lineas = append(lineas, actual)
		}
	}
	for i, l := range lineas {
		if i >= 3 {
			break
		}
		cmds = append(cmds, "A|"+texto(l, 40))
	}
	divisa := 0.0
	for _, p := range lista(d["pagos"]) {
		if metDivisa[str(p["metodo"])] {
			divisa += num(p["monto"])
		}
	}
	if cb(c, "igtf") && divisa > 0 && !nc {
		cmds = append(cmds, "E|U|"+sinPunto(divisa, 2))
	} else {
		cmds = append(cmds, "E|T")
	}
	return cmds, nil
}

// ---------------------------------------------------------------- PNP: transporte
type conexion interface {
	enviar(cmd string, espera time.Duration) (bool, []string, []byte)
	nombre() string
	cerrar()
}

type pnpSerial struct {
	p      Puerto
	puerto string
	sec    byte
	c      map[string]interface{}
}

func (t *pnpSerial) nombre() string { return t.puerto }
func (t *pnpSerial) cerrar()        { t.p.Close() }

func tramaPNP(sec byte, cmd string) []byte {
	partes := strings.Split(cmd, "|")
	d := []byte{0x02, sec}
	d = append(d, latin1(partes[0])...)
	for _, p := range partes[1:] {
		d = append(d, 0x1C)
		d = append(d, latin1(p)...)
	}
	d = append(d, 0x03)
	suma := 0
	for _, b := range d {
		suma += int(b)
	}
	return append(d, []byte(fmt.Sprintf("%04X", suma&0xFFFF))...)
}

func latin1(s string) []byte {
	out := []byte{}
	for _, r := range s {
		if r < 256 {
			out = append(out, byte(r))
		} else {
			out = append(out, '?')
		}
	}
	return out
}

func (t *pnpSerial) enviar(cmd string, espera time.Duration) (bool, []string, []byte) {
	if espera == 0 {
		espera = time.Duration(cf(t.c, "timeout_s") * float64(time.Second))
	}
	if t.sec < 0x20 || t.sec >= 0x7F {
		t.sec = 0x20
	} else {
		t.sec++
	}
	t.p.Purgar()
	t.p.Write(tramaPNP(t.sec, cmd))
	limite := time.Now().Add(espera)
	buf := []byte{}
	for time.Now().Before(limite) {
		b, _ := t.p.Leer(256, 150*time.Millisecond)
		if len(b) > 0 {
			limpio := []byte{}
			for _, x := range b {
				if x == 0x12 {
					limite = limite.Add(800 * time.Millisecond)
				} else {
					limpio = append(limpio, x)
				}
			}
			buf = append(buf, limpio...)
			if i := indexByte(buf, 0x03); i >= 0 {
				t0 := time.Now()
				for len(buf) < i+5 && time.Since(t0) < 500*time.Millisecond {
					m, _ := t.p.Leer(8, 100*time.Millisecond)
					buf = append(buf, m...)
				}
				break
			}
		}
	}
	log.Printf("PNP > %q < %q", cmd, recortar(buf, 200))
	i, j := indexByte(buf, 0x02), indexByte(buf, 0x03)
	if i < 0 || j < 0 || j < i {
		return false, nil, buf
	}
	cuerpo := string(buf[i+1 : j])
	campos := strings.Split(cuerpo, "\x1c")[1:]
	return !strings.Contains(strings.ToUpper(cuerpo), "ERROR"), campos, buf
}

func indexByte(b []byte, c byte) int {
	for i, x := range b {
		if x == c {
			return i
		}
	}
	return -1
}
func recortar(b []byte, n int) []byte {
	if len(b) > n {
		return b[:n]
	}
	return b
}

// Simulador (sin impresora): "simular": true en impresora_fiscal.json
type simulada struct{}

type estadoSim struct {
	Factura int    `json:"factura"`
	NC      int    `json:"nc"`
	Z       int    `json:"z"`
	Abierta string `json:"abierta"`
}

func (s simulada) nombre() string { return "SIMULADA" }
func (s simulada) cerrar()        {}
func (s simulada) enviar(cmd string, espera time.Duration) (bool, []string, []byte) {
	log.Printf("SIM > %q", cmd)
	ruta := filepath.Join(CARPETA, "fiscal_simulado.json")
	var e estadoSim
	if b, err := os.ReadFile(ruta); err == nil {
		json.Unmarshal(b, &e)
	}
	defer func() { b, _ := json.Marshal(e); os.WriteFile(ruta, b, 0644) }()
	switch {
	case strings.HasPrefix(cmd, "@"):
		if strings.HasSuffix(cmd, "|D") {
			e.Abierta = "nc"
		} else {
			e.Abierta = "factura"
		}
	case strings.HasPrefix(cmd, "E|") && e.Abierta != "":
		if e.Abierta == "nc" {
			e.NC++
		} else {
			e.Factura++
		}
		e.Abierta = ""
		return true, []string{"0080", "0000", "1", fmt.Sprintf("%08d", e.Factura), fmt.Sprintf("%08d", e.NC), "0"}, nil
	case strings.HasPrefix(cmd, "9|Z"):
		e.Z++
	case cmd == "\u0080":
		return true, []string{"0080", "0000", "SIM0000001"}, nil
	case strings.HasPrefix(cmd, "8"):
		return true, []string{"0080", "0000", "30", "00", "45", time.Now().Format("060102"), time.Now().Format("150405"), strconv.Itoa(e.Factura), "0", fmt.Sprintf("%08d", e.Factura), "0", fmt.Sprintf("%04d", e.Z)}, nil
	}
	return true, []string{"0080", "0000"}, nil
}

func respondePNP(puerto string, c map[string]interface{}) bool {
	p, err := abrirPuerto(puerto, int(cf(c, "baudios")), 'N')
	if err != nil {
		return false
	}
	t := &pnpSerial{p: p, puerto: puerto, c: c}
	defer t.cerrar()
	_, _, crudo := t.enviar(cs(c, "cmd_estado"), 1500*time.Millisecond)
	return indexByte(crudo, 0x02) >= 0
}

func abrirPNP(c map[string]interface{}) (conexion, error) {
	if cb(c, "simular") {
		return simulada{}, nil
	}
	fijo := strings.TrimSpace(cs(c, "puerto"))
	if fijo != "" && strings.ToUpper(fijo) != "AUTO" {
		p, err := abrirPuerto(fijo, int(cf(c, "baudios")), 'N')
		if err != nil {
			return nil, err
		}
		return &pnpSerial{p: p, puerto: fijo, c: c}, nil
	}
	previo := cs(c, "puerto_detectado")
	orden := []string{}
	if previo != "" {
		orden = append(orden, previo)
	}
	for _, x := range listarPuertos() {
		if x != previo {
			orden = append(orden, x)
		}
	}
	for _, x := range orden {
		if respondePNP(x, c) {
			if x != previo {
				b := cargarCfg()
				b["puerto_detectado"] = x
				guardarCfg(b)
			}
			p, err := abrirPuerto(x, int(cf(c, "baudios")), 'N')
			if err != nil {
				return nil, err
			}
			return &pnpSerial{p: p, puerto: x, c: c}, nil
		}
	}
	if len(orden) == 0 {
		return nil, errors.New("no se encontró la impresora fiscal. Revisa que esté encendida y con el cable USB conectado (Windows no muestra ningún puerto COM)")
	}
	return nil, errors.New("no se encontró la impresora fiscal PNP. Revisa que esté encendida y con el cable USB conectado. Puertos vistos: " + strings.Join(orden, ", "))
}

var reSerial = regexp.MustCompile(`\b([A-Z]{2,4}\d{6,8})\b`)

func leerSerialPNP(t conexion, c map[string]interface{}) interface{} {
	_, campos, _ := t.enviar(cs(c, "cmd_serial"), 2*time.Second)
	if m := reSerial.FindStringSubmatch(strings.Join(campos, "|")); m != nil {
		return m[1]
	}
	return nil
}

func esDigitos(s string) bool {
	s = strings.TrimSpace(s)
	if s == "" {
		return false
	}
	for _, r := range s {
		if !unicode.IsDigit(r) {
			return false
		}
	}
	return true
}

func estadoPNP(c map[string]interface{}) map[string]interface{} {
	lockFiscal.Lock()
	defer lockFiscal.Unlock()
	t, err := abrirPNP(c)
	if err != nil {
		p := cs(c, "puerto_detectado")
		if p == "" {
			p = cs(c, "puerto")
		}
		return map[string]interface{}{"ok": true, "conectada": false, "modelo": cs(c, "modelo"), "puerto": p, "marca": "pnp", "error": err.Error()}
	}
	defer t.cerrar()
	_, campos, _ := t.enviar(cs(c, "cmd_estado"), 2*time.Second)
	conectada := len(campos) > 0
	var serial, ultima interface{}
	if conectada {
		serial = leerSerialPNP(t, c)
	}
	if len(campos) > 9 && esDigitos(campos[9]) {
		ultima = strings.TrimSpace(campos[9])
	}
	var errTxt interface{}
	if !conectada {
		errTxt = "La impresora no respondió en " + t.nombre()
	}
	_, sim := t.(simulada)
	return map[string]interface{}{"ok": true, "conectada": conectada, "modelo": cs(c, "modelo"), "puerto": t.nombre(), "marca": "pnp", "simulada": sim,
		"serial": serial, "ultima_factura": ultima, "requiere_z": len(campos) > 3 && (campos[3] == "04" || campos[3] == "08"), "error": errTxt}
}

func documentoPNP(c map[string]interface{}, d map[string]interface{}, nc bool) (map[string]interface{}, error) {
	cmds, err := comandosPNP(d, c, nc)
	if err != nil {
		return nil, err
	}
	lockFiscal.Lock()
	defer lockFiscal.Unlock()
	t, err := abrirPNP(c)
	if err != nil {
		return map[string]interface{}{"ok": false, "error": err.Error()}, nil
	}
	defer t.cerrar()
	var resp []string
	for _, cmd := range cmds {
		espera := time.Duration(0)
		if strings.HasPrefix(cmd, "E") {
			espera = 12 * time.Second
		}
		ok, campos, crudo := t.enviar(cmd, espera)
		if !ok {
			det := "sin respuesta"
			if len(campos) > 2 {
				det = strings.Join(campos[2:], " ")
			} else if len(crudo) > 0 {
				det = string(crudo)
			}
			extra := ""
			if !strings.HasPrefix(cmd, "@") {
				extra = " Apaga y enciende la impresora para anular el documento que quedó abierto."
			}
			return map[string]interface{}{"ok": false, "error": fmt.Sprintf("La impresora fiscal rechazó el paso \"%s\": %s.%s", strings.Split(cmd, "|")[0], det, extra), "comando": cmd}, nil
		}
		resp = campos
	}
	var numero interface{}
	if len(resp) > 3 {
		n := strings.TrimSpace(resp[3])
		if nc && len(resp) > 4 && esDigitos(resp[4]) {
			n = strings.TrimSpace(resp[4])
		}
		if n != "" {
			numero = n
		}
	}
	return map[string]interface{}{"ok": true, "numero_fiscal": numero, "serial": leerSerialPNP(t, c), "comandos": len(cmds)}, nil
}

func comandoSimplePNP(c map[string]interface{}, cmd, alterno string, espera time.Duration) map[string]interface{} {
	lockFiscal.Lock()
	defer lockFiscal.Unlock()
	t, err := abrirPNP(c)
	if err != nil {
		return map[string]interface{}{"ok": false, "error": err.Error()}
	}
	defer t.cerrar()
	ok, campos, crudo := t.enviar(cmd, espera)
	if !ok && alterno != "" {
		ok, campos, crudo = t.enviar(alterno, espera)
	}
	if ok {
		return map[string]interface{}{"ok": true, "error": nil}
	}
	e := "Comando rechazado"
	if len(crudo) == 0 {
		e = "Sin respuesta de la impresora"
	} else if len(campos) > 2 {
		e = strings.Join(campos[2:], " ")
	}
	return map[string]interface{}{"ok": false, "error": e}
}

// ---------------------------------------------------------------- API /fiscal/*
func atenderFiscal(metodo, ruta string, d map[string]interface{}) (int, map[string]interface{}) {
	if ok, code, res := atenderDeteccion(metodo, ruta, d); ok {
		return code, res
	}
	code, res := atenderFiscalMarca(metodo, ruta, d)
	// Errores de la máquina en palabras claras (sin papel, tapa abierta, memoria llena…)
	if e, ok := res["error"].(string); ok && e != "" {
		res["error"] = traducirErrorFiscal(e)
	}
	return code, res
}

func atenderFiscalMarca(metodo, ruta string, d map[string]interface{}) (int, map[string]interface{}) {
	c := cargarCfg()
	if p := strings.TrimSpace(str(d["puerto"])); p != "" && strings.ToUpper(p) != "AUTO" && !strings.HasPrefix(ruta, "/fiscal/config") {
		c["puerto"] = p
	}
	if strings.HasPrefix(ruta, "/fiscal/config") {
		if metodo == "POST" {
			b := cargarCfg()
			for k, v := range d {
				if _, ok := cfgBase[k]; ok || k == "url" || k == "serial" {
					if k == "puerto" {
						v = strings.TrimSpace(str(v))
						if v == "" {
							v = "AUTO"
						}
					}
					b[k] = v
				}
			}
			guardarCfg(b)
			return 200, map[string]interface{}{"ok": true, "config": b}
		}
		return 200, map[string]interface{}{"ok": true, "config": c}
	}
	if cs(c, "marca") == "hka" {
		return atenderHKA(ruta, d, c)
	}
	// Marcas detectadas que todavía no facturan desde REFRIMAR (por probar)
	if drv := driverPorMarca(cs(c, "marca")); drv != nil && !drv.Factura() {
		if strings.HasPrefix(ruta, "/fiscal/estado") {
			lockFiscal.Lock()
			defer lockFiscal.Unlock()
			p := cs(c, "puerto")
			if r := drv.Probar(p, c); r != nil {
				return 200, map[string]interface{}{"ok": true, "conectada": true, "modelo": r.Modelo, "puerto": p, "marca": drv.Marca(), "serial": r.Serial, "por_probar": true}
			}
			return 200, map[string]interface{}{"ok": true, "conectada": false, "modelo": cs(c, "modelo"), "puerto": p, "marca": drv.Marca(), "error": "La impresora no respondió en " + p}
		}
		return 501, map[string]interface{}{"ok": false, "error": drv.Nombre() + " fue detectada pero todavía no emite documentos desde REFRIMAR (por probar). Usa el modo Ticket mientras tanto."}
	}
	switch {
	case strings.HasPrefix(ruta, "/fiscal/estado"):
		return 200, estadoPNP(c)
	case strings.HasPrefix(ruta, "/fiscal/factura"), strings.HasPrefix(ruta, "/fiscal/nota_credito"):
		r, err := documentoPNP(c, d, strings.HasPrefix(ruta, "/fiscal/nota_credito"))
		if err != nil {
			return 400, map[string]interface{}{"ok": false, "error": err.Error()}
		}
		if r["ok"] == true {
			return 200, r
		}
		return 500, r
	case strings.HasPrefix(ruta, "/fiscal/reporte"):
		z := strings.ToUpper(str(d["tipo"])) == "Z"
		cmd, alt := cs(c, "cmd_reporte_x"), "9|X"
		if z {
			cmd, alt = cs(c, "cmd_reporte_z"), "9|Z"
		}
		r := comandoSimplePNP(c, cmd, alt, 90*time.Second)
		return codigo(r), r
	case strings.HasPrefix(ruta, "/fiscal/gaveta"):
		r := comandoSimplePNP(c, cs(c, "cmd_gaveta"), "", 3*time.Second)
		return codigo(r), r
	case strings.HasPrefix(ruta, "/fiscal/comandos"):
		cmds, err := comandosPNP(d, c, d["nota_credito"] == true)
		if err != nil {
			return 400, map[string]interface{}{"ok": false, "error": err.Error()}
		}
		return 200, map[string]interface{}{"ok": true, "comandos": cmds}
	}
	return 404, map[string]interface{}{"ok": false, "error": "Not Found"}
}

func codigo(r map[string]interface{}) int {
	if r["ok"] == true {
		return 200
	}
	return 500
}
