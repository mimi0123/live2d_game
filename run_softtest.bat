@echo off
cd /d "%~dp0"
"%~dp0engine\Godot.exe" --path "%~dp0." res://scenes/SoftPhysicsTest.tscn
