@echo off
setlocal
title SparkSustain installer
echo.
echo   SparkSustain installer for Windows
echo   ----------------------------------

set "SRC=%~dp0"
set "DEST=%LOCALAPPDATA%\SparkSustain"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    echo   ERROR: The .NET Framework 4 compiler was not found on this PC.
    echo   Install ".NET Framework 4.8" from Microsoft and run this again.
    pause
    exit /b 1
)

if not exist "%SRC%SparkSustain.cs" (
    echo   ERROR: SparkSustain.cs not found next to this installer.
    pause
    exit /b 1
)

echo   Compiling SparkSustain on this PC (no downloads needed)...
mkdir "%DEST%" 2>nul
taskkill /im SparkSustain.exe /f >nul 2>nul

set "ICONARG="
if exist "%SRC%SparkSustain.ico" set "ICONARG=/win32icon:"%SRC%SparkSustain.ico""

"%CSC%" /nologo /target:winexe /out:"%DEST%\SparkSustain.exe" %ICONARG% ^
  /r:System.dll /r:System.Core.dll /r:System.Drawing.dll ^
  /r:System.Windows.Forms.dll /r:System.Management.dll ^
  /r:System.Web.Extensions.dll /r:System.IO.Compression.dll ^
  /r:System.IO.Compression.FileSystem.dll ^
  "%SRC%SparkSustain.cs"
if errorlevel 1 (
    echo.
    echo   BUILD FAILED — copy the error text above and send it to Jay.
    pause
    exit /b 1
)

copy /y "%SRC%Manual.html" "%DEST%\Manual.html" >nul 2>nul

echo   Installed to %DEST%\SparkSustain.exe
echo   Launching SparkSustain — look for the sun icon in your system tray
echo   (near the clock; click the ^ arrow if it's hidden).
echo.
echo   The Setup Assistant will walk you through pairing your Videri API key.
echo.
start "" "%DEST%\SparkSustain.exe"
pause
