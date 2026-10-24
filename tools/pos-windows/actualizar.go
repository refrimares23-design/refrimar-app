package main

// Actualización automática del programa de la caja.
// Cada hora el puente lee <dominio>/pos-version.json:
//   { "version": "2.2.0", "url": "https://.../REFRIMAR-POS-Setup.exe", "sha256": "…", "notas": "…" }
// Si hay una versión más nueva: la descarga, revisa el SHA-256 y corre el instalador
// en silencio (/S). El instalador cierra el programa, lo reemplaza y lo vuelve a abrir.
// Para no cerrar la caja en medio de una venta, la instalación automática solo ocurre
// de noche (10 p. m. a 6 a. m.); de día se instala con el botón "Actualizar ahora" en Dispositivos.
// No actualiza si hay una factura imprimiéndose (usa el mismo candado de la impresora fiscal).
// Se desactiva con "auto_actualizar": false en impresora_fiscal.json.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

type infoVersion struct {
	Version string `json:"version"`
	URL     string `json:"url"`
	SHA256  string `json:"sha256"`
	Notas   string `json:"notas"`
}

var ultimaRevision = map[string]interface{}{}

func versionMayor(a, b string) bool { // ¿a > b?
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < 3; i++ {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func urlVersion() string {
	u, err := url.Parse(urlPOS())
	if err != nil {
		return ""
	}
	return u.Scheme + "://" + u.Host + "/pos-version.json"
}

func revisarActualizacion(instalar bool) (map[string]interface{}, error) {
	c := http.Client{Timeout: 20 * time.Second}
	r, err := c.Get(urlVersion())
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return nil, errors.New("sin archivo de versión (" + r.Status + ")")
	}
	var v infoVersion
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&v); err != nil {
		return nil, err
	}
	res := map[string]interface{}{"actual": VERSION, "disponible": v.Version, "nueva": versionMayor(v.Version, VERSION), "notas": v.Notas}
	ultimaRevision = res
	if !instalar || !versionMayor(v.Version, VERSION) || runtime.GOOS != "windows" {
		return res, nil
	}
	if !strings.HasPrefix(v.URL, "https://") || len(v.SHA256) != 64 {
		return res, errors.New("archivo de versión incompleto (falta url https o sha256)")
	}
	destino := filepath.Join(os.TempDir(), "REFRIMAR-POS-Setup-"+v.Version+".exe")
	if err := descargar(v.URL, destino, v.SHA256); err != nil {
		return res, err
	}
	// Espera a que no haya un documento fiscal imprimiéndose
	lockFiscal.Lock()
	log.Println("Instalando actualización", v.Version)
	cmd := exec.Command(destino, "/S")
	err = cmd.Start()
	lockFiscal.Unlock()
	if err != nil {
		return res, err
	}
	res["instalando"] = true
	return res, nil
}

func descargar(origen, destino, sha string) error {
	c := http.Client{Timeout: 10 * time.Minute}
	r, err := c.Get(origen)
	if err != nil {
		return err
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return errors.New("descarga falló: " + r.Status)
	}
	tmp := destino + ".part"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	h := sha256.New()
	_, err = io.Copy(io.MultiWriter(f, h), io.LimitReader(r.Body, 200<<20))
	f.Close()
	if err != nil {
		os.Remove(tmp)
		return err
	}
	if !strings.EqualFold(hex.EncodeToString(h.Sum(nil)), sha) {
		os.Remove(tmp)
		return errors.New("el instalador descargado no coincide con su firma SHA-256: no se instala")
	}
	return os.Rename(tmp, destino)
}

func cicloActualizacion() {
	time.Sleep(2 * time.Minute) // deja arrancar la caja primero
	for {
		if c := cargarCfg(); c["auto_actualizar"] != false {
			h := time.Now().Hour()
			if r, err := revisarActualizacion(h >= 22 || h < 6); err != nil {
				log.Println("Actualización:", err)
			} else if r["nueva"] == true {
				log.Println("Actualización disponible:", r["disponible"])
			}
		}
		time.Sleep(1 * time.Hour)
	}
}
