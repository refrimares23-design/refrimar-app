//go:build !windows

package main

import (
	"errors"
	"os"
)

// En Linux (pruebas) la "impresora" es un archivo si existe REFRIMAR_IMPRESORA
func impresoraPredeterminada() string { return os.Getenv("REFRIMAR_IMPRESORA") }
func listarImpresoras() []string {
	if p := impresoraPredeterminada(); p != "" {
		return []string{p}
	}
	return []string{}
}
func rawImprimir(nombre string, datos []byte) error {
	if nombre == "" {
		return errors.New("sin impresora")
	}
	return os.WriteFile(nombre, datos, 0644)
}

func imprimirDatos(nombre string, datos []byte, tipoDatos string) error { return rawImprimir(nombre, datos) }
