@echo off
cd /d "%~dp0"
start "" "%~dp0engine\Godot.exe" --editor --path "%~dp0"
