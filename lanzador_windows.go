//go:build windows

package main

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func lanzarPuenteAparte() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	cmd := exec.Command(exe, "--puente")
	cmd.Dir = filepath.Dir(exe)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x00000008 | 0x00000200}
	if err := cmd.Start(); err != nil {
		log.Println("no se pudo iniciar el puente:", err)
	}
}

func navegador() string {
	c := []string{
		filepath.Join(os.Getenv("ProgramFiles(x86)"), `Microsoft\Edge\Application\msedge.exe`),
		filepath.Join(os.Getenv("ProgramFiles"), `Microsoft\Edge\Application\msedge.exe`),
		filepath.Join(os.Getenv("ProgramFiles"), `Google\Chrome\Application\chrome.exe`),
		filepath.Join(os.Getenv("ProgramFiles(x86)"), `Google\Chrome\Application\chrome.exe`),
		filepath.Join(os.Getenv("LOCALAPPDATA"), `Google\Chrome\Application\chrome.exe`),
	}
	for _, p := range c {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

func abrirVentana(url string) {
	if nav := navegador(); nav != "" {
		cmd := exec.Command(nav, "--app="+url, "--window-size=1366,820", "--start-maximized")
		if err := cmd.Start(); err == nil {
			return
		}
	}
	exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
}
