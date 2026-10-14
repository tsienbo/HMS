@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 智慧医院预约挂号系统

echo.
echo   ============================================
echo    智慧医院预约挂号系统   Node + PostgreSQL
echo   ============================================
echo.
echo   服务地址 : http://127.0.0.1:3000/
echo   停止服务 : 直接关闭本窗口
echo.
echo   前置条件 :
echo     - PostgreSQL 服务已启动
echo     - 首次使用请先执行 npm install 与 npm run db:init
echo   ============================================
echo.

echo   [1/2] 启动服务，2 秒后自动打开浏览器...
start "" /min cmd /c "timeout /t 2 >nul & start "" http://127.0.0.1:3000/"

echo   [2/2] 运行中，按 Ctrl+C 或关闭窗口停止
echo.
node server/app.js

echo.
echo   服务已停止。
pause
