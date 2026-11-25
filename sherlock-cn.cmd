@echo off
rem ============================================================
rem  Sherlock CN launcher (domestic platforms only)
rem  Usage: sherlock-cn.cmd <handle> [options]
rem  e.g.   sherlock-cn.cmd douyin --csv out.csv --xlsx out.xlsx
rem
rem  ASCII only: cmd.exe misparses UTF-8 comments under cp936.
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

rem Domestic platforms are reached directly; no proxy is applied here.
"%PY%" "%SCRIPT_DIR%lib\cn_search.py" %*
set "RC=%ERRORLEVEL%"
exit /b %RC%
