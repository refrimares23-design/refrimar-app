//go:build windows

package main

import (
	"errors"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

var (
	kernel32         = syscall.NewLazyDLL("kernel32.dll")
	pGetCommState    = kernel32.NewProc("GetCommState")
	pSetCommState    = kernel32.NewProc("SetCommState")
	pSetCommTimeouts = kernel32.NewProc("SetCommTimeouts")
	pPurgeComm       = kernel32.NewProc("PurgeComm")
	advapi32         = syscall.NewLazyDLL("advapi32.dll")
	pRegEnumValueW   = advapi32.NewProc("RegEnumValueW")
)

type dcb struct {
	DCBlength  uint32
	BaudRate   uint32
	Flags      uint32
	wReserved  uint16
	XonLim     uint16
	XoffLim    uint16
	ByteSize   byte
	Parity     byte
	StopBits   byte
	XonChar    byte
	XoffChar   byte
	ErrorChar  byte
	EofChar    byte
	EvtChar    byte
	wReserved1 uint16
}

type commTimeouts struct {
	ReadIntervalTimeout         uint32
	ReadTotalTimeoutMultiplier  uint32
	ReadTotalTimeoutConstant    uint32
	WriteTotalTimeoutMultiplier uint32
	WriteTotalTimeoutConstant   uint32
}

type puertoWin struct {
	h       syscall.Handle
	ultimoT uint32
}

func abrirPuerto(nombre string, baud int, paridad byte) (Puerto, error) {
	ruta := nombre
	if !strings.HasPrefix(ruta, `\\.\`) {
		ruta = `\\.\` + nombre
	}
	p, _ := syscall.UTF16PtrFromString(ruta)
	h, err := syscall.CreateFile(p, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0, nil, syscall.OPEN_EXISTING, 0, 0)
	if err != nil {
		return nil, errors.New("no se pudo abrir " + nombre + ": " + err.Error())
	}
	var d dcb
	d.DCBlength = uint32(unsafe.Sizeof(d))
	pGetCommState.Call(uintptr(h), uintptr(unsafe.Pointer(&d)))
	d.BaudRate = uint32(baud)
	d.ByteSize = 8
	d.StopBits = 0                     // ONESTOPBIT
	d.Flags = 1 | (1 << 4) | (1 << 12) // fBinary, DTR_CONTROL_ENABLE, RTS_CONTROL_ENABLE
	switch paridad {
	case 'E':
		d.Parity = 2
		d.Flags |= 1 << 1
	case 'O':
		d.Parity = 1
		d.Flags |= 1 << 1
	default:
		d.Parity = 0
	}
	if r, _, e := pSetCommState.Call(uintptr(h), uintptr(unsafe.Pointer(&d))); r == 0 {
		syscall.CloseHandle(h)
		return nil, errors.New("no se pudo configurar " + nombre + ": " + e.Error())
	}
	pw := &puertoWin{h: h}
	pw.timeouts(300)
	return pw, nil
}

func (p *puertoWin) timeouts(ms uint32) {
	if ms == p.ultimoT {
		return
	}
	t := commTimeouts{ReadIntervalTimeout: 0xFFFFFFFF, ReadTotalTimeoutMultiplier: 0xFFFFFFFF, ReadTotalTimeoutConstant: ms, WriteTotalTimeoutConstant: 3000}
	pSetCommTimeouts.Call(uintptr(p.h), uintptr(unsafe.Pointer(&t)))
	p.ultimoT = ms
}

func (p *puertoWin) Write(b []byte) (int, error) {
	var n uint32
	err := syscall.WriteFile(p.h, b, &n, nil)
	return int(n), err
}

func (p *puertoWin) Leer(max int, espera time.Duration) ([]byte, error) {
	ms := uint32(espera / time.Millisecond)
	if ms < 1 {
		ms = 1
	}
	p.timeouts(ms)
	buf := make([]byte, max)
	var n uint32
	err := syscall.ReadFile(p.h, buf, &n, nil)
	return buf[:n], err
}

func (p *puertoWin) Purgar()      { pPurgeComm.Call(uintptr(p.h), 0x0008|0x0004) }
func (p *puertoWin) Close() error { return syscall.CloseHandle(p.h) }

// Puertos COM según el registro (HKLM\HARDWARE\DEVICEMAP\SERIALCOMM), los USB primero
func listarPuertos() []string {
	var k syscall.Handle
	ruta, _ := syscall.UTF16PtrFromString(`HARDWARE\DEVICEMAP\SERIALCOMM`)
	if syscall.RegOpenKeyEx(syscall.HKEY_LOCAL_MACHINE, ruta, 0, syscall.KEY_READ, &k) != nil {
		return []string{}
	}
	defer syscall.RegCloseKey(k)
	type item struct {
		com string
		pr  int
	}
	l := []item{}
	for i := uint32(0); i < 64; i++ {
		nom := make([]uint16, 256)
		nlen := uint32(len(nom))
		dat := make([]uint16, 64)
		dlen := uint32(len(dat) * 2)
		var tipo uint32
		r, _, _ := pRegEnumValueW.Call(uintptr(k), uintptr(i), uintptr(unsafe.Pointer(&nom[0])), uintptr(unsafe.Pointer(&nlen)), 0,
			uintptr(unsafe.Pointer(&tipo)), uintptr(unsafe.Pointer(&dat[0])), uintptr(unsafe.Pointer(&dlen)))
		if r != 0 {
			break
		}
		dev := strings.ToLower(syscall.UTF16ToString(nom[:nlen]))
		com := syscall.UTF16ToString(dat)
		pr := 5
		switch {
		case strings.Contains(dev, "bth"):
			pr = 9
		case strings.Contains(dev, "usb") || strings.Contains(dev, "vcp") || strings.Contains(dev, "silab") || strings.Contains(dev, "ch34") || strings.Contains(dev, "prolific") || strings.Contains(dev, "ftdi") || strings.Contains(dev, "ser2pl"):
			pr = 1
		}
		l = append(l, item{com, pr})
	}
	sort.SliceStable(l, func(a, b int) bool { return l[a].pr < l[b].pr })
	out := []string{}
	visto := map[string]bool{}
	for _, x := range l {
		out = append(out, x.com)
		visto[strings.ToUpper(x.com)] = true
	}
	// Por si el driver no se registró: probar también COM1..COM20 que existan
	for i := 1; i <= 20; i++ {
		c := "COM" + strconv.Itoa(i)
		if !visto[c] && existePuerto(c) {
			out = append(out, c)
		}
	}
	return out
}

func existePuerto(nombre string) bool {
	p, _ := syscall.UTF16PtrFromString(`\\.\` + nombre)
	h, err := syscall.CreateFile(p, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0, nil, syscall.OPEN_EXISTING, 0, 0)
	if err != nil {
		// ERROR_ACCESS_DENIED (5) = existe pero lo está usando otro programa
		return err == syscall.Errno(5)
	}
	syscall.CloseHandle(h)
	return true
}
