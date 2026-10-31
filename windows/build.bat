@echo off
rem Build Clawd.exe with the C# compiler that ships with Windows (.NET Framework 4.x).
rem Nothing else needs to be installed. Output: windows\dist\Clawd.exe
setlocal
cd /d "%~dp0"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
  echo [error] csc.exe not found. Please enable .NET Framework 4.8 in Windows Features.
  if "%CI%"=="" pause
  exit /b 1
)
if not exist dist mkdir dist
"%CSC%" /nologo /target:winexe /optimize+ /platform:anycpu /codepage:65001 /warn:3 ^
  /out:dist\Clawd.exe /win32icon:clawd.ico /win32manifest:app.manifest ^
  /resource:..\Resources\rime\weasel.custom.yaml,weasel.custom.yaml ^
  /resource:..\Resources\rime\clawd.lua,clawd.lua ^
  /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll ^
  ClawdWin.cs
if errorlevel 1 (
  echo [error] Build failed.
  if "%CI%"=="" pause
  exit /b 1
)
echo [ok] Built windows\dist\Clawd.exe
if "%CI%"=="" pause
