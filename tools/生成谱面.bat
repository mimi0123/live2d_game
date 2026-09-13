@echo off
chcp 936 >nul
title 音游谱面生成器
set PYTHONIOENCODING=gbk
set PY=C:\Users\Administrator\.workbuddy\binaries\python\versions\3.13.12\python.exe
cd /d "%~dp0.."

set AUDIO=
if not "%~1"=="" set AUDIO=%~1
if "%AUDIO%"=="" set /p AUDIO=请把音频文件拖到这里再回车：

if "%AUDIO%"=="" (
  echo 没有收到音频文件，已退出。
  pause
  exit /b 1
)

echo.
echo 正在生成谱面：%AUDIO%
echo.
"%PY%" "tools\gen_rhythm_chart.py" "%AUDIO%"
echo.
pause
