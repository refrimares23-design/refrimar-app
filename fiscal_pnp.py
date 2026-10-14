# fiscal_pnp.py — Impresoras fiscales DESARROLLOS PNP (PF-220, PF-300, PF-950, DT-230…)
# Protocolo oficial PNP v5.4 (desarrollospnp.com/archivos/PROTOCOLO0141.pdf) y ejemplos
# del fabricante (github.com/digiua/TestPnP):
#   Trama: STX + secuencia + comando + [FS + campo]... + ETX + BCC (4 hex = suma STX..ETX)
#   Puerto: 9600 baudios, 8 bits, sin paridad, 1 stop (USB aparece como un puerto COM)
#   Abrir factura   @ | razón social | RIF
#   Renglón         B | descripción | cantidad(3 dec sin punto) | precio(2 dec sin punto) | tasa(1600=16%) | M
#   Texto fiscal    A | texto (máx. 3 líneas seguidas)
#   Cerrar          E | T          (con IGTF: E | U | monto en divisa en céntimos)
#   Nota de crédito @ | razón | RIF | n° factura | serial máquina | DDMMAAAA | HHMMSS | D
#   Reporte X / Z   9 | X | T   /   9 | Z | T
#   Gaveta          {
#   Estado          8 | N        Seriales: 0x80
# El puerto COM se busca solo. Todo se puede ajustar en impresora_fiscal.json.
import json, os, re, time, threading, unicodedata, datetime

CARPETA = os.path.dirname(os.path.abspath(__file__))
RUTA_CFG = os.path.join(CARPETA, 'impresora_fiscal.json')
RUTA_LOG = os.path.join(CARPETA, 'fiscal_log.txt')
RUTA_SIM = os.path.join(CARPETA, 'fiscal_simulado.json')
LOCK = threading.Lock()
STX, ETX, FS, ESPERA = 0x02, 0x03, 0x1C, 0x12

CFG_BASE = {
    'marca': 'pnp',                 # pnp | hka (Bixolon / The Factory)
    'modelo': 'Impresora fiscal PNP',
    'puerto': 'AUTO',               # AUTO = lo busca solo; o COM3, COM5…
    'puerto_detectado': '',
    'baudios': 9600,
    'tasas': {'0': '0000', '16': '1600', '8': '0800', '31': '3100'},
    'largo_descripcion': 20,
    'largo_razon': 38,
    'largo_rif': 12,
    'cmd_reporte_x': '9|X|T',
    'cmd_reporte_z': '9|Z|T',
    'cmd_gaveta': '{',
    'cmd_estado': '8|N',
    'cmd_serial': '\x80',
    'imprimir_pagos': True,          # líneas de texto con los métodos de pago
    'igtf': False,                   # True = la impresora agrega IGTF 3% a lo pagado en divisas
    'timeout_s': 4,
    'simular': False,
}

# ---------------------------------------------------------------- config / log
def cfg():
    c = dict(CFG_BASE)
    try:
        with open(RUTA_CFG, encoding='utf-8') as f:
            c.update(json.load(f))
    except FileNotFoundError:
        guardar_cfg(c)
    except Exception:
        pass
    return c

def guardar_cfg(c):
    try:
        with open(RUTA_CFG, 'w', encoding='utf-8') as f:
            json.dump(c, f, ensure_ascii=False, indent=2)
    except Exception:
        pass

def log(txt):
    try:
        if os.path.exists(RUTA_LOG) and os.path.getsize(RUTA_LOG) > 2_000_000:
            os.replace(RUTA_LOG, RUTA_LOG + '.1')
        with open(RUTA_LOG, 'a', encoding='utf-8') as f:
            f.write(datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S ') + txt + '\n')
    except Exception:
        pass

# ---------------------------------------------------------------- formato
def texto(s, largo):
    s = unicodedata.normalize('NFKD', str(s or '')).replace('⁄', '/').encode('ascii', 'ignore').decode('ascii')
    s = re.sub(r'[^\x20-\x7E]', '', s).replace('|', '/').strip()
    return s[:largo]

def sin_punto(v, dec):
    return str(int(round(abs(float(v or 0)) * (10 ** dec))))

def clave_tasa(iva):
    try:
        x = float(iva or 0)
    except Exception:
        x = 0
    return str(int(x)) if abs(x - int(x)) < 1e-9 else str(x)

def fecha_local(iso):
    try:
        d = datetime.datetime.fromisoformat(str(iso).replace('Z', '+00:00'))
        if d.tzinfo:
            d = d.astimezone()
        return d
    except Exception:
        return datetime.datetime.now()

NOMBRE_METODO = {'efectivo': 'Efectivo Bs', 'divisa': 'Efectivo $', 'pago_movil': 'Pago movil', 'punto': 'Debito',
                 'transferencia': 'Transferencia', 'zelle': 'Zelle', 'binance': 'Binance', 'otro': 'Otro', 'credito': 'Credito'}
MET_DIVISA = ('divisa', 'zelle', 'binance', 'otro')

def comandos_documento(d, c, nota_credito=False):
    cli = d.get('cliente') or {}
    razon = texto(cli.get('nombre') or 'CONSUMIDOR FINAL', int(c['largo_razon'])).upper()
    rif = texto(cli.get('rif') or '', int(c['largo_rif'])).replace(' ', '').upper()
    cmds = []
    if nota_credito:
        fac = re.sub(r'\D', '', str(d.get('factura_afectada') or ''))
        if not fac:
            raise ValueError('La nota de crédito fiscal necesita el número fiscal de la factura')
        serial = texto(d.get('factura_serial') or c.get('serial') or '', 12)
        f = fecha_local(d.get('factura_fecha'))
        cmds.append('|'.join(['@', razon, rif, fac.rjust(8, '0'), serial, f.strftime('%d%m%Y'), f.strftime('%H%M%S'), 'D']))
    else:
        cmds.append('|'.join(['@', razon, rif]))
    items = [i for i in (d.get('items') or []) if float(i.get('cantidad') or 0) > 0]
    if not items:
        raise ValueError('El documento no tiene productos')
    for it in items:
        k = clave_tasa(it.get('iva'))
        if k not in c['tasas']:
            raise ValueError('La tasa de IVA %s%% no está programada (impresora_fiscal.json)' % k)
        cmds.append('|'.join(['B', texto(it.get('descripcion'), int(c['largo_descripcion'])) or 'PRODUCTO',
                              sin_punto(it.get('cantidad'), 3), sin_punto(it.get('precio'), 2), c['tasas'][k], 'M']))
    # Hasta 3 líneas de texto fiscal: referencia y pagos
    lineas = []
    if d.get('numero_interno'):
        lineas.append(texto('Ref %s Caj %s' % (d.get('numero_interno'), d.get('cajero') or ''), 40))
    if c.get('imprimir_pagos') and not nota_credito:
        pg = ['%s %s' % (NOMBRE_METODO.get(p.get('metodo'), p.get('metodo') or 'Pago'), ('%.2f' % float(p.get('monto') or 0)).replace('.', ','))
              for p in (d.get('pagos') or []) if float(p.get('monto') or 0) > 0]
        actual = ''
        for x in pg:
            if len(actual) + len(x) + 3 > 40:
                lineas.append(actual); actual = ''
            actual = (actual + ' / ' + x) if actual else x
        if actual:
            lineas.append(actual)
    for l in lineas[:3]:
        cmds.append('A|' + texto(l, 40))
    # Cierre (IGTF opcional sobre lo pagado en divisas, en Bs y céntimos)
    divisa_bs = sum(float(p.get('monto') or 0) for p in (d.get('pagos') or []) if p.get('metodo') in MET_DIVISA)
    if c.get('igtf') and divisa_bs > 0 and not nota_credito:
        cmds.append('E|U|' + sin_punto(divisa_bs, 2))
    else:
        cmds.append('E|T')
    return cmds

# ---------------------------------------------------------------- transporte serial
class Pnp:
    def __init__(self, puerto, c):
        import serial
        self.serial = serial
        self.c = c
        self.puerto = puerto
        self.p = serial.Serial(puerto, int(c['baudios']), bytesize=8, parity=serial.PARITY_NONE, stopbits=1,
                               timeout=0.3, write_timeout=3, xonxoff=False, rtscts=False)
        self.sec = 0x20

    def cerrar(self):
        try: self.p.close()
        except Exception: pass

    def trama(self, cmd):
        self.sec = 0x20 if self.sec >= 0x7F else self.sec + 1
        partes = cmd.split('|')
        datos = bytes([STX, self.sec]) + partes[0].encode('latin-1')
        for campo in partes[1:]:
            datos += bytes([FS]) + campo.encode('latin-1')
        datos += bytes([ETX])
        return datos + ('%04X' % (sum(datos) & 0xFFFF)).encode('ascii')

    def enviar(self, cmd, espera=None):
        """Devuelve (ok, campos, crudo). campos[0]=estado impresora, [1]=estado fiscal, [2..]=datos."""
        limite = time.time() + float(espera or self.c['timeout_s'])
        self.p.reset_input_buffer()
        self.p.write(self.trama(cmd))
        buf = bytearray()
        while time.time() < limite:
            b = self.p.read(64)
            if b:
                if ESPERA in b:
                    limite += 0.8
                    b = bytes(x for x in b if x != ESPERA)
                buf += b
                if ETX in buf:
                    fin = buf.index(ETX)
                    t0 = time.time()
                    while len(buf) < fin + 5 and time.time() - t0 < 0.5:
                        buf += self.p.read(5)
                    break
        crudo = bytes(buf)
        log('PNP > %r  <  %r' % (cmd, crudo[:200]))
        if STX not in crudo or ETX not in crudo:
            return False, [], crudo
        cuerpo = crudo[crudo.index(STX) + 1: crudo.index(ETX)].decode('latin-1', 'replace')
        campos = cuerpo.split('\x1c')[1:]
        ok = 'ERROR' not in cuerpo.upper()
        return ok, campos, crudo

class Simulada:
    puerto = 'SIMULADA'
    def __init__(self, c): self.c = c
    def cerrar(self): pass
    def _e(self):
        try:
            with open(RUTA_SIM, encoding='utf-8') as f: return json.load(f)
        except Exception: return {'factura': 0, 'nc': 0, 'z': 0}
    def enviar(self, cmd, espera=None):
        log('SIM > ' + repr(cmd))
        e = self._e()
        if cmd.startswith('@'):
            e['abierta'] = 'nc' if cmd.endswith('|D') else 'factura'
        if cmd.startswith('E|') and e.get('abierta'):
            e[e['abierta']] += 1; tipo = e.pop('abierta')
            with open(RUTA_SIM, 'w', encoding='utf-8') as f: json.dump(e, f)
            return True, ['0080', '0000', '1', str(e['factura']).rjust(8, '0'), str(e['nc']).rjust(8, '0'), '0'], b''
        if cmd.startswith('9|Z'):
            e['z'] += 1
        with open(RUTA_SIM, 'w', encoding='utf-8') as f: json.dump(e, f)
        if cmd == '\x80':
            return True, ['0080', '0000', 'SIM0000001'], b''
        if cmd.startswith('8'):
            return True, ['0080', '0000', '30', '00', '45', time.strftime('%y%m%d'), time.strftime('%H%M%S'),
                          str(e['factura']), '0', str(e['factura']).rjust(8, '0'), '0', str(e['z']).rjust(4, '0')], b''
        return True, ['0080', '0000'], b''

# ---------------------------------------------------------------- detección de puerto
def puertos_candidatos():
    try:
        from serial.tools import list_ports
        l = list(list_ports.comports())
    except Exception:
        return []
    def prioridad(p):
        txt = ('%s %s %s' % (p.device, p.description, p.hwid)).lower()
        if 'bluetooth' in txt: return 9
        if any(k in txt for k in ('pnp', 'fiscal')): return 0
        if any(k in txt for k in ('usb', 'ch340', 'prolific', 'ftdi', 'cp210', 'serial')): return 1
        return 5
    return [p.device for p in sorted(l, key=prioridad)]

def responde(puerto, c):
    try:
        t = Pnp(puerto, c)
    except Exception:
        return False
    try:
        ok, campos, crudo = t.enviar(c['cmd_estado'], 1.5)
        return bool(crudo) and STX in crudo
    finally:
        t.cerrar()

def abrir(c):
    if c.get('simular'):
        return Simulada(c)
    fijo = str(c.get('puerto') or 'AUTO').strip()
    if fijo.upper() != 'AUTO':
        return Pnp(fijo, c)
    previo = c.get('puerto_detectado')
    orden = ([previo] if previo else []) + [p for p in puertos_candidatos() if p != previo]
    for p in orden:
        if responde(p, c):
            if p != previo:
                base = cfg(); base['puerto_detectado'] = p; guardar_cfg(base)
            return Pnp(p, c)
    raise RuntimeError('No se encontró la impresora fiscal PNP. Revisa que esté encendida y con el cable USB conectado.' +
                       (' Puertos vistos: ' + ', '.join(orden) if orden else ' (Windows no muestra ningún puerto COM: falta el cable o el driver USB)'))

def con_impresora(c, fn):
    with LOCK:
        t = abrir(c)
        try:
            return fn(t)
        finally:
            t.cerrar()

# ---------------------------------------------------------------- operaciones
def leer_serial(t, c):
    try:
        ok, campos, crudo = t.enviar(c['cmd_serial'], 2)
        m = re.search(r'\b([A-Z]{2,4}\d{6,8})\b', '|'.join(campos))
        return m.group(1) if m else None
    except Exception:
        return None

def estado(c):
    try:
        def f(t):
            ok, campos, crudo = t.enviar(c['cmd_estado'], 2)
            conectada = bool(campos)
            serial = leer_serial(t, c) if conectada else None
            ultima = campos[9] if len(campos) > 9 and campos[9].strip().isdigit() else None
            return {'ok': True, 'conectada': conectada, 'modelo': c['modelo'], 'puerto': t.puerto, 'marca': 'pnp',
                    'simulada': isinstance(t, Simulada), 'serial': serial, 'ultima_factura': ultima,
                    'requiere_z': len(campos) > 3 and campos[3] in ('04', '08'),
                    'error': None if conectada else 'La impresora no respondió en ' + t.puerto}
        return con_impresora(c, f)
    except Exception as e:
        return {'ok': True, 'conectada': False, 'modelo': c['modelo'], 'puerto': c.get('puerto_detectado') or c.get('puerto'), 'marca': 'pnp', 'error': str(e)}

def documento(c, d, nota_credito=False):
    cmds = comandos_documento(d, c, nota_credito)
    def f(t):
        resp = []
        for cmd in cmds:
            ok, campos, crudo = t.enviar(cmd, 12 if cmd.startswith('E') else None)
            if not ok:
                det = ' '.join(campos[2:]) if len(campos) > 2 else ('sin respuesta' if not crudo else crudo.decode('latin-1', 'replace'))
                extra = '' if cmd.startswith('@') else ' Apaga y enciende la impresora para anular el documento que quedó abierto.'
                return {'ok': False, 'error': 'La impresora fiscal rechazó el paso "%s": %s.%s' % (cmd.split('|')[0], det, extra), 'comando': cmd}
            resp = campos
        numero = None
        if len(resp) > 3:
            numero = resp[4] if nota_credito and len(resp) > 4 and resp[4].strip().isdigit() else resp[3]
        return {'ok': True, 'numero_fiscal': (numero or '').strip() or None, 'serial': leer_serial(t, c), 'comandos': len(cmds)}
    return con_impresora(c, f)

def comando_simple(c, cmd, espera=None, alterno=None):
    def f(t):
        ok, campos, crudo = t.enviar(cmd, espera)
        if not ok and alterno:
            ok, campos, crudo = t.enviar(alterno, espera)
        return {'ok': ok, 'error': None if ok else ('Sin respuesta de la impresora' if not crudo else ' '.join(campos[2:]) or 'Comando rechazado')}
    return con_impresora(c, f)

def resumen():
    c = cfg()
    if c.get('marca') == 'hka':
        import fiscal_hka
        return fiscal_hka.resumen()
    return '%s (%s)' % (c['modelo'], 'simulada' if c.get('simular') else (c.get('puerto_detectado') or 'puerto automático'))

def atender(metodo, ruta, data):
    c = cfg()
    if c.get('marca') == 'hka' and not ruta.startswith('/fiscal/config'):
        import fiscal_hka
        return fiscal_hka.atender(metodo, ruta, data)
    data = data if isinstance(data, dict) else {}
    p = str(data.get('puerto') or '').strip()
    if p and p.upper() != 'AUTO' and not ruta.startswith('/fiscal/config'):
        c['puerto'] = p
    try:
        if ruta.startswith('/fiscal/estado'):
            return 200, estado(c)
        if ruta.startswith('/fiscal/config'):
            if metodo == 'POST':
                base = cfg()
                for k, v in data.items():
                    if k in CFG_BASE:
                        base[k] = (str(v).strip() or 'AUTO') if k == 'puerto' else v
                guardar_cfg(base)
                return 200, {'ok': True, 'config': base}
            return 200, {'ok': True, 'config': c}
        if ruta.startswith('/fiscal/factura'):
            r = documento(c, data, False)
            return (200 if r.get('ok') else 500), r
        if ruta.startswith('/fiscal/nota_credito'):
            r = documento(c, data, True)
            return (200 if r.get('ok') else 500), r
        if ruta.startswith('/fiscal/reporte'):
            z = str(data.get('tipo') or 'X').upper() == 'Z'
            r = comando_simple(c, c['cmd_reporte_z'] if z else c['cmd_reporte_x'], 90, '9|Z' if z else '9|X')
            return (200 if r.get('ok') else 500), r
        if ruta.startswith('/fiscal/gaveta'):
            r = comando_simple(c, c['cmd_gaveta'], 3)
            return (200 if r.get('ok') else 500), r
        if ruta.startswith('/fiscal/comandos'):
            return 200, {'ok': True, 'comandos': comandos_documento(data, c, bool(data.get('nota_credito')))}
    except ValueError as e:
        return 400, {'ok': False, 'error': str(e)}
    except Exception as e:
        log('ERROR %s %s' % (ruta, e))
        return 500, {'ok': False, 'error': str(e)}
    return 404, {'ok': False, 'error': 'Not Found'}
