@echo off
setlocal
title Abrir Herramienta Administrativa (Profit Plus)
echo Buscando Softech.HerramientaAdministrativa.UI.exe ...
set "FOUND="
for %%p in (
  "C:\profit\herramientas\Softech.HerramientaAdministrativa.UI.exe"
  "C:\profit\profit_a\Softech.HerramientaAdministrativa.UI.exe"
  "C:\Program Files\profit\Softech.HerramientaAdministrativa.UI.exe"
  "C:\Program Files (x86)\profit\Softech.HerramientaAdministrativa.UI.exe"
) do (
  if exist %%p set "FOUND=%%~p"
)
if defined FOUND (
  echo Abriendo: %FOUND%
  start "" "%FOUND%"
) else (
  echo.
  echo NO se encontro el programa.
  echo Buscalo en tu instalacion (se llama Softech.HerramientaAdministrativa.UI.exe)
  echo y abrelo manualmente.
)
echo.
pause
