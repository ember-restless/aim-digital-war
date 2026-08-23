@echo off
title AIM 数字大战 - 启动器
cd /d "%~dp0"

echo ========================================
echo   AIM 数字大战 · PC 版 启动器
echo ========================================
echo.

set "PY="
where py >nul 2>nul && py -c "import sys" >nul 2>nul && set "PY=py"
if not defined PY (
    where python >nul 2>nul && python -c "import sys" >nul 2>nul && set "PY=python"
)
if not defined PY (
    for /d %%d in ("%LOCALAPPDATA%\Programs\Python\*") do (
        "%%d\python.exe" -c "import sys" >nul 2>nul && set "PY=%%d\python.exe"
    )
)
if not defined PY (
    echo [1/3] 未检测到可用的 Python，正在下载安装器…
    powershell -Command "try { Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe' -OutFile '%TEMP%\aim-py-setup.exe' -UseBasicParsing } catch { exit 1 }"
    if errorlevel 1 (
        echo   下载失败！请手动打开 https://www.python.org/downloads/ 安装 Python
        echo   安装时务必勾选 "Add Python to PATH"
        pause
        exit /b 1
    )
    echo   正在静默安装 Python（约 1-2 分钟，请稍候）…
    "%TEMP%\aim-py-setup.exe" /quiet InstallAllUsers=0 PrependPath=1 Include_pip=1 Include_launcher=1
    for /d %%d in ("%LOCALAPPDATA%\Programs\Python\*") do set "PY=%%d\python.exe"
    if not defined PY set "PY=py"
)

echo [2/3] 检查 pygame …
"%PY%" -c "import pygame" >nul 2>nul
if errorlevel 1 (
    echo   未安装，正在安装 pygame（首次约 1 分钟）…
    "%PY%" -m pip install pygame --quiet --disable-pip-version-check
    if errorlevel 1 (
        echo   pygame 安装失败！请检查网络后重新运行本文件
        pause
        exit /b 1
    )
)

echo [3/3] 启动游戏 …
echo.
"%PY%" main.py

echo.
echo 游戏已退出。
pause
