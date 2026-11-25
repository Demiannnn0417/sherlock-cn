@echo off
rem ============================================================
rem  Sherlock local launcher (Windows)
rem  Usage: sherlock.cmd <username> [options]
rem  e.g.   sherlock.cmd john -fo output
rem
rem  ASCII only on purpose: cmd.exe misparses UTF-8 comments
rem  under code page 936, which corrupts the rest of the file.
rem ============================================================
setlocal
chcp 65001 >nul 2>nul
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "PYTHONUNBUFFERED=1"
set "SCRIPT_DIR=%~dp0"
set "PY=%SCRIPT_DIR%.venv\Scripts\python.exe"

if not exist "%PY%" (
  echo [ERROR] Virtual environment not found: "%SCRIPT_DIR%.venv"
  echo         Please reinstall dependencies, see LOCAL-DEPLOY.md
  exit /b 1
)

rem Auto-detect a usable local proxy (fails silently, never blocks the query)
if exist "%SCRIPT_DIR%lib\proxy_probe.py" (
  "%PY%" "%SCRIPT_DIR%lib\proxy_probe.py" --emit-cmd "%SCRIPT_DIR%state\proxy_env.cmd" >nul 2>nul
  if exist "%SCRIPT_DIR%state\proxy_env.cmd" call "%SCRIPT_DIR%state\proxy_env.cmd" >nul 2>nul
)

"%PY%" -m sherlock_project %*
set "RC=%ERRORLEVEL%"
exit /b %RC%
