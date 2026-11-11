//go:build !windows

package main

import (
	"os"
	"syscall"
	"time"
)

// Implementación para pruebas en Linux (pty o /dev/ttyUSB*)
type puertoUnix struct{ f *os.File }

func abrirPuerto(nombre string, baud int, paridad byte) (Puerto, error) {
	f, err := os.OpenFile(nombre, os.O_RDWR|syscall.O_NOCTTY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	return &puertoUnix{f}, nil
}
func (p *puertoUnix) Write(b []byte) (int, error) { return p.f.Write(b) }
func (p *puertoUnix) Leer(max int, espera time.Duration) ([]byte, error) {
	p.f.SetReadDeadline(time.Now().Add(espera))
	buf := make([]byte, max)
	n, err := p.f.Read(buf)
	if os.IsTimeout(err) {
		err = nil
	}
	return buf[:n], err
}
func (p *puertoUnix) Purgar() {
	for {
		b, _ := p.Leer(256, 5*time.Millisecond)
		if len(b) == 0 {
			return
		}
	}
}
func (p *puertoUnix) Close() error { return p.f.Close() }

var PUERTOS_PRUEBA []string

func listarPuertos() []string { return PUERTOS_PRUEBA }
