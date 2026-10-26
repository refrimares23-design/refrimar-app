package main

import "strings"

var cp850 = map[rune]byte{
	'Ç': 0x80, 'ü': 0x81, 'é': 0x82, 'â': 0x83, 'ä': 0x84, 'à': 0x85, 'ç': 0x87, 'ê': 0x88, 'ë': 0x89, 'è': 0x8A,
	'ï': 0x8B, 'î': 0x8C, 'ì': 0x8D, 'Ä': 0x8E, 'É': 0x90, 'ô': 0x93, 'ö': 0x94, 'ò': 0x95, 'û': 0x96, 'ù': 0x97,
	'Ö': 0x99, 'Ü': 0x9A, 'á': 0xA0, 'í': 0xA1, 'ó': 0xA2, 'ú': 0xA3, 'ñ': 0xA4, 'Ñ': 0xA5, 'ª': 0xA6, 'º': 0xA7,
	'¿': 0xA8, '¡': 0xAD, 'Á': 0xB5, 'Â': 0xB6, 'À': 0xB7, 'Í': 0xD6, 'Ó': 0xE0, 'Ú': 0xE9, '°': 0xF8, '·': 0xFA,
}

func aCP850(s string) []byte {
	out := make([]byte, 0, len(s))
	for _, r := range s {
		if r < 128 {
			out = append(out, byte(r))
		} else if b, ok := cp850[r]; ok {
			out = append(out, b)
		} else {
			out = append(out, '?')
		}
	}
	return out
}

var pulsoCajon = []byte{0x1B, 'p', 0x00, 0x19, 0xFA}

func escpos(texto string, cortar, cajon bool) []byte {
	out := []byte{0x1B, '@'}
	for _, l := range strings.Split(texto, "\n") {
		out = append(out, aCP850(l)...)
		out = append(out, '\n')
	}
	out = append(out, '\n', '\n', '\n')
	if cajon {
		out = append(out, pulsoCajon...)
	}
	if cortar {
		out = append(out, 0x1D, 'V', 0x00)
	}
	return out
}

var palabrasTermica = []string{"termica", "térmica", "thermal", "80mm", "58mm", "80 mm", "58 mm", "pos", "ticket", "receipt", "recibo",
	"epson tm", "tm-t", "tm-u", "xprinter", "xp-", "3nstar", "bixolon", "srp-", "star tsp", "star sp", "sewoo", "rongta", "gprinter",
	"hoin", "zjiang", "sunmi", "citizen ct", "posiflex", "hprt", "munbyn", "rp80", "rp58"}

// esTermica: las térmicas entienden ESC/POS; las demás (láser, tinta, PDF) reciben texto normal por Windows
func esTermica(nombre string) bool {
	l := strings.ToLower(nombre)
	for _, p := range palabrasTermica {
		if strings.Contains(l, p) {
			return true
		}
	}
	return false
}

func detectarImpresora() string {
	if d := impresoraPredeterminada(); d != "" {
		return d
	}
	for _, n := range listarImpresoras() {
		if esTermica(n) {
			return n
		}
	}
	return ""
}

// formato: "escpos" (térmica), "texto" (cualquier impresora de Windows) o "" = automático según el nombre
func imprimirTexto(texto, nombre string, cajon bool, formato string) (bool, string) {
	if nombre == "" {
		nombre = detectarImpresora()
	}
	if nombre == "" {
		return false, "No hay impresora conectada. Enciéndela y vuelve a imprimir."
	}
	if formato == "texto" || (formato == "" && !esTermica(nombre)) {
		datos := []byte(strings.ReplaceAll(texto, "\n", "\r\n") + "\r\n\f")
		if err := imprimirDatos(nombre, aCP1252(datos), "TEXT"); err != nil {
			// algunos controladores no aceptan TEXT: se intenta como datos directos
			if err2 := imprimirDatos(nombre, aCP1252(datos), "RAW"); err2 != nil {
				return false, "Error: " + err.Error()
			}
		}
		return true, "Impreso en: " + nombre
	}
	return enviarRaw(escpos(texto, true, cajon), nombre)
}

// Windows (texto normal) usa la página de códigos 1252: tildes y ñ salen bien
func aCP1252(b []byte) []byte {
	out := make([]byte, 0, len(b))
	for _, r := range string(b) {
		if r < 256 {
			out = append(out, byte(r))
		} else {
			out = append(out, '?')
		}
	}
	return out
}

func abrirCajon(nombre string) (bool, string) {
	return enviarRaw(append([]byte{0x1B, '@'}, pulsoCajon...), nombre)
}

func enviarRaw(datos []byte, nombre string) (bool, string) {
	if nombre == "" {
		nombre = detectarImpresora()
	}
	if nombre == "" {
		return false, "No hay impresora conectada. Enciéndela y vuelve a imprimir."
	}
	if err := imprimirDatos(nombre, datos, "RAW"); err != nil {
		return false, "Error: " + err.Error()
	}
	return true, "Impreso en: " + nombre
}
