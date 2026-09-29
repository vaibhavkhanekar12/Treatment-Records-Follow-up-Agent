@echo off
setlocal

if "%~1"=="" (
  echo Usage: deploy-personal-injury.cmd ^<org-alias^>
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy-personal-injury.ps1" -TargetOrg "%~1"
exit /b %ERRORLEVEL%
