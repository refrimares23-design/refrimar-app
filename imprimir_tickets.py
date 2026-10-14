# imprimir_tickets.py — versión PNP
# Puente local REFRIMAR -> impresora térmica (ESC/POS RAW) en localhost:3001
#   GET  /health    -> impresora detectada
#   GET  /printers  -> lista de impresoras
#   POST /print     -> {"text": "...", "printer": opcional, "drawer": opcional}
#   POST /drawer    -> abre el cajón monedero (sin imprimir ni cortar)
# Impresora FISCAL PNP (PF-220, PF-300…) por USB, puerto COM automático.
# También HKA / The Factory (Bixolon) poniendo "marca": "hka" en impresora_fiscal.json:
#   GET  /fiscal/estado        -> conectada, serial, última factura
#   GET/POST /fiscal/config    -> puerto, tasas (impresora_fiscal.json)
#   POST /fiscal/factura       -> imprime la factura fiscal y devuelve el número fiscal
#   POST /fiscal/nota_credito  -> nota de crédito fiscal
#   POST /fiscal/reporte       -> {"tipo": "X"} o {"tipo": "Z"}
#   POST /fiscal/gaveta        -> abre la gaveta conectada a la fiscal
# Instalación: doble clic en INICIAR_PUENTE.bat
import json
import fiscal_pnp as fiscal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
try:
    import win32print
except ImportError:
    win32print = None

PUERTO = 3001
CODEPAGE = 'cp850'
PALABRAS_TERMICA = ('termica', 'thermal', '80mm', '58mm', 'pos', 'ticket', 'epson tm', 'xprinter')
PULSO_CAJON = b'\x1bp\x00\x19\xFA'          # pulso cajón monedero

def _escpos(texto, cortar=True, cajon=False):
    out = bytearray(b'\x1b@')
    for linea in texto.split('\n'):
        out += linea.encode(CODEPAGE, errors='replace') + b'\n'
    out += b'\n\n\n'
    if cajon:
        out += PULSO_CAJON
    if cortar:
        out += b'\x1dV\x00'                  # GS V 0 (corte full, más estándar)
    return bytes(out)

def detectar_impresora():
    """Usa la predeterminada; si no hay, busca una térmica por nombre."""
    if win32print is None:
        return None
    try:
        return win32print.GetDefaultPrinter()
    except Exception:
        pass
    try:
        for n in win32print.EnumPrinters(2):
            nombre = n[2].lower()
            if any(p in nombre for p in PALABRAS_TERMICA):
                return n[2]
    except Exception:
        pass
    return None

def _enviar_raw(datos, printer_name=None):
    if win32print is None:
        return False, 'pywin32 no instalado: pip install pywin32'
    nombre = printer_name or detectar_impresora()
    if not nombre:
        return False, 'No hay impresora conectada. Enciéndela y vuelve a imprimir.'
    try:
        ph = win32print.OpenPrinter(nombre)
        try:
            win32print.StartDocPrinter(ph, 1, ('Ticket REFRIMAR', None, 'RAW'))
            win32print.StartPagePrinter(ph)
            win32print.WritePrinter(ph, datos)
            win32print.EndPagePrinter(ph)
            win32print.EndDocPrinter(ph)
        finally:
            win32print.ClosePrinter(ph)
        return True, 'Impreso en: ' + nombre
    except Exception as e:
        return False, 'Error: %s' % e

def imprimir(texto, printer_name=None, cajon=False):
    return _enviar_raw(_escpos(texto, cajon=cajon), printer_name)

def abrir_cajon(printer_name=None):
    # Solo inicializar + pulso: no avanza papel ni corta.
    return _enviar_raw(b'\x1b@' + PULSO_CAJON, printer_name)

class Handler(BaseHTTPRequestHandler):
    def _json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        for h in [('Content-Type','application/json; charset=utf-8'),
                  ('Content-Length',str(len(body))),
                  ('Access-Control-Allow-Origin','*'),
                  ('Access-Control-Allow-Methods','GET, POST, OPTIONS'),
                  ('Access-Control-Allow-Headers','Content-Type'),
                  ('Access-Control-Allow-Private-Network','true')]:
            self.send_header(*h)
        self.end_headers()
        self.wfile.write(body)
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin','*')
        self.send_header('Access-Control-Allow-Methods','GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers','Content-Type')
        self.send_header('Access-Control-Allow-Private-Network','true')
        self.send_header('Content-Length','0')
        self.end_headers()
    def do_GET(self):
        if self.path.startswith('/fiscal/'):
            code, payload = fiscal.atender('GET', self.path, {})
            self._json(code, payload)
            return
        if self.path.startswith('/health'):
            imp = detectar_impresora()
            self._json(200 if imp else 500,
                {'ok': bool(imp), 'printer': imp,
                 'error': None if imp else 'Sin impresora detectada. Conéctala y reintenta.'})
            return
        if self.path.startswith('/printers'):
            try:
                lista = [p[2] for p in win32print.EnumPrinters(2)]
            except Exception:
                lista = []
            self._json(200, {'ok': True, 'printers': lista})
            return
        self._json(404, {'ok': False, 'error': 'Not Found'})
    def _leer_json(self):
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n).decode('utf-8') if n else ''
        return json.loads(raw or '{}')
    def do_POST(self):
        if self.path.startswith('/fiscal/'):
            try:
                data = self._leer_json()
            except Exception:
                data = {}
            code, payload = fiscal.atender('POST', self.path, data)
            self._json(code, payload)
            return
        if self.path.startswith('/print'):
            try:
                data = self._leer_json()
                ok, msg = imprimir(data.get('text') or 'REFRIMAR', data.get('printer'), bool(data.get('drawer')))
                self._json(200 if ok else 500, {'ok': ok, 'message': msg})
            except Exception as e:
                self._json(500, {'ok': False, 'error': str(e)})
            return
        if self.path.startswith('/drawer'):
            try:
                data = self._leer_json()
            except Exception:
                data = {}
            ok, msg = abrir_cajon(data.get('printer'))
            self._json(200 if ok else 500, {'ok': ok, 'message': msg})
            return
        self._json(404, {'ok': False, 'error': 'Not Found'})
    def log_message(self, *a): pass

if __name__ == '__main__':
    print('=' * 50)
    print('  PUENTE REFRIMAR — impresora PNP lista en localhost:%d' % PUERTO)
    print('  Enciende/conecta la térmica: se detecta sola.')
    print('  Impresora fiscal: ' + fiscal.resumen())
    print('=' * 50)
    try:
        ThreadingHTTPServer(('127.0.0.1', PUERTO), Handler).serve_forever()
    except OSError as e:
        print('Puerto ocupado (%s). El puente ya está corriendo.' % e)
