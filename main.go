// REFRIMAR POS — aplicación de escritorio para la caja.
//
//	refrimar-pos.exe            abre la App POS en su propia ventana (y arranca el
//	                            programa de impresión si no está corriendo)
//	refrimar-pos.exe --puente   solo el programa de impresión (arranca con Windows)
//
// El programa de impresión escucha en http://127.0.0.1:3001 y maneja la impresora
// fiscal (PNP o HKA/Bixolon por USB-serial) y la impresora de tickets (ESC/POS).
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const VERSION = "2.1.0"
const PUERTO_HTTP = "127.0.0.1:3001"
const URL_POS = "https://refrimar-app.refrimar-es23.workers.dev/pos.html"

var CARPETA string

func carpetaDatos() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		if h, err := os.UserHomeDir(); err == nil {
			base = h
		} else {
			base = "."
		}
	}
	d := filepath.Join(base, "RefrimarPOS")
	os.MkdirAll(d, 0755)
	return d
}

func puenteActivo() bool {
	c := http.Client{Timeout: 1500 * time.Millisecond}
	r, err := c.Get("http://" + PUERTO_HTTP + "/health")
	if err != nil {
		return false
	}
	r.Body.Close()
	return true
}

func main() {
	CARPETA = carpetaDatos()
	f, err := os.OpenFile(filepath.Join(CARPETA, "puente.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err == nil {
		if st, e := f.Stat(); e == nil && st.Size() > 3_000_000 {
			f.Truncate(0)
		}
		log.SetOutput(f)
	}
	args := strings.Join(os.Args[1:], " ")
	switch {
	case strings.Contains(args, "--puente"):
		correrPuente()
	case strings.Contains(args, "--version"):
		fmt.Println("REFRIMAR POS", VERSION)
	default:
		if !puenteActivo() {
			lanzarPuenteAparte()
			for i := 0; i < 20 && !puenteActivo(); i++ {
				time.Sleep(150 * time.Millisecond)
			}
		}
		abrirVentana(urlPOS())
	}
}

func urlPOS() string {
	c := cargarCfg()
	if u, ok := c["url"].(string); ok && strings.HasPrefix(u, "http") {
		return u
	}
	return URL_POS
}

func correrPuente() {
	ln, err := net.Listen("tcp", PUERTO_HTTP)
	if err != nil {
		log.Println("El puente ya está corriendo:", err)
		return
	}
	log.Println("Puente REFRIMAR", VERSION, "escuchando en", PUERTO_HTTP)
	go cicloActualizacion()
	http.Serve(ln, http.HandlerFunc(atender))
}

func responder(w http.ResponseWriter, code int, v interface{}) {
	h := w.Header()
	h.Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func atender(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Access-Control-Allow-Origin", "*")
	h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	h.Set("Access-Control-Allow-Headers", "Content-Type")
	h.Set("Access-Control-Allow-Private-Network", "true")
	if r.Method == http.MethodOptions {
		w.WriteHeader(204)
		return
	}
	defer func() {
		if e := recover(); e != nil {
			log.Println("PANIC", r.URL.Path, e)
			responder(w, 500, map[string]interface{}{"ok": false, "error": fmt.Sprint(e)})
		}
	}()
	datos := map[string]interface{}{}
	if r.Method == http.MethodPost {
		json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20)).Decode(&datos)
	}
	p := r.URL.Path
	switch {
	case strings.HasPrefix(p, "/fiscal/"):
		code, res := atenderFiscal(r.Method, p, datos)
		responder(w, code, res)
	case strings.HasPrefix(p, "/health"):
		imp := detectarImpresora()
		code := 200
		var errTxt interface{}
		if imp == "" {
			code = 500
			errTxt = "Sin impresora de tickets detectada. Conéctala y reintenta."
		}
		responder(w, code, map[string]interface{}{"ok": imp != "", "printer": nilSiVacio(imp), "error": errTxt, "version": VERSION, "app": "REFRIMAR POS"})
	case strings.HasPrefix(p, "/balanza/"):
		lockFiscal.Lock()
		code, res := atenderBalanza(p)
		lockFiscal.Unlock()
		responder(w, code, res)
	case strings.HasPrefix(p, "/version"):
		// ?instalar=1 instala ya la versión nueva si existe
		res, err := revisarActualizacion(r.URL.Query().Get("instalar") == "1")
		if err != nil {
			responder(w, 200, map[string]interface{}{"ok": false, "actual": VERSION, "error": err.Error()})
			return
		}
		res["ok"] = true
		responder(w, 200, res)
	case strings.HasPrefix(p, "/printers"):
		responder(w, 200, map[string]interface{}{"ok": true, "printers": listarImpresoras()})
	case strings.HasPrefix(p, "/print"):
		txt, _ := datos["text"].(string)
		if txt == "" {
			txt = "REFRIMAR"
		}
		nombre, _ := datos["printer"].(string)
		cajon, _ := datos["drawer"].(bool)
		ok, msg := imprimirTexto(txt, nombre, cajon)
		code := 200
		if !ok {
			code = 500
		}
		responder(w, code, map[string]interface{}{"ok": ok, "message": msg, "error": siError(ok, msg)})
	case strings.HasPrefix(p, "/drawer"):
		nombre, _ := datos["printer"].(string)
		ok, msg := abrirCajon(nombre)
		code := 200
		if !ok {
			code = 500
		}
		responder(w, code, map[string]interface{}{"ok": ok, "message": msg, "error": siError(ok, msg)})
	default:
		responder(w, 404, map[string]interface{}{"ok": false, "error": "Not Found"})
	}
}

func nilSiVacio(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}
func siError(ok bool, msg string) interface{} {
	if ok {
		return nil
	}
	return msg
}
