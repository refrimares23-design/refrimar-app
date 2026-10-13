@echo off
title Puente Impresion REFRIMAR
cd /d "%~dp0"
where python >nul 2>nul || (echo Instala Python desde python.org marcando "Add to PATH" & pause & exit)
python -c "import win32print" 2>nul || (echo Instalando pywin32... & python -m pip install pywin32)
echo Quieres que el puente arranque solo con Windows? (S/N)
set /p r=
if /i "%r%"=="S" (
  echo @echo off ^&^& start /min "" pythonw "%~dp0imprimir_tickets.py" > "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\refrimar_puente.bat"
  echo Listo: arrancara solo cada vez que enciendas la PC.
)
start /min "" pythonw imprimir_tickets.py
exit
