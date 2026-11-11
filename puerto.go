package main

import "time"

type Puerto interface {
	Write([]byte) (int, error)
	Leer(max int, espera time.Duration) ([]byte, error)
	Purgar()
	Close() error
}
