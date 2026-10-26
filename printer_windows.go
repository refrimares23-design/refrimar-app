//go:build windows

package main

import (
	"errors"
	"syscall"
	"unsafe"
)

var (
	winspool            = syscall.NewLazyDLL("winspool.drv")
	pGetDefaultPrinterW = winspool.NewProc("GetDefaultPrinterW")
	pEnumPrintersW      = winspool.NewProc("EnumPrintersW")
	pOpenPrinterW       = winspool.NewProc("OpenPrinterW")
	pClosePrinter       = winspool.NewProc("ClosePrinter")
	pStartDocPrinterW   = winspool.NewProc("StartDocPrinterW")
	pEndDocPrinter      = winspool.NewProc("EndDocPrinter")
	pStartPagePrinter   = winspool.NewProc("StartPagePrinter")
	pEndPagePrinter     = winspool.NewProc("EndPagePrinter")
	pWritePrinter       = winspool.NewProc("WritePrinter")
)

func impresoraPredeterminada() string {
	var n uint32 = 0
	pGetDefaultPrinterW.Call(0, uintptr(unsafe.Pointer(&n)))
	if n == 0 {
		return ""
	}
	buf := make([]uint16, n)
	r, _, _ := pGetDefaultPrinterW.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&n)))
	if r == 0 {
		return ""
	}
	return syscall.UTF16ToString(buf)
}

type printerInfo4 struct {
	Nombre    *uint16
	Servidor  *uint16
	Atributos uint32
}

func listarImpresoras() []string {
	const flags = 2 | 4 // PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS
	var necesita, cuantos uint32
	pEnumPrintersW.Call(flags, 0, 4, 0, 0, uintptr(unsafe.Pointer(&necesita)), uintptr(unsafe.Pointer(&cuantos)))
	if necesita == 0 {
		return []string{}
	}
	buf := make([]byte, necesita)
	r, _, _ := pEnumPrintersW.Call(flags, 0, 4, uintptr(unsafe.Pointer(&buf[0])), uintptr(necesita), uintptr(unsafe.Pointer(&necesita)), uintptr(unsafe.Pointer(&cuantos)))
	if r == 0 {
		return []string{}
	}
	out := []string{}
	tam := unsafe.Sizeof(printerInfo4{})
	for i := uint32(0); i < cuantos; i++ {
		pi := (*printerInfo4)(unsafe.Pointer(&buf[uintptr(i)*tam]))
		if pi.Nombre != nil {
			out = append(out, utf16Ptr(pi.Nombre))
		}
	}
	return out
}

func utf16Ptr(p *uint16) string {
	if p == nil {
		return ""
	}
	s := []uint16{}
	for ptr := unsafe.Pointer(p); ; ptr = unsafe.Pointer(uintptr(ptr) + 2) {
		c := *(*uint16)(ptr)
		if c == 0 {
			break
		}
		s = append(s, c)
	}
	return syscall.UTF16ToString(s)
}

type docInfo1 struct {
	Doc    *uint16
	Salida *uint16
	Tipo   *uint16
}

func rawImprimir(nombre string, datos []byte) error { return imprimirDatos(nombre, datos, "RAW") }

func imprimirDatos(nombre string, datos []byte, tipoDatos string) error {
	n, _ := syscall.UTF16PtrFromString(nombre)
	var h syscall.Handle
	if r, _, e := pOpenPrinterW.Call(uintptr(unsafe.Pointer(n)), uintptr(unsafe.Pointer(&h)), 0); r == 0 {
		return errors.New("no se pudo abrir la impresora: " + e.Error())
	}
	defer pClosePrinter.Call(uintptr(h))
	doc, _ := syscall.UTF16PtrFromString("Ticket REFRIMAR")
	tipo, _ := syscall.UTF16PtrFromString(tipoDatos)
	di := docInfo1{Doc: doc, Tipo: tipo}
	if r, _, e := pStartDocPrinterW.Call(uintptr(h), 1, uintptr(unsafe.Pointer(&di))); r == 0 {
		return errors.New("no se pudo iniciar el documento: " + e.Error())
	}
	defer pEndDocPrinter.Call(uintptr(h))
	pStartPagePrinter.Call(uintptr(h))
	var escritos uint32
	r, _, e := pWritePrinter.Call(uintptr(h), uintptr(unsafe.Pointer(&datos[0])), uintptr(len(datos)), uintptr(unsafe.Pointer(&escritos)))
	pEndPagePrinter.Call(uintptr(h))
	if r == 0 {
		return errors.New("la impresora no recibió los datos: " + e.Error())
	}
	return nil
}
