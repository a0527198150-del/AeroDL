@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
cd /d "%USERPROFILE%"
title AeroDL - One Click Windows Setup
set "REPO=https://github.com/a0527198150-del/AeroDL.git"
set "WORK=%USERPROFILE%\AeroDL-Desktop"
set "SUPPORT=%LOCALAPPDATA%\AeroDL-Builder"
set "LOG=%SUPPORT%\build.log"
set "NETFREE_CERT=%ProgramData%\NetFree\CA\netfree-ca-last.crt"
set "JAVA_HOME="
if not exist "%SUPPORT%" mkdir "%SUPPORT%"
call :log AeroDL - automated Windows setup
call :log Log file: %LOG%
call :log Working directory: %WORK%
call :log Step 1 - checking Git
where git.exe >nul 2>&1
if errorlevel 1 (call :err Git for Windows is missing. Install Git and rerun. & goto :fail)
if not exist "%WORK%\.git" (
  if exist "%WORK%" (call :err The destination exists but is not a Git repository. Nothing changed. & goto :fail)
  call :log Cloning the fork...
  git clone --branch main --single-branch "%REPO%" "%WORK%"
  if errorlevel 1 goto :fail
) else (
  cd /d "%WORK%"
  git remote get-url origin | findstr /I /C:"a0527198150-del/AeroDL" >nul
  if errorlevel 1 (call :err Existing repository has a different origin. & goto :fail)
  git diff --quiet
  if errorlevel 1 (call :err Uncommitted work detected. Aborting without overwriting. & goto :fail)
  git diff --cached --quiet
  if errorlevel 1 (call :err Staged work detected. Aborting without overwriting. & goto :fail)
  git checkout main
  if errorlevel 1 goto :fail
  git pull --ff-only origin main
  if errorlevel 1 goto :fail
)
cd /d "%WORK%"
call :log Step 2 - locating a Java Development Kit
set "JDK="
call :checkjdk "%USERPROFILE%\.jdks\jdk-25"
if defined JDK goto :javafound
for /d %%D in ("%USERPROFILE%\.jdks\jdk-25*") do call :checkjdk "%%~fD"
if defined JDK goto :javafound
for /d %%D in ("%ProgramFiles%\Eclipse Adoptium\jdk-25*") do call :checkjdk "%%~fD"
if defined JDK goto :javafound
for /d %%D in ("%ProgramFiles%\Java\jdk-25*") do call :checkjdk "%%~fD"
if defined JDK goto :javafound
for /d %%D in ("%ProgramFiles%\Microsoft\jdk-25*") do call :checkjdk "%%~fD"
if defined JDK goto :javafound
for /d %%D in ("%USERPROFILE%\.gradle\jdks\*") do call :checkjdk "%%~fD"
if defined JDK goto :javafound
call :log No JDK 25 was found in common locations.
where winget.exe >nul 2>&1
if errorlevel 1 (call :err JDK 25 is required and winget is unavailable. Install Temurin 25 and rerun. & goto :fail)
choice /C YN /M "Install Eclipse Temurin JDK 25 with winget"
if errorlevel 2 (call :err JDK installation declined. & goto :fail)
call :log Installing Temurin JDK 25...
winget.exe install --id EclipseAdoptium.Temurin.25.JDK --exact --source winget --accept-package-agreements --accept-source-agreements
if errorlevel 1 goto :fail
for /d %%D in ("%ProgramFiles%\Eclipse Adoptium\jdk-25*") do call :checkjdk "%%~fD"
if not defined JDK (call :err JDK 25 installation finished but was not found. Relaunch the script. & goto :fail)
:javafound
set "JAVA_HOME=%JDK%"
set "PATH=%JAVA_HOME%\bin;%PATH%"
call :log Using JAVA_HOME=%JAVA_HOME%
"%JAVA_HOME%\bin\java.exe" -version
if errorlevel 1 goto :fail
call :log Step 3 - preparing Java certificate trust for NetFree
if not exist "%NETFREE_CERT%" (
  call :log Local NetFree certificate not found. Downloading from official netfree.link domain...
  curl.exe --fail --location --show-error --max-time 45 --output "%SUPPORT%\netfree-ca.crt" https://netfree.link/netfree-ca.crt
  if errorlevel 1 (call :err Cannot obtain the certificate from the official NetFree URL. & goto :fail)
)
if not exist "%NETFREE_CERT%" set "NETFREE_CERT=%SUPPORT%\netfree-ca.crt"
"%JAVA_HOME%\bin\keytool.exe" -printcert -file "%NETFREE_CERT%" >nul 2>&1
if errorlevel 1 (call :err The NetFree certificate file is not a valid X.509 certificate. & goto :fail)
if not exist "%JAVA_HOME%\lib\security\cacerts" (call :err JDK trust store was not found. & goto :fail)
copy /Y "%JAVA_HOME%\lib\security\cacerts" "%SUPPORT%\aerodl-cacerts" >nul
if errorlevel 1 goto :fail
"%JAVA_HOME%\bin\keytool.exe" -delete -alias aerodl-netfree -keystore "%SUPPORT%\aerodl-cacerts" -storepass changeit >nul 2>&1
"%JAVA_HOME%\bin\keytool.exe" -importcert -noprompt -trustcacerts -alias aerodl-netfree -file "%NETFREE_CERT%" -keystore "%SUPPORT%\aerodl-cacerts" -storepass changeit
if errorlevel 1 (call :err Could not add the NetFree CA to the temporary trust store. & goto :fail)
set "JAVA_TOOL_OPTIONS=-Djavax.net.ssl.trustStore=%SUPPORT%\aerodl-cacerts -Djavax.net.ssl.trustStorePassword=changeit"
call :log Certificate configured for this build only. No SSL checks were disabled.
call :log Step 4 - Gradle build and test
call gradlew.bat --no-daemon check --stacktrace > "%LOG%" 2>&1
if errorlevel 1 (
  call :err Gradle build failed. Showing the last 75 log lines:
  powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%LOG%' -Tail 75"
  goto :fail
)
call :log BUILD SUCCEEDED. Starting AeroDL...
call :log Runtime output is written to "%SUPPORT%\runtime.log"
call gradlew.bat :composeApp:run --stacktrace > "%SUPPORT%\runtime.log" 2>&1
if errorlevel 1 (
  call :err AeroDL stopped with a nonzero exit code.
  call :log Showing the final runtime log lines:
  powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%SUPPORT%\runtime.log' -Tail 90"
  call :log If the window froze, inspect the runtime log and Windows Event Viewer.
  goto :fail
)
call :log Application exited normally.
pause
exit /b 0
:checkjdk
if defined JDK exit /b 0
if not exist "%~1\bin\javac.exe" exit /b 0
"%~1\bin\javac.exe" -version 2>&1 | findstr /R /C:"javac 25[.]" /C:"javac 25$" >nul
if not errorlevel 1 set "JDK=%~1"
exit /b 0
:log
echo [AeroDL] %*
exit /b 0
:err
echo [AeroDL ERROR] %*
exit /b 0
:fail
echo.
echo [AeroDL] Stopped after an error. Log: "%LOG%"
pause
exit /b 1
