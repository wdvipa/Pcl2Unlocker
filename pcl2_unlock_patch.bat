@echo off
setlocal
cd /d "%~dp0"

echo ========================================
echo   PCL2 下载限制解除补丁 启动器
echo ========================================
echo.

if not exist "pcl2_unlock_patch.ps1" (
    echo [错误] 未在当前目录找到 pcl2_unlock_patch.ps1
    echo        请将本 bat 与 ps1 放在同一目录。
    echo.
    pause
    exit /b 1
)

echo 正在启动补丁脚本...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pcl2_unlock_patch.ps1"

echo.
echo 脚本已结束。
pause
exit /b
