#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PUENTE DE IMPRESION REFRIMAR -> Impresora termica (ESC/POS RAW)

El navegador NO puede imprimir en silencio a una termica por seguridad.
Este puente local recibe el ticket desde la app (http://localhost:3001)
y lo manda directo a la impresora por comandos RAW. Sin dialogo alguno.

INSTALACION (Windows, una sola vez por PC de caja):
  1) Instala Python 3 desde https://python.org  (marca "Add Python to PATH").
  2) Abre CMD y ejecuta:  pip install pywin32
  3) Conecta la impresora termica por USB e instala su driver (la app
     la usa como "impresora predeterminada" de Windows).
  4) Ejecuta:  python imprimir_tickets.py
     Deja esta ventana abierta mientras atiendas caja.

Si las letras con acento salen raras, cambia CODEPAGE a 'cp850' o 'latin-1'.
Si el ticket sale muy ancho/angosto, cambia la configuracion de ancho
desde REFRIMAR -> Configuracion -> Impresion de Tickets (80/58 mm).
"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    import win32print
except ImportError:
    win32print = None

PUERTO = 3001
CODEPAGE = 'cp850'
DEFAULT_WIDTH = 42


def _escpos(texto):
    out = bytearray()
    out += b'\x1b@'                      # ESC @  -> inicializar impresora
    for linea in texto.split('\n'):
        out += linea.encode(CODEPAGE, errors='replace')
        out += b'\n'
    out += b'\n\n\n'                     # espacio al final antes de cortar
    out += b'\x1dVa\x00'                 # GS V A 0 -> corte de papel (full)
    return bytes(out)


def imprimir(texto, printer_name=None):
    if win32print is None:
        return False, 'pywin32 no instalado. Ejecuta: pip install pywin32'
    try:
        nombre = printer_name or win32print.GetDefaultPrinter()
    except Exception as e:
        return False, 'Sin impresora predeterminada: %s' % e
    try:
        ph = win32print.OpenPrinter(nombre)
        try:
            win32print.StartDocPrinter(ph, 1, ('Ticket REFRIMAR', None, 'RAW'))
            win32print.StartPagePrinter(ph)
            win32print.WritePrinter(ph, _escpos(texto))
            win32print.EndPagePrinter(ph)
            win32print.EndDocPrinter(ph)
        finally:
            win32print.ClosePrinter(ph)
        return True, 'Impreso en: %s' % nombre
    except Exception as e:
        return False, 'Error al imprimir: %s' % e


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        if self.path.startswith('/health'):
            info = {'ok': True, 'server': 'refrimar-print-bridge', 'printer': None}
            if win32print is None:
                info['ok'] = False
                info['error'] = 'pywin32 no instalado. Ejecuta: pip install pywin32'
            else:
                try:
                    info['printer'] = win32print.GetDefaultPrinter()
                except Exception as e:
                    info['printer'] = None
                    info['error'] = 'Sin impresora predeterminada: %s' % e
            self._json(200 if info['ok'] else 500, info)
            return
        self._json(404, {'ok': False, 'error': 'Not Found'})

    def do_POST(self):
        if not self.path.startswith('/print'):
            self._json(404, {'ok': False, 'error': 'Not Found'})
            return
        try:
            length = int(self.headers.get('Content-Length') or 0)
            raw = self.rfile.read(length)
            try:
                data = json.loads(raw.decode('utf-8'))
            except Exception:
                data = {}
            texto = data.get('text') or 'REFRIMAR'
            printer_name = data.get('printer') or None
            ok, msg = imprimir(texto, printer_name)
            self._json(200 if ok else 500, {'ok': ok, 'message': msg})
        except Exception as e:
            self._json(500, {'ok': False, 'error': str(e)})

    def log_message(self, *args):
        pass


def main():
    print('=' * 56)
    print('  PUENTE DE IMPRESION REFRIMAR (ESC/POS RAW)')
    print('  Escuchando en: http://localhost:%d' % PUERTO)
    if win32print is None:
        print('  OJO: falta pywin32. Ejecuta:  pip install pywin32')
        print('  El puente NO podra imprimir hasta instalarlo.')
    else:
        try:
            print('  Impresora predeterminada: %s' % win32print.GetDefaultPrinter())
        except Exception as e:
            print('  OJO: %s' % e)
    print('  Deja esta ventana abierta mientras atiendes caja.')
    print('  Cierra con Ctrl+C.')
    print('=' * 56)
    try:
        server = ThreadingHTTPServer(('127.0.0.1', PUERTO), Handler)
    except OSError as e:
        print('No se pudo abrir el puerto %d (%s).' % (PUERTO, e))
        print('Revisa que el puente no este ya abierto o cierra el programa que lo use.')
        return
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nPuente detenido.')


if __name__ == '__main__':
    main()
