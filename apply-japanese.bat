@echo off
setlocal

set "SCRIPT=%~dp0apply-japanese.ps1"
if not exist "%SCRIPT%" (
    echo Could not find apply-japanese.ps1 in this folder.
    pause
    exit /b 1
)

where.exe pwsh.exe >nul 2>nul
if errorlevel 1 goto use_windows_powershell
pwsh.exe -NoLogo -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -ge 7) { exit 0 } else { exit 1 }" >nul 2>nul
if errorlevel 1 goto use_windows_powershell
set "POWERSHELL=pwsh.exe"
goto runtime_selected

:use_windows_powershell
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" goto missing_powershell

:runtime_selected

echo Waves of Steel Japanese Localization
echo.
echo 1. Apply Japanese localization
echo 2. Restore original files
echo Q. Quit
echo.
choice /c 12Q /n /m "Select [1/2/Q]: "
if errorlevel 3 exit /b 0
if errorlevel 2 goto restore
if errorlevel 1 goto apply

:apply
echo.
%POWERSHELL% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "PATCH_EXIT=%ERRORLEVEL%"
goto finished

:restore
echo.
%POWERSHELL% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Restore
set "PATCH_EXIT=%ERRORLEVEL%"
goto finished

:finished
echo.
if "%PATCH_EXIT%"=="0" (
    echo Completed successfully.
) else (
    echo The operation failed. Review the message above.
)
pause
exit /b %PATCH_EXIT%

:missing_powershell
echo PowerShell 7 or Windows PowerShell 5.1 was not found.
pause
exit /b 1
