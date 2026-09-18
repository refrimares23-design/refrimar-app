@echo off
setlocal
title Abrir Configuracion del Cliente (Profit Plus)
echo Buscando Softech.Configuracion.Cliente.exe ...
set "FOUND="
for %%p in (
  "C:\profit\profit_a\Softech.Configuracion.Cliente.exe"
  "C:\profit\herramientas\Softech.Configuracion.Cliente.exe"
  "C:\Program Files\profit\Softech.Configuracion.Cliente.exe"
  "C:\Program Files (x86)\profit\Softech.Configuracion.Cliente.exe"
) do (
  if exist %%p set "FOUND=%%~p"
)
if defined FOUND (
  echo Abriendo: %FOUND%
  start "" "%FOUND%"
) else (
  echo.
  echo NO se encontro el programa.
  echo Buscalo en tu instalacion (se llama Softech.Configuracion.Cliente.exe)
  echo y abrelo manualmente.
)
echo.
pause
