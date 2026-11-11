//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
)

func lanzarPuenteAparte() {
	exe, _ := os.Executable()
	exec.Command(exe, "--puente").Start()
}
func abrirVentana(url string) { fmt.Println("Abrir:", url) }
