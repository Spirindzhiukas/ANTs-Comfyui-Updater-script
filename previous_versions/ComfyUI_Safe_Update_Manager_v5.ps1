# ============================================================================
# ComfyUI Safe Update Manager v5
# ============================================================================
# Safe updater for ComfyUI portable installations
# ============================================================================
# Features:
# - Branch awareness (master/main vs PR branches)
# - Safe PR recovery
# - Protected symlink-aware folder handling
# - GitHub connection validation
# - Git version validation
# - Rollback branch creation
# - Protected cleanup exclusions
# - Safe force cleanup mode
# ============================================================================

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------------------
# CONFIG
# ----------------------------------------------------------------------------

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ComfyPath = Join-Path $ScriptRoot "ComfyUI"
$UpdateDir = Join-Path $ScriptRoot "update"

$FoldersToProtect = @(
    "models",
    "output",
    "input"
)

# NEVER allow destructive cleanup to touch these
$GitProtectedPaths = @(
    "models",
    "input",
    "output",
    "temp",
    "custom_nodes",
    "user"
)

$SpeedThresholdMB = 5
$InitialTestSeconds = 10
$ExtendedTestSeconds = 30

$GitHubTestURL = "https://raw.githubusercontent.com/github/gitignore/main/Python.gitignore"

# ----------------------------------------------------------------------------
# UI HELPERS
# ----------------------------------------------------------------------------

function Write-Banner {
    param(
        [string]$Text,
        [string]$Color = "White"
    )

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor $Color
    Write-Host " $Text" -ForegroundColor $Color
    Write-Host "============================================================" -ForegroundColor $Color
    Write-Host ""
}

function Write-Section {
    param([string]$Text)

    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
}

# ----------------------------------------------------------------------------
# GIT HELPERS
# ----------------------------------------------------------------------------

function Invoke-Git {
    param([string]$Arguments)

    Push-Location $ComfyPath

    try {
        return (Invoke-Expression "git $Arguments" 2>&1)
    }
    finally {
        Pop-Location
    }
}

function Get-CurrentBranch {

    Push-Location $ComfyPath

    try {
        return ((git rev-parse --abbrev-ref HEAD 2>&1).Trim())
    }
    finally {
        Pop-Location
    }
}

function Get-CurrentCommit {
    return ((Invoke-Git "rev-parse --short HEAD").Trim())
}

function Test-DirtyWorkingTree {

    $status = Invoke-Git "status --porcelain"

    return -not [string]::IsNullOrWhiteSpace($status)
}

function Show-ModifiedFiles {

    Write-Section "Modified Files"

    Invoke-Git "status --short"
}

function Get-StableBranch {

    Push-Location $ComfyPath

    try {

        $masterExists = git branch --list master

        if (-not [string]::IsNullOrWhiteSpace($masterExists)) {
            return "master"
        }

        $mainExists = git branch --list main

        if (-not [string]::IsNullOrWhiteSpace($mainExists)) {
            return "main"
        }

        throw "Could not detect master/main branch."
    }
    finally {
        Pop-Location
    }
}

function Try-GetRemoteCommit {
    param([string]$Branch)

    try {

        $commit = Invoke-Git "rev-parse --short origin/$Branch"

        if ([string]::IsNullOrWhiteSpace($commit)) {
            return $null
        }

        return $commit.Trim()
    }
    catch {
        return $null
    }
}

function Get-LatestCommitMessage {
    param([string]$Branch)

    try {
        return ((Invoke-Git "log HEAD..origin/$Branch --oneline -1").Trim())
    }
    catch {
        return $null
    }
}

function Create-BackupBranch {

    $timestamp = Get-Date -Format "yyyy_MM_dd_HHmmss"
    $backupBranch = "backup/pre_update_$timestamp"

    Write-Host "Creating rollback branch: $backupBranch" -ForegroundColor Yellow

    Invoke-Git "branch $backupBranch" | Out-Null
}

# ----------------------------------------------------------------------------
# GIT VERSION VALIDATION
# ----------------------------------------------------------------------------

function Test-GitVersion {

    Write-Section "Git Environment"

    $gitVersion = git --version 2>&1
    $gitPath = where.exe git 2>&1

    Write-Host "Git Version : $gitVersion"
    Write-Host "Git Path    : $gitPath"
    Write-Host ""

    $match = [regex]::Match($gitVersion, '(\d+)\.(\d+)')

    if ($match.Success) {

        $major = [int]$match.Groups[1].Value
        $minor = [int]$match.Groups[2].Value

        if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 30)) {

            Write-Banner "WARNING: OUTDATED GIT DETECTED" "Red"

            Write-Host "Old Git versions can break:"
            Write-Host " - PR branch handling"
            Write-Host " - upstream tracking"
            Write-Host " - fetch operations"
            Write-Host ""

            Write-Host "Updating system Git affects ALL applications using Git." -ForegroundColor Yellow
            Write-Host ""

            Write-Host "1 - Open Git for Windows download page"
            Write-Host "2 - Continue anyway"
            Write-Host "3 - Exit"
            Write-Host ""

            $choice = Read-Host "Select option"

            switch ($choice) {

                "1" {
                    Start-Process "https://gitforwindows.org"
                    exit
                }

                "2" { }

                default {
                    exit
                }
            }
        }
    }
}

# ----------------------------------------------------------------------------
# NETWORK VALIDATION
# ----------------------------------------------------------------------------

function Test-GitHubConnection {
    param([int]$DurationSeconds)

    Write-Section "Testing GitHub Connection ($DurationSeconds sec)"

    $client = New-Object System.Net.WebClient
    $buffer = New-Object byte[] 4096

    $stream = $client.OpenRead($GitHubTestURL)

    $samples = @()

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $sampleTimer = [System.Diagnostics.Stopwatch]::StartNew()

    $bytesThisSecond = 0

    while ($sw.Elapsed.TotalSeconds -lt $DurationSeconds) {

        $read = $stream.Read($buffer, 0, $buffer.Length)

        if ($read -le 0) {
            break
        }

        $bytesThisSecond += $read

        if ($sampleTimer.Elapsed.TotalSeconds -ge 1) {

            $mbps = ($bytesThisSecond / 1MB)

            $samples += $mbps

            Write-Host ("  Sample: {0:N2} MB/s" -f $mbps)

            $bytesThisSecond = 0
            $sampleTimer.Restart()
        }
    }

    $stream.Close()

    $avg = ($samples | Measure-Object -Average).Average
    $min = ($samples | Measure-Object -Minimum).Minimum
    $max = ($samples | Measure-Object -Maximum).Maximum

    return @{
        Average = [math]::Round($avg,2)
        Minimum = [math]::Round($min,2)
        Maximum = [math]::Round($max,2)
        Variance = [math]::Round(($max - $min),2)
    }
}

function Handle-NetworkValidation {

    $result = Test-GitHubConnection -DurationSeconds $InitialTestSeconds

    Write-Host ""
    Write-Host ("Average : {0} MB/s" -f $result.Average)
    Write-Host ("Minimum : {0} MB/s" -f $result.Minimum)
    Write-Host ("Maximum : {0} MB/s" -f $result.Maximum)
    Write-Host ("Variance: {0}" -f $result.Variance)
    Write-Host ""

    $unstable = $result.Variance -gt ($result.Average * 0.75)

    if ($unstable) {

        Write-Host "Connection unstable. Running extended 30-second test..." -ForegroundColor Yellow

        $result = Test-GitHubConnection -DurationSeconds $ExtendedTestSeconds
    }

    if ($result.Average -lt $SpeedThresholdMB) {

        Write-Banner "WARNING: SLOW OR UNSTABLE GITHUB CONNECTION" "Red"

        Write-Host ("Average Speed: {0} MB/s" -f $result.Average)
        Write-Host ""

        Write-Host "Updates may partially fail or corrupt dependencies."
        Write-Host ""

        Write-Host "1 - Proceed anyway"
        Write-Host "2 - Exit"
        Write-Host ""

        $choice = Read-Host "Select option"

        if ($choice -ne "1") {
            exit
        }
    }
    else {

        Write-Host ("GitHub connection is GOOD ({0} MB/s)." -f $result.Average) -ForegroundColor Green
    }
}

# ----------------------------------------------------------------------------
# FORCE CLEANUP
# ----------------------------------------------------------------------------

function Force-CleanupWorkingTree {

    Write-Banner "FORCE CLEANUP MODE" "Red"

    Write-Host "THIS OPERATION WILL DELETE:" -ForegroundColor Red
    Write-Host ""
    Write-Host " - uncommitted repo changes"
    Write-Host " - PR leftovers"
    Write-Host " - temporary Git debris"
    Write-Host ""

    Write-Host "PROTECTED FROM CLEANUP:" -ForegroundColor Green
    Write-Host ""

    foreach ($path in $GitProtectedPaths) {
        Write-Host " - $path"
    }

    Write-Host ""

    Write-Host "1 - CONFIRM FORCE CLEANUP"
    Write-Host "2 - Cancel"
    Write-Host ""

    $confirm = Read-Host "Select option"

    if ($confirm -ne "1") {
        exit
    }

    Write-Section "Cleaning Working Tree"

    Invoke-Git "reset --hard" | Out-Null

    $excludeArgs = $GitProtectedPaths | ForEach-Object {
        "-e $_"
    }

    $excludeString = $excludeArgs -join " "

    Invoke-Git "clean -fd $excludeString" | Out-Null
}

# ----------------------------------------------------------------------------
# SYMLINK PROTECTION
# ----------------------------------------------------------------------------

function Backup-ProtectedFolders {

    Write-Section "Backing Up Protected Folders"

    foreach ($folder in $FoldersToProtect) {

        $path = Join-Path $ComfyPath $folder

        if (-not (Test-Path $path)) {
            throw "Missing required folder: $folder"
        }

        Write-Host "Renaming $folder -> ${folder}_backup"

        Rename-Item $path "${folder}_backup"
    }
}

function Cleanup-UpdaterFolders {

    Write-Section "Removing Updater-Created Folders"

    foreach ($folder in $FoldersToProtect) {

        $path = Join-Path $ComfyPath $folder

        if (Test-Path $path) {

            Write-Host "Removing $folder"

            Remove-Item $path -Recurse -Force
        }
    }
}

function Restore-ProtectedFolders {

    Write-Section "Restoring Protected Folders"

    foreach ($folder in $FoldersToProtect) {

        $backup = Join-Path $ComfyPath "${folder}_backup"

        if (Test-Path $backup) {

            Write-Host "Restoring ${folder}_backup -> $folder"

            Rename-Item $backup $folder
        }
    }
}

# ----------------------------------------------------------------------------
# UPDATE EXECUTION
# ----------------------------------------------------------------------------

function Run-Update {

    Backup-ProtectedFolders

    try {

        Write-Section "Running ComfyUI Update"

        Push-Location $UpdateDir

        try {

            cmd /c update_comfyui.bat

            if ($LASTEXITCODE -ne 0) {
                throw "update_comfyui.bat failed."
            }
        }
        finally {
            Pop-Location
        }

        Cleanup-UpdaterFolders
    }
    finally {

        Restore-ProtectedFolders
    }
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------

Clear-Host

Write-Banner "ComfyUI Safe Update Manager v5" "Cyan"

Test-GitVersion

if (-not (Test-Path $ComfyPath)) {
    throw "ComfyUI folder not found: $ComfyPath"
}

Push-Location $ComfyPath

try {

    Write-Section "Fetching Remote Information"

    git fetch origin | Out-Null

    $currentBranch = Get-CurrentBranch
    $currentCommit = Get-CurrentCommit

    $stableBranch = Get-StableBranch

    $isStable = ($currentBranch -eq "master" -or $currentBranch -eq "main")

    if ($isStable) {

        $remoteCommit = Try-GetRemoteCommit -Branch $stableBranch

        if (-not $remoteCommit) {
            $remoteCommit = "UNKNOWN"
        }

        $latestMsg = Get-LatestCommitMessage -Branch $stableBranch

        Write-Banner "BRANCH: $($stableBranch.ToUpper())" "Green"

        Write-Host ("Current Commit : {0}" -f $currentCommit) -ForegroundColor Green
        Write-Host ("Updating To    : {0}" -f $remoteCommit) -ForegroundColor Green

        if (-not [string]::IsNullOrWhiteSpace($latestMsg)) {
            Write-Host ("Latest Change  : {0}" -f $latestMsg) -ForegroundColor Green
        }

        if ($currentCommit -eq $remoteCommit) {

            Write-Host ""
            Write-Host "ComfyUI is already up to date." -ForegroundColor Green

            pause
            exit
        }

        Handle-NetworkValidation

        Run-Update
    }
    else {

        $remoteCommit = Try-GetRemoteCommit -Branch $currentBranch

        if (-not $remoteCommit) {
            $remoteCommit = "NO REMOTE TRACKING"
        }

        Write-Banner "WARNING: PR / EXPERIMENTAL BRANCH DETECTED" "Red"

        Write-Host ("Branch         : {0}" -f $currentBranch) -ForegroundColor Red
        Write-Host ("Current Commit : {0}" -f $currentCommit) -ForegroundColor Red
        Write-Host ("Remote Commit  : {0}" -f $remoteCommit) -ForegroundColor Red

        $dirty = Test-DirtyWorkingTree

        if ($dirty) {

            Write-Host ""
            Write-Host "WARNING: Uncommitted changes detected!" -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "1 - Update current PR / branch"
        Write-Host "2 - Return to $stableBranch and update"
        Write-Host "3 - Show modified files"
        Write-Host "4 - Exit"
        Write-Host ""

        $choice = Read-Host "Select option"

        switch ($choice) {

            "1" {

                Create-BackupBranch

                Handle-NetworkValidation

                Run-Update
            }

            "2" {

                Create-BackupBranch

                if ($dirty) {
                    Force-CleanupWorkingTree
                }

                Write-Section "Returning To Stable Branch"

                Invoke-Git "checkout $stableBranch" | Out-Null
                Invoke-Git "reset --hard origin/$stableBranch" | Out-Null

                Handle-NetworkValidation

                Run-Update
            }

            "3" {

                Show-ModifiedFiles

                pause
                exit
            }

            default {
                exit
            }
        }
    }

    Write-Banner "UPDATE COMPLETED SUCCESSFULLY" "Green"
}
finally {
    Pop-Location
}

pause
