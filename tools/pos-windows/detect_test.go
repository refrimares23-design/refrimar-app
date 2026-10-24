package main

import (
	"os"
	"strings"
	"testing"
)

func TestDetectarPNP(t *testing.T) {
	b, err := os.ReadFile("/tmp/claude-0/pty.txt")
	if err != nil {
		t.Skip("sin pty")
	}
	CARPETA = t.TempDir()
	PUERTOS_PRUEBA = []string{strings.TrimSpace(string(b))}
	if f, e := os.OpenFile(PUERTOS_PRUEBA[0], os.O_RDWR, 0); e != nil {
		t.Skip("pty no disponible")
	} else {
		f.Close()
	}
	l := detectarFiscales(cargarCfg())
	t.Logf("%+v", l)
	if len(l) != 1 || l[0].Marca != "pnp" || l[0].Serial != "ZPA1234567" || l[0].UltimaFactura != "00000123" {
		t.Fatalf("detección inesperada: %+v", l)
	}
	ok, code, r := atenderDeteccion("POST", "/fiscal/usar", map[string]interface{}{"marca": "hka", "puerto": "COM9"})
	if !ok || code != 200 || cargarCfg()["marca"] != "hka" {
		t.Fatalf("usar falló %v %v", code, r)
	}
}

func TestBalanza(t *testing.T) {
	b, err := os.ReadFile("/tmp/claude-0/pty2.txt")
	if err != nil {
		t.Skip("sin pty")
	}
	p := strings.TrimSpace(string(b))
	if f, e := os.OpenFile(p, os.O_RDWR, 0); e != nil {
		t.Skip("pty no disponible")
	} else {
		f.Close()
	}
	peso, est, ok := leerPeso(p, 9600)
	if !ok || peso != 1.25 || !est {
		t.Fatalf("peso %v %v %v", peso, est, ok)
	}
}

// Monto en divisas y tasa BCV en la factura fiscal (Providencia 0071 art. 14)
func TestComentariosDivisas(t *testing.T) {
	d := map[string]interface{}{
		"cliente":     map[string]interface{}{"nombre": "PEDRO PEREZ", "rif": "V12345678"},
		"items":       []interface{}{map[string]interface{}{"descripcion": "DISCO CORTE", "precio": 1551.72, "cantidad": 1.0, "iva": 16.0}},
		"pagos":       []interface{}{map[string]interface{}{"metodo": "efectivo", "monto": 1800.0}},
		"comentarios": []interface{}{"TOTAL US$ 10,00 TASA BCV 180,00"},
	}
	cmds, err := comandosPNP(d, cargarCfg(), false)
	if err != nil {
		t.Fatal(err)
	}
	hay := false
	for _, c := range cmds {
		if strings.HasPrefix(c, "A|TOTAL US$ 10,00") {
			hay = true
		}
	}
	if !hay {
		t.Fatalf("PNP sin comentario de divisas: %v", cmds)
	}
	h, err := comandosHKA(d, cargarCfg(), false)
	if err != nil {
		t.Fatal(err)
	}
	hay = false
	for _, c := range h {
		if strings.HasPrefix(c, "@TOTAL US$ 10,00") {
			hay = true
		}
	}
	if !hay {
		t.Fatalf("HKA sin comentario de divisas: %v", h)
	}
}

func TestImpresoraCualquiera(t *testing.T) {
	f := t.TempDir() + "/hp-laserjet"
	if ok, msg := imprimirTexto("FACTURA\nCAFÉ ñ", f, false, ""); !ok {
		t.Fatal(msg)
	}
	b, _ := os.ReadFile(f)
	if len(b) == 0 || b[0] == 0x1B || !strings.Contains(string(b), "FACTURA\r\n") || !strings.Contains(string(b), "CAF\xc9 \xf1") {
		t.Fatalf("una impresora normal debe recibir texto plano: %q", b)
	}
	g := t.TempDir() + "/POS-80 termica"
	imprimirTexto("TICKET", g, true, "")
	c, _ := os.ReadFile(g)
	if len(c) < 2 || c[0] != 0x1B || c[1] != '@' {
		t.Fatalf("una térmica debe recibir ESC/POS: %q", c)
	}
}
