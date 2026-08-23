@echo off
chcp 65001 >nul
title AIM - Windows 桌面版编译
cd /d "%~dp0"
echo ================================
echo   AIM 数字大战 · Windows 桌面版
echo ================================
echo.
where flutter >nul 2>nul
if errorlevel 1 (
    echo [错误] 未找到 Flutter。请先安装 Flutter SDK 并加入 PATH：
    echo   https://docs.flutter.dev/get-started/install/windows
    echo   装完用 PowerShell 跑:  flutter doctor
    pause
    exit /b 1
)
echo [1/4] 启用 Windows 桌面支持…
call flutter config --enable-windows-desktop >nul
echo [2/4] 安装依赖…
call flutter pub get
if errorlevel 1 ( echo 依赖安装失败 & pause & exit /b 1 )
echo [3/4] 检查 Visual Studio C++（Windows 桌面必需）…
call flutter doctor -v 2>nul | findstr /i "Visual Studio"
echo [4/4] 编译 release 版（首次约 5-10 分钟，请耐心）…
call flutter build windows --release
if errorlevel 1 (
    echo.
    echo 编译失败！多半是没装 VS 的「使用 C++ 的桌面开发」。
    echo 用 Visual Studio Installer 勾选后重跑本文件。
    pause
    exit /b 1
)
echo.
echo 编译完成！
echo 可执行文件在:  build\windows\x64\runner\Release\aim.exe
echo 把整个 Release 文件夹拷走即可运行（桌面版跟手机端同代码，界面一致）。
pause
