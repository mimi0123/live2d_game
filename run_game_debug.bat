@echo off
cd /d "%~dp0"
set "PROJ=%~dp0"
if "%PROJ:~-1%"=="\" set "PROJ=%PROJ:~0,-1%"
"%PROJ%\engine\Godot.exe" --path "%PROJ%" --verbose > "%PROJ%\game.log" 2>&1
