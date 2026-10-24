@echo off
setlocal EnableExtensions
chcp 65001 >nul
title AeroDL - Build and Run
set "REPO=https://github.com/a0527198150-del/AeroDL.git"
set "TARGET=%USERPROFILE%\AeroDL-Desktop"
set "LOG=%TEMP%\aerodl-build.log"

echo ==================================================
echo AeroDL - Windows build and launch
echo Project: a0527198150-del/AeroDL (main)
echo ==================================================
echo.
where git >nul 2>&1
if errorlevel 1 (
  echo ERROR: Git is required to download or update the project.
  echo Install Git for Windows: https://git-scm.com/downloads/win
  goto :fail
)
if not exist "%TARGET%\.git" (
  if exist "%TARGET%" (
    echo ERROR: "%TARGET%" exists but is not a Git repository.
    echo Rename this folder and run again; nothing was deleted.
    goto :fail
  )
  echo [1/4] Cloning repository...
  git clone --branch main --single-branch "%REPO%" "%TARGET%" || goto :fail
) else (
  echo [1/4] Updating local repository...
  cd /d "%TARGET%" || goto :fail
  git remote get-url origin | findstr /I /C:"a0527198150-del/AeroDL" >nul
  if errorlevel 1 (
    echo ERROR: Existing folder points to a different repository.
    goto :fail
  )
  git diff --quiet
  if errorlevel 1 (
    echo ERROR: Local changes found. Refusing to overwrite them.
    goto :fail
  )
  git diff --cached --quiet
  if errorlevel 1 (
    echo ERROR: Staged changes found. Refusing to overwrite them.
    goto :fail
  )
  git checkout main || goto :fail
  git pull --ff-only origin main || goto :fail
)
cd /d "%TARGET%" || goto :fail
if not exist gradlew.bat (
  echo ERROR: Gradle wrapper missing.
  goto :fail
)
echo [2/4] Checking Java and running Gradle...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%\scripts\Build-Run-Windows.ps1"
if errorlevel 1 goto :fail
echo AeroDL exited normally.
pause
exit /b 0

:fail
echo.
echo Build or launch did not finish successfully.
echo If a log exists, share: "%LOG%"
pause
exit /b 1
