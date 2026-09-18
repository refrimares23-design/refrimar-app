"""
REFRIMAR — Impresora Termica Bridge
====================================
Servidor local HTTP (puerto 3001) que recibe tickets en texto plano
y los envia a la impresora termica conectada por USB.

Instalacion:
    pip install pywin32        (Windows — solo si quieres impresion directa)
    pip install impresora-bridge  (opcional, no requerido)

Uso:
    python imprimir_tickets.py
    python imprimir_tickets.py --port 3001
    python imprimir_tickets.py --printer "POS-58"
    python imprimir_tickets.py --width 42

API:
    GET  /health   -> { ok: true, printer: "nombre", port: 42 }
    POST /print    -> { text, width }  -> { ok: true }
    POST /print    -> { text }         -> { ok: true }
    OPTIONS /print -> (CORS preflight)

La app web (facturacion.html) llama a:
    GET  http://localhost:3001/health
    POST http://localhost:3001/print
"""

import sys
import os
import json
import argparse
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler

# ── Detectar plataforma e impresora ──────────────────────────────

def get_default_printer_name():
    """Obtiene el nombre de la impresora predeterminada del sistema."""
    if sys.platform == "win32":
        try:
            import win32print
            return win32print.GetDefaultPrinter()
        except ImportError:
            pass
    # Linux / macOS: usar lpstat
    try:
        out = subprocess.check_output(["lpstat", "-d"], text=True, timeout=3)
        # Output: "system default destination: HP_LaserJet"
        return out.split(":", 1)[1].strip()
    except Exception:
        return None


def print_text(text, printer_name=None, width=42):
    """
    Envia texto plano a la impresora termica.
    En Windows usa win32print (RAW).
    En Linux/macOS usa lp.
    Retorna (ok, error_msg).
    """
    if sys.platform == "win32":
        return _print_windows(text, printer_name)
    else:
        return _print_unix(text, printer_name)


def _print_windows(text, printer_name=None):
    """Impresion directa en Windows via win32print (RAW)."""
    try:
        import win32print
        import win32con
    except ImportError:
        return False, "pywin32 no instalado. Ejecuta: pip install pywin32"

    try:
        hprinter = win32print.OpenPrinter(printer_name or win32print.GetDefaultPrinter())
        try:
            hjob = win32print.StartDocPrinter(hprinter, 1, ("REFRIMAR Ticket", None, "RAW"))
            try:
                win32print.StartPagePrinter(hprinter)
                # Codificar en latin-1 para caracteres especiales
                raw = text.encode("latin-1", errors="replace")
                win32print.WritePrinter(hprinter, raw)
                win32print.EndPagePrinter(hprinter)
            finally:
                win32print.EndDocPrinter(hprinter)
        finally:
            win32print.ClosePrinter(hprinter)
        return True, None
    except Exception as e:
        return False, str(e)


def _print_unix(text, printer_name=None):
    """Impresion en Linux/macOS via lp."""
    try:
        cmd = ["lp"]
        if printer_name:
            cmd += ["-d", printer_name]
        cmd += ["-"]  # leer de stdin
        proc = subprocess.run(cmd, input=text, text=True, timeout=10, capture_output=True)
        if proc.returncode == 0:
            return True, None
        return False, proc.stderr.strip() or "lp fallo"
    except FileNotFoundError:
        return False, "comando 'lp' no encontrado"
    except Exception as e:
        return False, str(e)


# ── Servidor HTTP ────────────────────────────────────────────────

PRINTER_NAME = None
DEFAULT_WIDTH = 42


class PrintHandler(BaseHTTPRequestHandler):
    """Handler HTTP para el bridge de impresion."""

    def log_message(self, fmt, *args):
        """Log con prefijo."""
        print(f"[bridge] {args[0]}")

    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        """CORS preflight."""
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            self._handle_health()
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/print":
            self._handle_print()
        else:
            self.send_response(404)
            self.end_headers()

    def _handle_health(self):
        """GET /health — Verifica estado de la impresora."""
        printer = PRINTER_NAME or get_default_printer_name() or "impresora del sistema"

        # Verificar que la impresora responde (rapido)
        ok = True
        error = None
        if sys.platform == "win32":
            try:
                import win32print
                win32print.GetDefaultPrinter()
            except Exception as e:
                ok = False
                error = str(e)

        resp = {"ok": ok, "printer": printer, "width": DEFAULT_WIDTH}
        if error:
            resp["error"] = error

        body = json.dumps(resp).encode("utf-8")
        self.send_response(200 if ok else 503)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _handle_print(self):
        """POST /print — Imprime un ticket."""
        content_length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(content_length) if content_length else b""

        try:
            data = json.loads(raw)
            text = data.get("text", "")
            width = data.get("width", DEFAULT_WIDTH)
        except (json.JSONDecodeError, AttributeError):
            # Si no es JSON valido, tratar como texto plano
            text = raw.decode("utf-8", errors="replace")
            width = DEFAULT_WIDTH

        if not text.strip():
            self._json_response(400, {"ok": False, "error": "texto vacio"})
            return

        ok, error = print_text(text, PRINTER_NAME, width)

        if ok:
            self._json_response(200, {"ok": True})
        else:
            self._json_response(500, {"ok": False, "error": error or "error desconocido"})

    def _json_response(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)


# ── Main ─────────────────────────────────────────────────────────

def main():
    global PRINTER_NAME, DEFAULT_WIDTH

    parser = argparse.ArgumentParser(description="REFRIMAR Impresora Termica Bridge")
    parser.add_argument("--port", type=int, default=3001, help="Puerto HTTP (default: 3001)")
    parser.add_argument("--printer", type=str, default=None, help="Nombre de la impresora")
    parser.add_argument("--width", type=int, default=42, help="Ancho de caracteres (42=80mm, 32=58mm)")
    args = parser.parse_args()

    PRINTER_NAME = args.printer
    DEFAULT_WIDTH = args.width

    printer = PRINTER_NAME or get_default_printer_name() or "impresora del sistema"
    print(f"")
    print(f"  ╔══════════════════════════════════════════════╗")
    print(f"  ║  REFRIMAR — Impresora Termica Bridge         ║")
    print(f"  ╠══════════════════════════════════════════════╣")
    print(f"  ║  Puerto:     http://localhost:{args.port}          ║")
    print(f"  ║  Impresora:  {printer:<31s}║")
    print(f"  ║  Ancho:      {args.width} chars ({'80mm' if args.width >= 40 else '58mm'}){' ' * (24 - len(str(args.width)))}║")
    print(f"  ║  Plataforma: {sys.platform:<31s}║")
    print(f"  ╠══════════════════════════════════════════════╣")
    print(f"  ║  Dejar esta ventana abierta mientras usas    ║")
    print(f"  ║  la app web. Ctrl+C para detener.            ║")
    print(f"  ╚══════════════════════════════════════════════╝")
    print(f"")

    try:
        server = HTTPServer(("0.0.0.0", args.port), PrintHandler)
        server.serve_forever()
    except OSError as e:
        if "address already in use" in str(e).lower() or e.errno == 10048:
            print(f"  [ERROR] Puerto {args.port} ya esta en uso.")
            print(f"  Cierra la otra instancia o usa: python imprimir_trials.py --port {args.port + 1}")
        else:
            raise
    except KeyboardInterrupt:
        print("\n  Bridge detenido.")


if __name__ == "__main__":
    main()
