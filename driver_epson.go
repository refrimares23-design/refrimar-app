package main

// Epson fiscal (TM-T900FA, TM-U220AF y otros homologados en Venezuela).
// Usa la misma trama que PNP (STX + secuencia + comando + campos FS + ETX + suma en 4 hex),
// con el comando de estado "*". POR PROBAR: solo detecta y lee el estado; todavía no emite
// facturas desde REFRIMAR hasta confirmar sus comandos con una máquina real.

import (
	"strings"
	"time"
)

type drvEpson struct{}

func (drvEpson) Marca() string   { return "epson" }
func (drvEpson) Nombre() string  { return "Epson fiscal" }
func (drvEpson) Modelos() string { return "TM-T900FA, TM-U220AF" }
func (drvEpson) Probado() bool   { return false }
func (drvEpson) Factura() bool   { return false }
func (drvEpson) Probar(puerto string, c map[string]interface{}) *Detectado {
	p, err := abrirPuerto(puerto, 9600, 'N')
	if err != nil {
		return nil
	}
	t := &pnpSerial{p: p, puerto: puerto, c: c}
	defer t.cerrar()
	_, campos, crudo := t.enviar("*", 1500*time.Millisecond)
	if indexByte(crudo, 0x02) < 0 {
		return nil
	}
	d := &Detectado{Marca: "epson", Modelo: "Impresora fiscal Epson", Puerto: puerto, Protocolo: "Epson fiscal", Estado: "detectada (por probar)", PorProbar: true}
	for _, x := range campos {
		if m := reSerial.FindStringSubmatch(strings.ToUpper(x)); m != nil {
			d.Serial = m[1]
			break
		}
	}
	return d
}

func init() { registrarDriver(drvEpson{}) }
