# AeroDL Windows build helper. Launched by AeroDL-Build-And-Run.cmd.
$ErrorActionPreference = 'Stop'
$repo = Join-Path $env:USERPROFILE 'AeroDL-Desktop'
$log = Join-Path $env:TEMP 'aerodl-build.log'

Write-Host '[AeroDL] PowerShell build helper started.' -ForegroundColor Cyan
Write-Host ('[AeroDL] Repository: ' + $repo)
Write-Host '[AeroDL] Checking Java configuration and available JDKs...'

function Find-Jdk25 {
    Write-Host '[Java] Looking for an installed JDK 25...'
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $roots = New-Object 'System.Collections.Generic.List[string]'

    if ($env:JAVA_HOME) { $candidates.Add($env:JAVA_HOME) }
    foreach ($scope in @('User','Machine')) {
        $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', $scope)
        if ($javaHome) { $candidates.Add($javaHome) }
    }

    $javaCommand = Get-Command javac.exe -ErrorAction SilentlyContinue
    if ($javaCommand -and $javaCommand.Source) {
        $candidates.Add((Split-Path -Parent (Split-Path -Parent $javaCommand.Source)))
    }

    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    foreach ($prefix in @($programFiles, $programFilesX86, $env:LOCALAPPDATA)) {
        if (-not $prefix) { continue }
        foreach ($subpath in @('Eclipse Adoptium','Java','Microsoft','Amazon Corretto','BellSoft','Zulu','Programs\Eclipse Adoptium','Programs\Java')) {
            $roots.Add((Join-Path $prefix $subpath))
        }
    }
    foreach ($root in @(
        (Join-Path $env:USERPROFILE '.jdks'),
        (Join-Path $env:USERPROFILE '.gradle\jdks'),
        (Join-Path $programFiles 'Android\Android Studio\jbr')
    )) {
        if ($root) { $roots.Add($root) }
    }

    Write-Host '[Java] Checking registered JDK installations...'
    foreach ($registryKey in @(
        'HKLM:\SOFTWARE\JavaSoft\JDK',
        'HKCU:\SOFTWARE\JavaSoft\JDK',
        'HKLM:\SOFTWARE\Eclipse Adoptium\JDK',
        'HKCU:\SOFTWARE\Eclipse Adoptium\JDK'
    )) {
        if (-not (Test-Path -LiteralPath $registryKey)) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $registryKey -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if ($properties -and $properties.JavaHome) { $candidates.Add([string]$properties.JavaHome) }
            if ($properties -and $properties.Path) { $candidates.Add([string]$properties.Path) }
        }
    }

    Write-Host '[Java] Checking common installation folders...'
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $candidates.Add($root)
        foreach ($child in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $candidates.Add($child.FullName)
            $nested = Join-Path $child.FullName 'Contents\Home'
            if (Test-Path -LiteralPath $nested -PathType Container) { $candidates.Add($nested) }
        }
    }

    Write-Host ('[Java] Found ' + $candidates.Count + ' candidate locations; verifying compiler versions...')
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        $compiler = Join-Path $candidate 'bin\javac.exe'
        if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { continue }
        Write-Host ('[Java] Testing ' + $candidate)
        # Protect against a broken Java executable hanging the entire launcher.
        $process = New-Object System.Diagnostics.Process
        try {
            $info = New-Object System.Diagnostics.ProcessStartInfo
            $info.FileName = $compiler
            $info.Arguments = '-version'
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $process.StartInfo = $info
            if (-not $process.Start()) { continue }
            if (-not $process.WaitForExit(10000)) {
                Write-Warning ('Java compiler check timed out: ' + $compiler)
                $process.Kill()
                $process.WaitForExit()
                continue
            }
            $version = ($process.StandardOutput.ReadToEnd() + "`n" + $process.StandardError.ReadToEnd()).Trim()
            Write-Host ('[Java] ' + $version)
            if ($process.ExitCode -eq 0 -and $version -match '^javac\s+25(\.|$)') {
                return $candidate
            }
        } catch {
            Write-Warning ('Unable to inspect ' + $compiler + ': ' + $_.Exception.Message)
        } finally {
            $process.Dispose()
        }
    }
    return $null
}

function Fail([string]$message) {
    Write-Host ''
    Write-Host ('ERROR: ' + $message) -ForegroundColor Red
    exit 1
}

$jdk = Find-Jdk25
if (-not $jdk) {
    Write-Host 'JDK 25 was not detected in common installation locations.' -ForegroundColor Yellow
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Fail 'Install JDK 25 from https://adoptium.net/ and run this script again. winget is not installed.'
    }
    $choice = Read-Host 'Install Eclipse Temurin JDK 25 using winget now? [Y/N]'
    if ($choice -notmatch '^(y|yes)$') {
        Fail 'Java installation declined. Install JDK 25 manually and try again.'
    }

    Write-Host 'Installing JDK 25 using Windows Package Manager...'
    & winget.exe install --id EclipseAdoptium.Temurin.25.JDK --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Fail ('winget failed (exit code ' + $LASTEXITCODE + '). Install JDK 25 manually from https://adoptium.net/')
    }

    $jdk = Find-Jdk25
    if (-not $jdk) {
        Fail 'JDK 25 installation finished but its location could not be detected. Reopen a terminal or install from https://adoptium.net/'
    }
}

$env:JAVA_HOME = $jdk
$env:PATH = (Join-Path $jdk 'bin') + ';' + $env:PATH
Write-Host ('Using JAVA_HOME=' + $env:JAVA_HOME) -ForegroundColor Green
& (Join-Path $jdk 'bin\java.exe') -version

if (-not (Test-Path -LiteralPath (Join-Path $repo 'gradlew.bat') -PathType Leaf)) {
    Fail ('Gradle wrapper not found in ' + $repo)
}
Push-Location $repo
try {
    Write-Host ''
    Write-Host ('Running Gradle checks. Full log: ' + $log)
    $ErrorActionPreference = 'Continue'
    & .\gradlew.bat --no-daemon check --stacktrace 2>&1 |
        ForEach-Object { "$_" } |
        Tee-Object -FilePath $log
    $buildExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    if ($buildExitCode -ne 0) {
        Write-Host ''
        Write-Host 'BUILD FAILED. Log tail:' -ForegroundColor Red
        Get-Content -LiteralPath $log -Tail 75
        exit $buildExitCode
    }
    Write-Host ''
    Write-Host 'BUILD CHECKS PASSED. Launching AeroDL...' -ForegroundColor Green
    & .\gradlew.bat :composeApp:run
    $launchExitCode = $LASTEXITCODE
    if ($launchExitCode -ne 0) {
        Write-Host ('Application launch failed with exit code ' + $launchExitCode) -ForegroundColor Red
    }
    exit $launchExitCode
}
finally {
    Pop-Location
}
