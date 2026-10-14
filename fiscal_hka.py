# fiscal_hka.py — Impresoras fiscales venezolanas protocolo HKA / The Factory (TFHKA)
# Bixolon SRP-812 / SRP-350, HKA80, HKA112, Aclas PP9, Dascom, Okidata ML1120…
#
# Dos formas de hablar con la impresora (se elige sola):
#   1) tfhkaif.dll (la DLL oficial de The Factory) si está en esta carpeta o en Windows\System32
#   2) Puerto serial directo con pyserial (STX + datos + ETX + LRC, espera ACK 06h)
# Modo "simulado": no necesita impresora; escribe los comandos en fiscal_log.txt (para probar).
#
# Todo lo que cambia entre modelos (tasas, comandos, formato de montos, códigos de pago)
# está en fiscal_config.json, que se crea solo la primera vez.
import json, os, re, time, threading, unicodedata, datetime, ctypes

CARPETA = os.path.dirname(os.path.abspath(__file__))
RUTA_CFG = os.path.join(CARPETA, 'fiscal_config.json')
RUTA_LOG = os.path.join(CARPETA, 'fiscal_log.txt')
RUTA_SIM = os.path.join(CARPETA, 'fiscal_simulado.json')
LOCK = threading.Lock()

STX, ETX, ACK, NAK, ENQ = b'\x02', b'\x03', b'\x06', b'\x15', b'\x05'

CFG_BASE = {
    'puerto': 'COM1',
    'baudios': 9600,
    'paridad': 'E',                 # E = par (estándar HKA)
    'modelo': 'Impresora fiscal HKA',
    'transporte': 'auto',           # auto | dll | serial | simulado
    'dll': 'tfhkaif.dll',
    # Caracter de tasa por % de IVA (factura) — deben coincidir con las tasas programadas
    'tasas': {'0': ' ', '16': '!', '8': '"', '31': '#'},
    # Prefijo de ítem para nota de crédito
    'tasas_nc': {'0': 'd0', '16': 'd1', '8': 'd2', '31': 'd3'},
    # Formato de montos: precio 8 enteros + 2 decimales, cantidad 5 + 3 (modelos con flag 21 = 00)
    'precio_enteros': 8, 'precio_decimales': 2,
    'cantidad_enteros': 5, 'cantidad_decimales': 3,
    'pago_enteros': 10, 'pago_decimales': 2,
    'largo_descripcion': 40,
    'cmd_cliente_rif': 'iR*',
    'cmd_cliente_nombre': 'iS*',
    'cmd_comentario': '@',
    'cmd_nc_factura': 'iF*',
    'cmd_nc_fecha': 'iD*',
    'cmd_nc_serial': 'iI*',
    'formato_fecha_nc': '%d/%m/%Y',
    'digitos_factura_nc': 11,
    'cmd_pago_total': '1',          # 1 + código 2 dígitos  -> paga el resto y cierra
    'cmd_pago_parcial': '2',        # 2 + código + monto     -> pago parcial
    'cmd_reporte_x': 'I0X',
    'cmd_reporte_z': 'I0Z',
    'cmd_gaveta': '0',
    'cmd_anular': '7',              # anula el documento abierto si algo falla a mitad
    'imprimir_referencia': True,    # línea "@Ref: F-1234567 Cajero: X"
    # Posiciones dentro de la respuesta S1 (varían por modelo; si fallan se busca por patrón)
    's1_ultima_factura': [21, 29],
    's1_ultima_nc': [55, 63],
    'timeout_s': 6,
    'simular': False,
}

# ---------------------------------------------------------------- configuración
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
        with open(RUTA_LOG, 'a', encoding='utf-8') as f:
            f.write(datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S ') + txt + '\n')
    except Exception:
        pass

# ---------------------------------------------------------------- formato de comandos
def ascii_txt(s, largo=None):
    s = unicodedata.normalize('NFKD', str(s or '')).replace('\u2044', '/').encode('ascii', 'ignore').decode('ascii')
    s = re.sub(r'[^\x20-\x7E]', '', s).strip()
    return s[:largo] if largo else s

def monto(v, enteros, decimales):
    n = int(round(abs(float(v or 0)) * (10 ** decimales)))
    txt = str(n).rjust(enteros + decimales, '0')
    if len(txt) > enteros + decimales:
        raise ValueError('Monto demasiado grande para la impresora: %s' % v)
    return txt

def clave_tasa(iva):
    try:
        x = float(iva or 0)
    except Exception:
        x = 0
    return str(int(x)) if abs(x - int(x)) < 1e-9 else str(x)

def comandos_documento(d, c, nota_credito=False):
    """Lista de comandos HKA para una factura o nota de crédito."""
    cmds = []
    cli = d.get('cliente') or {}
    rif = ascii_txt(cli.get('rif') or '', 16).replace('-', '').replace(' ', '').upper()
    nombre = ascii_txt(cli.get('nombre') or 'CONSUMIDOR FINAL', 40).upper()
    if rif:
        cmds.append(c['cmd_cliente_rif'] + rif)
    cmds.append(c['cmd_cliente_nombre'] + nombre)
    if nota_credito:
        fac = re.sub(r'\D', '', str(d.get('factura_afectada') or ''))
        if not fac:
            raise ValueError('La nota de crédito fiscal necesita el número fiscal de la factura')
        cmds.append(c['cmd_nc_factura'] + fac.rjust(int(c['digitos_factura_nc']), '0'))
        fecha = d.get('factura_fecha')
        try:
            f = datetime.datetime.fromisoformat(str(fecha).replace('Z', '+00:00')[:19]) if fecha else datetime.datetime.now()
        except Exception:
            f = datetime.datetime.now()
        cmds.append(c['cmd_nc_fecha'] + f.strftime(c['formato_fecha_nc']))
        if d.get('factura_serial') and c.get('cmd_nc_serial'):
            cmds.append(c['cmd_nc_serial'] + ascii_txt(d['factura_serial'], 12))
    if c.get('imprimir_referencia') and d.get('numero_interno'):
        cmds.append(c['cmd_comentario'] + ascii_txt('Ref: %s  Cajero: %s' % (d.get('numero_interno'), d.get('cajero') or ''), 40))
    total = 0.0
    tabla = c['tasas_nc'] if nota_credito else c['tasas']
    items = d.get('items') or []
    if not items:
        raise ValueError('El documento no tiene productos')
    for it in items:
        k = clave_tasa(it.get('iva'))
        if k not in tabla:
            raise ValueError('La tasa de IVA %s%% no está configurada en fiscal_config.json' % k)
        precio = float(it.get('precio') or 0)
        cant = float(it.get('cantidad') or 0)
        if cant <= 0:
            continue
        cmds.append(tabla[k] + monto(precio, c['precio_enteros'], c['precio_decimales']) +
                    monto(cant, c['cantidad_enteros'], c['cantidad_decimales']) +
                    ascii_txt(it.get('descripcion'), int(c['largo_descripcion'])))
        total += round(precio * cant, 2) * (1 + float(it.get('iva') or 0) / 100.0)
    # Pagos: parciales mientras no cubran el total; el último cierra con "pago total"
    pagos = [p for p in (d.get('pagos') or []) if float(p.get('monto') or 0) > 0]
    if not pagos:
        pagos = [{'codigo': '01', 'monto': total}]
    acum = 0.0
    for i, p in enumerate(pagos):
        cod = str(p.get('codigo') or '01').rjust(2, '0')[-2:]
        m = float(p.get('monto') or 0)
        ultimo = i == len(pagos) - 1
        if ultimo or acum + m >= total - 0.01:
            cmds.append(c['cmd_pago_total'] + cod)
            break
        cmds.append(c['cmd_pago_parcial'] + cod + monto(m, c['pago_enteros'], c['pago_decimales']))
        acum += m
    return cmds

# ---------------------------------------------------------------- transporte
class Simulado:
    nombre = 'simulado'
    def __init__(self, c): self.c = c
    def abrir(self): return True
    def cerrar(self): pass
    def _estado(self):
        try:
            with open(RUTA_SIM, encoding='utf-8') as f: return json.load(f)
        except Exception: return {'factura': 0, 'nc': 0, 'z': 0}
    def _guardar(self, e):
        with open(RUTA_SIM, 'w', encoding='utf-8') as f: json.dump(e, f)
    def enviar(self, cmd):
        log('SIM > ' + cmd)
        e = self._estado()
        if cmd.startswith(self.c['cmd_pago_total']) and len(cmd) == 3:
            k = 'nc' if getattr(self, 'en_nc', False) else 'factura'
            e[k] += 1; self._guardar(e)
        if cmd == self.c['cmd_reporte_z']:
            e['z'] += 1; self._guardar(e)
        return True, ''
    def s1(self):
        e = self._estado()
        # Respuesta S1 con el mismo formato posicional que la real
        return ('S1' + '01' + '0' * 17 + str(e['factura']).rjust(8, '0') + '00000' + '00000000' + '00000' +
                '00000000' + '00000' + '00000000' + '00000' + str(e['z']).rjust(4, '0') + '0000' + 'J000000000' + 'SIM0000001'
                + time.strftime('%H%M%S%d%m%y')), {'ultima_nc': e['nc']}

class Dll:
    nombre = 'dll'
    def __init__(self, c):
        self.c = c
        ruta = os.path.join(CARPETA, c['dll'])
        self.lib = ctypes.WinDLL(ruta if os.path.exists(ruta) else c['dll'])
        self.lib.OpenFpctrl.argtypes = [ctypes.c_char_p]
        self.lib.SendCmd.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.c_char_p]
        self.lib.UploadStatusCmd.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.c_char_p, ctypes.c_char_p]
    def abrir(self):
        return bool(self.lib.OpenFpctrl(self.c['puerto'].encode('ascii')))
    def cerrar(self):
        try: self.lib.CloseFpctrl()
        except Exception: pass
    def enviar(self, cmd):
        st, err = ctypes.c_int(0), ctypes.c_int(0)
        ok = bool(self.lib.SendCmd(ctypes.byref(st), ctypes.byref(err), cmd.encode('latin-1')))
        log('DLL > %s  ok=%s st=%s err=%s' % (cmd, ok, st.value, err.value))
        return ok, '' if ok else 'La impresora rechazó el comando (estado %s, error %s)' % (st.value, err.value)
    def s1(self):
        st, err = ctypes.c_int(0), ctypes.c_int(0)
        arch = os.path.join(CARPETA, 'fiscal_s1.txt')
        ok = self.lib.UploadStatusCmd(ctypes.byref(st), ctypes.byref(err), b'S1', arch.encode('latin-1'))
        if not ok:
            return None, {}
        with open(arch, encoding='latin-1') as f:
            return f.read().strip(), {}

class Serial:
    nombre = 'serial'
    def __init__(self, c):
        import serial  # pyserial
        self.serial = serial
        self.c = c
        self.p = None
    def abrir(self):
        s = self.serial
        par = {'E': s.PARITY_EVEN, 'N': s.PARITY_NONE, 'O': s.PARITY_ODD}.get(str(self.c['paridad']).upper()[:1], s.PARITY_EVEN)
        self.p = s.Serial(self.c['puerto'], int(self.c['baudios']), bytesize=8, parity=par, stopbits=1, timeout=float(self.c['timeout_s']))
        return True
    def cerrar(self):
        try: self.p.close()
        except Exception: pass
    @staticmethod
    def trama(cmd):
        datos = cmd.encode('latin-1')
        lrc = 0
        for b in datos + ETX:
            lrc ^= b
        return STX + datos + ETX + bytes([lrc])
    def _leer_trama(self):
        b = self.p.read(1)
        if b != STX:
            return b, None
        datos = bytearray()
        while True:
            x = self.p.read(1)
            if not x:
                return STX, None
            if x == ETX:
                break
            datos += x
        self.p.read(1)  # LRC
        self.p.write(ACK)
        return STX, datos.decode('latin-1')
    def enviar(self, cmd, intentos=3):
        for _ in range(intentos):
            self.p.reset_input_buffer()
            self.p.write(self.trama(cmd))
            r = self.p.read(1)
            log('SER > %s  resp=%r' % (cmd, r))
            if r == ACK:
                return True, ''
            if r == NAK:
                return False, 'La impresora rechazó el comando ' + cmd[:6]
            time.sleep(0.4)
        return False, 'La impresora no responde en ' + self.c['puerto']
    def s1(self):
        self.p.reset_input_buffer()
        self.p.write(self.trama('S1'))
        primero, datos = self._leer_trama()
        if primero == ACK:
            primero, datos = self._leer_trama()
        return datos, {}

def transporte(c):
    t = 'simulado' if c.get('simular') else str(c.get('transporte') or 'auto').lower()
    if t == 'simulado':
        return Simulado(c)
    errores = []
    if t in ('auto', 'dll') and os.name == 'nt':
        try:
            return Dll(c)
        except Exception as e:
            errores.append('DLL: %s' % e)
    if t in ('auto', 'serial'):
        try:
            return Serial(c)
        except ImportError:
            errores.append('Falta pyserial (pip install pyserial)')
        except Exception as e:
            errores.append('Serial: %s' % e)
    raise RuntimeError('; '.join(errores) or 'Sin forma de conectar a la impresora fiscal')

# ---------------------------------------------------------------- operaciones
def leer_s1(t, c):
    try:
        txt, extra = t.s1()
    except Exception as e:
        log('S1 error %s' % e)
        return {}
    if not txt:
        return {}
    r = {'s1': txt}
    a, b = c['s1_ultima_factura']
    if len(txt) >= b and txt[a:b].isdigit():
        r['ultima_factura'] = txt[a:b]
    a, b = c['s1_ultima_nc']
    if len(txt) >= b and txt[a:b].isdigit():
        r['ultima_nc'] = txt[a:b]
    if 'ultima_nc' in extra:
        r['ultima_nc'] = str(extra['ultima_nc']).rjust(8, '0')
    m = re.search(r'([JVGEP]\d{9})([A-Z0-9]{10})', txt)
    if m:
        r['rif'], r['serial'] = m.group(1), m.group(2)
    return r

def con_impresora(c, fn):
    with LOCK:
        t = transporte(c)
        if not t.abrir():
            raise RuntimeError('No se pudo abrir el puerto %s. ¿Está encendida y conectada la impresora?' % c['puerto'])
        try:
            return fn(t)
        finally:
            t.cerrar()

def estado(c):
    try:
        def f(t):
            r = leer_s1(t, c)
            ok = bool(r) or t.nombre == 'simulado'
            return {'ok': True, 'conectada': ok, 'modelo': c['modelo'], 'puerto': c['puerto'], 'transporte': t.nombre,
                    'simulada': t.nombre == 'simulado', 'serial': r.get('serial'), 'rif': r.get('rif'),
                    'ultima_factura': r.get('ultima_factura'), 'ultima_nc': r.get('ultima_nc'),
                    'error': None if ok else 'La impresora no respondió el estado (S1) en ' + c['puerto']}
        return con_impresora(c, f)
    except Exception as e:
        return {'ok': True, 'conectada': False, 'modelo': c['modelo'], 'puerto': c['puerto'], 'error': str(e)}

def documento(c, d, nota_credito=False):
    cmds = comandos_documento(d, c, nota_credito)
    def f(t):
        t.en_nc = nota_credito
        for cmd in cmds:
            ok, err = t.enviar(cmd)
            if not ok:
                try: t.enviar(c['cmd_anular'])
                except Exception: pass
                return {'ok': False, 'error': err, 'comando': cmd}
        time.sleep(0.3)
        r = leer_s1(t, c)
        num = r.get('ultima_nc' if nota_credito else 'ultima_factura')
        return {'ok': True, 'numero_fiscal': num, 'serial': r.get('serial'), 'comandos': len(cmds)}
    return con_impresora(c, f)

def comando_simple(c, cmd):
    def f(t):
        ok, err = t.enviar(cmd)
        return {'ok': ok, 'error': err or None}
    return con_impresora(c, f)

def resumen():
    c = cfg()
    return '%s en %s (%s)' % (c['modelo'], c['puerto'], 'simulada' if c.get('simular') else c.get('transporte'))

def atender(metodo, ruta, data):
    """Devuelve (código HTTP, json)."""
    c = cfg()
    if isinstance(data, dict) and data.get('puerto') and str(data['puerto']).upper() != 'AUTO' and ruta.startswith('/fiscal/') and not ruta.startswith('/fiscal/config'):
        c['puerto'] = str(data['puerto']).upper()
    try:
        if ruta.startswith('/fiscal/estado'):
            return 200, estado(c)
        if ruta.startswith('/fiscal/config'):
            if metodo == 'POST':
                base = cfg()
                for k, v in (data or {}).items():
                    if k in CFG_BASE:
                        base[k] = v
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
            tipo = str(data.get('tipo') or 'X').upper()
            r = comando_simple(c, c['cmd_reporte_z'] if tipo == 'Z' else c['cmd_reporte_x'])
            return (200 if r.get('ok') else 500), r
        if ruta.startswith('/fiscal/gaveta'):
            r = comando_simple(c, c['cmd_gaveta'])
            return (200 if r.get('ok') else 500), r
        if ruta.startswith('/fiscal/comandos'):
            # Vista previa de los comandos sin imprimir (diagnóstico)
            return 200, {'ok': True, 'comandos': comandos_documento(data, c, bool(data.get('nota_credito')))}
    except ValueError as e:
        return 400, {'ok': False, 'error': str(e)}
    except Exception as e:
        log('ERROR %s %s' % (ruta, e))
        return 500, {'ok': False, 'error': str(e)}
    return 404, {'ok': False, 'error': 'Not Found'}
