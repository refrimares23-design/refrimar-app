package main

// Detección automática de impresoras fiscales (todas las marcas).
//
// Cada marca es un "driver" con la misma interfaz. Para agregar una marca nueva:
// crea un archivo driver_<marca>.go con un tipo que cumpla DriverFiscal y agrégalo
// a DRIVERS en init() de ese archivo. Nada más cambia.
//
//   GET  /fiscal/detectar   → escanea todos los puertos COM con cada protocolo
//   POST /fiscal/usar       → { marca, puerto } elige la impresora detectada
//   GET  /fiscal/drivers    → marcas soportadas y si están probadas en equipo real

import (
	"log"
	"sort"
	"strings"
	"sync"
	"time"
)

type Detectado struct {
	Marca         string `json:"marca"`
	Modelo        string `json:"modelo"`
	Puerto        string `json:"puerto"`
	Serial        string `json:"serial"`
	Rif           string `json:"rif"`
	UltimaFactura string `json:"ultima_factura"`
	Protocolo     string `json:"protocolo"`
	PorProbar     bool   `json:"por_probar"`
	Estado        string `json:"estado"`
}

type DriverFiscal interface {
	Marca() string   // clave guardada en impresora_fiscal.json ("pnp", "hka", "epson"…)
	Nombre() string  // nombre para mostrar
	Modelos() string // modelos conocidos
	Probado() bool   // false = implementado según documentación, falta probar con la máquina
	Factura() bool   // true si ya puede emitir facturas / notas de crédito
	Probar(puerto string, c map[string]interface{}) *Detectado
}

var (
	DRIVERS    []DriverFiscal
	lockDetect sync.Mutex
)

func registrarDriver(d DriverFiscal) { DRIVERS = append(DRIVERS, d) }

// ---------------------------------------------------------------- PNP
type drvPNP struct{}

func (drvPNP) Marca() string   { return "pnp" }
func (drvPNP) Nombre() string  { return "Desarrollos PNP (incluye Epson con firmware PNP)" }
func (drvPNP) Modelos() string { return "PF-220, PF-300, PF-950, DT-230, Epson TM-675A, Epson TM-950A" }
func (drvPNP) Probado() bool   { return false } // falta la prueba con la PNP real (Reporte X)
func (drvPNP) Factura() bool   { return true }
func (drvPNP) Probar(puerto string, c map[string]interface{}) *Detectado {
	p, err := abrirPuerto(puerto, int(cf(c, "baudios")), 'N')
	if err != nil {
		return nil
	}
	t := &pnpSerial{p: p, puerto: puerto, c: c}
	defer t.cerrar()
	_, campos, crudo := t.enviar(cs(c, "cmd_estado"), 1500*time.Millisecond)
	if indexByte(crudo, 0x02) < 0 {
		return nil
	}
	d := &Detectado{Marca: "pnp", Modelo: "Impresora fiscal PNP", Puerto: puerto, Protocolo: "PNP", Estado: "lista", PorProbar: true}
	if s, ok := leerSerialPNP(t, c).(string); ok {
		d.Serial = s
	}
	if len(campos) > 9 && esDigitos(campos[9]) {
		d.UltimaFactura = strings.TrimSpace(campos[9])
	}
	if len(campos) > 3 && (campos[3] == "04" || campos[3] == "08") {
		d.Estado = "requiere Reporte Z"
	}
	return d
}

// ---------------------------------------------------------------- HKA / The Factory
// Bixolon SRP-350/SRP-812, Aclas, Dascom/Tally, Star, Okidata y modelos HKA usan el protocolo TFHKA.
type drvHKA struct{}

func (drvHKA) Marca() string   { return "hka" }
func (drvHKA) Nombre() string  { return "The Factory HKA (Bixolon, Aclas, Tally, Star, Okidata)" }
func (drvHKA) Modelos() string { return "SRP-350, SRP-812, HKA80, CR68AF, PP9, Tally 1125" }
func (drvHKA) Probado() bool   { return false }
func (drvHKA) Factura() bool   { return true }
func (drvHKA) Probar(puerto string, c map[string]interface{}) *Detectado {
	par := byte('E')
	if s := cs(c, "hka_paridad"); s != "" {
		par = s[0]
	}
	p, err := abrirPuerto(puerto, int(cf(c, "baudios")), par)
	if err != nil {
		return nil
	}
	t := &hkaSerial{p: p, puerto: puerto}
	defer t.p.Close()
	r := leerS1(t, c)
	if len(r) == 0 {
		return nil
	}
	d := &Detectado{Marca: "hka", Modelo: "Impresora fiscal HKA / Bixolon", Puerto: puerto, Protocolo: "TFHKA", Estado: "lista", PorProbar: true}
	d.Serial, _ = r["serial"].(string)
	d.Rif, _ = r["rif"].(string)
	d.UltimaFactura, _ = r["ultima_factura"].(string)
	return d
}

func init() {
	registrarDriver(drvPNP{})
	registrarDriver(drvHKA{})
}

func driverPorMarca(m string) DriverFiscal {
	for _, d := range DRIVERS {
		if d.Marca() == m {
			return d
		}
	}
	return nil
}

// Escanea todos los puertos con todos los drivers (primero el que ya se usaba)
func detectarFiscales(c map[string]interface{}) []Detectado {
	lockDetect.Lock()
	defer lockDetect.Unlock()
	lockFiscal.Lock()
	defer lockFiscal.Unlock()
	puertos := listarPuertos()
	sort.Strings(puertos)
	// Orden de prueba: la marca configurada, luego PNP, HKA y el resto (Epson usa una trama parecida a PNP)
	pri := map[string]int{"pnp": 1, "hka": 2}
	actual := cs(c, "marca")
	peso := func(d DriverFiscal) int {
		if d.Marca() == actual {
			return 0
		}
		if v, ok := pri[d.Marca()]; ok {
			return v
		}
		return 9
	}
	orden := append([]DriverFiscal{}, DRIVERS...)
	sort.SliceStable(orden, func(i, j int) bool { return peso(orden[i]) < peso(orden[j]) })
	out := []Detectado{}
	for _, p := range puertos {
		for _, d := range orden {
			ini := time.Now()
			if r := d.Probar(p, c); r != nil {
				log.Printf("Detectada %s en %s (%v)", d.Marca(), p, time.Since(ini))
				out = append(out, *r)
				break
			}
		}
	}
	b := cargarCfg()
	b["detectados"] = out
	b["detectados_at"] = time.Now().Format(time.RFC3339)
	guardarCfg(b)
	return out
}

// Causa probable cuando no se encuentra ninguna impresora
func diagnosticoSinFiscal() []string {
	ps := listarPuertos()
	if len(ps) == 0 {
		return []string{
			"Windows no muestra ningún puerto COM: revisa el cable USB y que la impresora esté encendida.",
			"Falta el driver USB-serial (CH340, Prolific PL2303 o FTDI). Instálalo desde Dispositivos → Instalar drivers USB.",
		}
	}
	return []string{
		"Se ven los puertos " + strings.Join(ps, ", ") + " pero ninguna impresora respondió.",
		"La impresora puede estar apagada, sin papel o con un documento abierto: apágala y enciéndela.",
		"Otro programa puede estar usando el puerto (cierra otros sistemas de facturación).",
	}
}

// Traduce errores de la máquina a palabras claras
func traducirErrorFiscal(e string) string {
	u := strings.ToUpper(e)
	switch {
	case strings.Contains(u, "PAPEL") || strings.Contains(u, "PAPER"):
		return "La impresora fiscal no tiene papel. Cambia el rollo y vuelve a intentar: la factura quedó pendiente por fiscalizar."
	case strings.Contains(u, "TAPA") || strings.Contains(u, "COVER"):
		return "La tapa de la impresora fiscal está abierta. Ciérrala y vuelve a intentar."
	case strings.Contains(u, "MEMORIA") && (strings.Contains(u, "LLENA") || strings.Contains(u, "AGOT")):
		return "La memoria fiscal está casi llena o agotada. Llama al técnico autorizado de la impresora."
	case strings.Contains(u, "Z") && strings.Contains(u, "REPORTE") && strings.Contains(u, "REQUI"):
		return "La impresora pide el Reporte Z del día anterior antes de seguir facturando."
	}
	return e
}

func infoDrivers() []map[string]interface{} {
	l := []map[string]interface{}{}
	for _, d := range DRIVERS {
		l = append(l, map[string]interface{}{"marca": d.Marca(), "nombre": d.Nombre(), "modelos": d.Modelos(), "probado": d.Probado(), "factura": d.Factura()})
	}
	return l
}

// Rutas nuevas; devuelve false si la ruta no es de detección
func atenderDeteccion(metodo, ruta string, d map[string]interface{}) (bool, int, map[string]interface{}) {
	switch {
	case strings.HasPrefix(ruta, "/fiscal/drivers"):
		return true, 200, map[string]interface{}{"ok": true, "drivers": infoDrivers()}
	case strings.HasPrefix(ruta, "/fiscal/detectar"):
		c := cargarCfg()
		l := detectarFiscales(c)
		r := map[string]interface{}{"ok": true, "dispositivos": l, "puertos": listarPuertos(), "marca_actual": cs(c, "marca"), "puerto_actual": cs(c, "puerto")}
		if len(l) == 0 {
			r["ayuda"] = diagnosticoSinFiscal()
		}
		return true, 200, r
	case strings.HasPrefix(ruta, "/fiscal/usar") && metodo == "POST":
		m, p := str(d["marca"]), strings.TrimSpace(str(d["puerto"]))
		drv := driverPorMarca(m)
		if drv == nil {
			return true, 400, map[string]interface{}{"ok": false, "error": "Marca desconocida: " + m}
		}
		b := cargarCfg()
		b["marca"] = m
		b["modelo"] = "Impresora fiscal " + drv.Nombre()
		if p != "" {
			b["puerto"] = p
			b["puerto_detectado"] = p
		}
		guardarCfg(b)
		return true, 200, map[string]interface{}{"ok": true, "marca": m, "puerto": p, "factura": drv.Factura(), "probado": drv.Probado()}
	}
	return false, 0, nil
}
