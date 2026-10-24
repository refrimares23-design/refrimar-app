Unicode true
!include "MUI2.nsh"
!include "x64.nsh"

!define APP "REFRIMAR POS"
!define VER "2.3.0"
!define REGUNINST "Software\Microsoft\Windows\CurrentVersion\Uninstall\RefrimarPOS"

Name "${APP}"
OutFile "REFRIMAR-POS-Setup.exe"
InstallDir "$LOCALAPPDATA\RefrimarPOS"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "Comercial Refrimar"
VIProductVersion "2.3.0.0"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "CompanyName" "Comercial Refrimar"
VIAddVersionKey "FileDescription" "Instalador de REFRIMAR POS"
VIAddVersionKey "FileVersion" "${VER}"
VIAddVersionKey "LegalCopyright" "Comercial Refrimar"

!define MUI_ICON "refrimar.ico"
!define MUI_UNICON "refrimar.ico"
!define MUI_WELCOMEFINISHPAGE_BITMAP "lateral.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "lateral.bmp"
!define MUI_WELCOMEPAGE_TITLE "Instalar REFRIMAR POS"
!define MUI_WELCOMEPAGE_TEXT "Se instalará el punto de venta de Comercial Refrimar en esta computadora.$\r$\n$\r$\nIncluye el programa de impresión para impresoras fiscales (PNP, HKA/Bixolon y otras) y de tickets. Las detecta solas.$\r$\n$\r$\nPulsa Instalar para continuar."
!define MUI_FINISHPAGE_TITLE "¡Listo!"
!define MUI_FINISHPAGE_TEXT "REFRIMAR POS quedó instalado. Lo encuentras en el escritorio y en el menú Inicio.$\r$\n$\r$\nEl programa de impresión arranca solo cada vez que enciendas la computadora."
!define MUI_FINISHPAGE_RUN "$INSTDIR\refrimar-pos.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Abrir REFRIMAR POS ahora"
!define MUI_WELCOMEPAGE_TITLE_3LINES

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Spanish"

Function DetenerAnterior
  nsExec::Exec 'taskkill /F /IM refrimar-pos.exe'
  Pop $0
  nsExec::Exec `powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $$_.CommandLine -like '*imprimir_tickets*' } | ForEach-Object { Stop-Process -Id $$_.ProcessId -Force }"`
  Pop $0
  Sleep 600
FunctionEnd

Section "Instalar"
  Call DetenerAnterior
  SetOutPath "$INSTDIR"
  ${If} ${RunningX64}
    File "/oname=refrimar-pos.exe" "refrimar-pos.exe"
  ${Else}
    File "/oname=refrimar-pos.exe" "refrimar-pos-32.exe"
  ${EndIf}
  File "refrimar.ico"

  ; Versión anterior (programa de impresión en Python): se quita del inicio
  Delete "$SMSTARTUP\REFRIMAR impresoras.lnk"
  Delete "$SMSTARTUP\refrimar_puente.bat"

  ; Accesos directos
  CreateShortcut "$DESKTOP\REFRIMAR POS.lnk" "$INSTDIR\refrimar-pos.exe" "" "$INSTDIR\refrimar.ico" 0 SW_SHOWNORMAL "" "Punto de venta REFRIMAR"
  CreateDirectory "$SMPROGRAMS\REFRIMAR"
  CreateShortcut "$SMPROGRAMS\REFRIMAR\REFRIMAR POS.lnk" "$INSTDIR\refrimar-pos.exe" "" "$INSTDIR\refrimar.ico"
  CreateShortcut "$SMPROGRAMS\REFRIMAR\Desinstalar REFRIMAR POS.lnk" "$INSTDIR\Desinstalar.exe"

  ; El programa de impresión arranca con Windows (sin ventana)
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "RefrimarPOS" '"$INSTDIR\refrimar-pos.exe" --puente'

  ; Que la impresora USB no se "duerma" (recomendación de PNP)
  nsExec::Exec 'powercfg /SETACVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0'
  Pop $0
  nsExec::Exec 'powercfg /SETDCVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0'
  Pop $0
  nsExec::Exec 'powercfg /SETACTIVE SCHEME_CURRENT'
  Pop $0

  ; Desinstalador (aparece en Configuración > Aplicaciones)
  WriteUninstaller "$INSTDIR\Desinstalar.exe"
  WriteRegStr HKCU "${REGUNINST}" "DisplayName" "${APP}"
  WriteRegStr HKCU "${REGUNINST}" "DisplayVersion" "${VER}"
  WriteRegStr HKCU "${REGUNINST}" "Publisher" "Comercial Refrimar"
  WriteRegStr HKCU "${REGUNINST}" "DisplayIcon" "$INSTDIR\refrimar.ico"
  WriteRegStr HKCU "${REGUNINST}" "UninstallString" '"$INSTDIR\Desinstalar.exe"'
  WriteRegDWORD HKCU "${REGUNINST}" "NoModify" 1
  WriteRegDWORD HKCU "${REGUNINST}" "NoRepair" 1

  ; Arranca el programa de impresión ya mismo
  Exec '"$INSTDIR\refrimar-pos.exe" --puente'
SectionEnd

Section "Uninstall"
  nsExec::Exec 'taskkill /F /IM refrimar-pos.exe'
  Pop $0
  Sleep 500
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "RefrimarPOS"
  DeleteRegKey HKCU "${REGUNINST}"
  Delete "$DESKTOP\REFRIMAR POS.lnk"
  RMDir /r "$SMPROGRAMS\REFRIMAR"
  Delete "$INSTDIR\refrimar-pos.exe"
  Delete "$INSTDIR\refrimar.ico"
  Delete "$INSTDIR\puente.log"
  Delete "$INSTDIR\Desinstalar.exe"
  ; Se conserva impresora_fiscal.json por si se vuelve a instalar
SectionEnd
