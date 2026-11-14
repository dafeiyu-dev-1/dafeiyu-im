@echo off
rem 启动桌面端服务。敏感配置放在 server\.env.cmd（已被 .gitignore 忽略）。
rem 先复制 server\.env.cmd.example 为 server\.env.cmd 并填好自己的值。
cd /d "%~dp0..\server"
if exist .env.cmd call .env.cmd
if "%IM_TOKEN%"=="" (
  echo [error] IM_TOKEN 未设置：请先配置 server\.env.cmd
  exit /b 1
)
node index.mjs
