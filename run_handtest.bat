@echo off
rem STEP 3 soft-touch hand regression (ASCII only on purpose: avoids GBK/UTF-8 bat issues)
cd /d "%~dp0"
set GODOT="%~dp0engine\Godot.exe"
echo ================ 1/4 soft_selftest ================
%GODOT% --headless --path "%~dp0." --script res://tools/soft_selftest.gd
echo ================ 2/4 rhythm_selftest ================
%GODOT% --headless --path "%~dp0." --script res://tools/rhythm_selftest.gd
echo ================ 3/4 soft_field_test ================
%GODOT% --headless --path "%~dp0." --script res://tools/soft_field_test.gd
echo ================ 4/4 hand_contact_test ================
%GODOT% --headless --path "%~dp0." --script res://tools/hand_contact_test.gd
echo.
echo all done. press any key to close.
pause >nul
