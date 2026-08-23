@echo off
chcp 65001 >nul
title AIM 数字大战
cd /d %~dp0

echo ========================================
echo   AIM 数字大战 - Windows 客户端
echo ========================================

REM ---- 1. 找 Python（找不到则自动安装）----
set "PY="
where python >nul 2>nul && set "PY=python"
if not defined PY (
    where py >nul 2>nul && set "PY=py"
)
if not defined PY (
    echo.
    echo [信息] 未找到 Python，正在自动安装 Python 3.12...
    echo 需要联网，请稍候...
    winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements >nul 2>nul
    if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" (
        set "PY=%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
        echo [完成] Python 安装成功！
    ) else (
        echo.
        echo [错误] 自动安装失败。请手动安装 Python 3.9+:
        echo   https://www.python.org/downloads/
        echo 安装时勾选 Add Python to PATH
        echo.
        pause
        exit /b 1
    )
)

REM ---- 2. 检查/安装依赖 ----
%PY% -c "import pygame, socketio" >nul 2>nul
if errorlevel 1 (
    echo.
    echo [首次运行] 检测到缺少依赖，正在自动安装...
    echo 安装 pygame + python-socketio，需要联网，请稍候...
    echo.
    %PY% -m pip install -r requirements.txt
    if errorlevel 1 (
        echo.
        echo [错误] 依赖安装失败。
        echo 请手动执行: %PY% -m pip install -r requirements.txt
        echo.
        pause
        exit /b 1
    )
    echo [完成] 依赖安装成功！
    echo.
)

REM ---- 3. 桌面快捷方式（没有则自动创建）----
for /f "delims=" %%i in ('powershell -NoProfile -Command "[Environment]::GetFolderPath('Desktop')"') do set "DESKTOP=%%i"
set "LNK=%DESKTOP%\AIM 数字大战.lnk"
if not exist "%LNK%" (
    powershell -NoProfile -Command "$ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut('%LNK%'); $s.TargetPath = '%~f0'; $s.WorkingDirectory = '%~dp0'; $s.IconLocation = '%~dp0icon.ico,0'; $s.Save()" >nul 2>nul
    if exist "%LNK%" echo [完成] 已在桌面创建快捷方式「AIM 数字大战」
)

REM ---- 4. 启动 ----
echo 启动游戏...
%PY% main.py
pause
