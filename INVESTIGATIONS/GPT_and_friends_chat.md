Absolutely. One file, one replacement, no surgery on a tired brain. )))

I’ve also verified that 2026-03-10 is currently the supported GitHub REST API version, so the PR lookup header in the script is current.

Confidence: high (~95%) on the updater logic. I cannot execute the PowerShell against your actual ComfyUI tree here, so the remaining risk is environment-specific behavior of your update_comfyui.bat.

Replace the old .ps1 completely with this:

# ============================================================================
# ComfyUI Safe Update Manager v8
# ============================================================================
# Safe updater for ComfyUI portable installations
#
# v8:
# - Automatically restores protected folders after VERIFIED update
# - Does not restore blindly after failed/partial update
# - Stores persistent updater state
# - Shows all ComfyUI commits since previous successful run
# - Resolves actual GitHub PR numbers + titles
# - Caches PR lookups
# - Separates Git transport testing from HTTP download testing
# - Uses .NET HttpClient for bulk download speed testing
# - NO curl dependency
# - NO per-second speed sampling
# - NO bogus "variance = unstable" warning
# - Verifies final Git branch + exact expected commit
# - Keeps failed-update backups intact
# ============================================================================

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------------------
# CONFIG
# ----------------------------------------------------------------------------

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ComfyPath  = Join-Path $ScriptRoot "ComfyUI"
$UpdateDir  = Join-Path $ScriptRoot "update"

# Persistent updater state
$StateFile = Join-Path $UpdateDir "ComfyUI_SafeUpdateManager_State.json"

# Folders protected from updater replacement
$FoldersToProtect = @(
    "models",
    "output",
    "input"
)

# NEVER allow destructive Git cleanup to touch these
$GitProtectedPaths = @(
    "models",
    "input",
    "output",
    "temp",
    "custom_nodes",
    "user"
)

# Network
$SpeedThresholdMB = 5

# Number of complete archive transfers
$SpeedTestCount = 3

# Maximum time allowed for one archive transfer
$SpeedTestTimeoutSeconds = 30

# GitHub
$GitHubOwner = "Comfy-Org"
$GitHubRepo  = "ComfyUI"

# Current GitHub REST API version
$GitHubApiVersion = "2026-03-10"

# Keep this many successful updater runs
$MaxHistoryEntries = 50

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
    param(
        [string]$Text
    )

    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
}

function Write-WarningText {
    param(
        [string]$Text
    )

    Write-Host $Text -ForegroundColor Yellow
}

# ----------------------------------------------------------------------------
# GIT HELPERS
# ----------------------------------------------------------------------------

function Invoke-Git {
    param(
        [string]$Arguments
    )

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

    Push-Location $ComfyPath

    try {
        return ((git rev-parse HEAD 2>&1).Trim())
    }
    finally {
        Pop-Location
    }
}

function Get-ShortCommit {
    param(
        [string]$Commit
    )

    if ([string]::IsNullOrWhiteSpace($Commit)) {
        return $null
    }

    if ($Commit.Length -gt 12) {
        return $Commit.Substring(0, 12)
    }

    return $Commit
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
    param(
        [string]$Branch
    )

    try {

        Push-Location $ComfyPath

        try {
            $commit = git rev-parse "origin/$Branch" 2>&1
        }
        finally {
            Pop-Location
        }

        if ([string]::IsNullOrWhiteSpace($commit)) {
            return $null
        }

        if ($commit -match "^fatal:") {
            return $null
        }

        return $commit.Trim()
    }
    catch {
        return $null
    }
}

function Get-LatestCommitMessage {
    param(
        [string]$Branch
    )

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

    return $backupBranch
}

# ----------------------------------------------------------------------------
# GIT HISTORY
# ----------------------------------------------------------------------------

function Get-CommitHistoryBetween {
    param(
        [string]$FromCommit,
        [string]$ToCommit
    )

    if ([string]::IsNullOrWhiteSpace($FromCommit) -or
        [string]::IsNullOrWhiteSpace($ToCommit)) {

        return @()
    }

    if ($FromCommit -eq $ToCommit) {
        return @()
    }

    Push-Location $ComfyPath

    try {

        $lines = @(
            git log "$FromCommit..$ToCommit" `
                --format="%H`t%h`t%aI`t%an`t%s" `
                2>&1
        )

        $result = New-Object System.Collections.Generic.List[object]

        foreach ($line in $lines) {

            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            if ($line -match "^fatal:") {
                continue
            }

            $parts = $line -split "`t", 5

            if ($parts.Count -lt 5) {
                continue
            }

            $result.Add(
                [PSCustomObject]@{
                    Commit      = $parts[0]
                    ShortCommit = $parts[1]
                    Date        = $parts[2]
                    Author      = $parts[3]
                    Subject     = $parts[4]
                }
            )
        }

        return @($result)
    }
    finally {
        Pop-Location
    }
}

# ----------------------------------------------------------------------------
# PERSISTENT STATE
# ----------------------------------------------------------------------------

function New-DefaultState {

    return [PSCustomObject]@{
        SchemaVersion     = 3
        LastSuccessfulRun = $null
        History           = @()
        PRCache           = [PSCustomObject]@{}
    }
}

function Load-UpdaterState {

    if (-not (Test-Path -LiteralPath $StateFile)) {
        return New-DefaultState
    }

    try {

        $raw = Get-Content `
            -LiteralPath $StateFile `
            -Raw `
            -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($raw)) {
            return New-DefaultState
        }

        $state = $raw | ConvertFrom-Json

        if ($null -eq $state.SchemaVersion) {
            return New-DefaultState
        }

        if ($null -eq $state.PSObject.Properties["History"]) {

            $state | Add-Member `
                -MemberType NoteProperty `
                -Name History `
                -Value @()
        }

        if ($null -eq $state.PSObject.Properties["PRCache"]) {

            $state | Add-Member `
                -MemberType NoteProperty `
                -Name PRCache `
                -Value ([PSCustomObject]@{})
        }

        $state.SchemaVersion = 3

        return $state
    }
    catch {

        Write-WarningText "WARNING: Could not read updater state file."
        Write-WarningText "A new state file will be created."

        return New-DefaultState
    }
}

function Save-UpdaterState {
    param(
        [object]$State
    )

    if (-not (Test-Path -LiteralPath $UpdateDir)) {

        New-Item `
            -ItemType Directory `
            -Path $UpdateDir `
            -Force | Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 15

    $tempFile = "$StateFile.tmp"

    Set-Content `
        -LiteralPath $tempFile `
        -Value $json `
        -Encoding UTF8

    Move-Item `
        -LiteralPath $tempFile `
        -Destination $StateFile `
        -Force
}

function Add-HistoryEntry {
    param(
        [object]$State,
        [object]$Entry
    )

    $history = @()

    if ($null -ne $State.History) {
        $history = @($State.History)
    }

    $history += $Entry

    if ($history.Count -gt $MaxHistoryEntries) {

        $start = $history.Count - $MaxHistoryEntries

        $history = @(
            $history[$start..($history.Count - 1)]
        )
    }

    $State.History = $history
}

# ----------------------------------------------------------------------------
# GITHUB PR LOOKUP
# ----------------------------------------------------------------------------
#
# Uses:
#
# GET /repos/{owner}/{repo}/commits/{commit_sha}/pulls
#
# GitHub returns the actual associated pull request(s), including:
# - PR number
# - PR title
# - state
# - merged date
# - URL
# - author
#
# Results are cached per commit.
# ----------------------------------------------------------------------------

function Get-CachedPRInfo {
    param(
        [object]$State,
        [string]$Commit
    )

    if ($null -eq $State.PRCache) {
        return $null
    }

    $property =
        $State.PRCache.PSObject.Properties[$Commit]

    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Set-CachedPRInfo {
    param(
        [object]$State,
        [string]$Commit,
        [object]$Value
    )

    if ($null -eq $State.PRCache) {

        $State | Add-Member `
            -MemberType NoteProperty `
            -Name PRCache `
            -Value ([PSCustomObject]@{})
    }

    $State.PRCache | Add-Member `
        -MemberType NoteProperty `
        -Name $Commit `
        -Value $Value `
        -Force
}

function Get-GitHubPRInfo {
    param(
        [object]$State,
        [string]$Commit
    )

    $cached =
        Get-CachedPRInfo `
            -State $State `
            -Commit $Commit

    if ($null -ne $cached) {
        return @($cached)
    }

    $uri =
        "https://api.github.com/repos/" +
        "$GitHubOwner/$GitHubRepo/commits/" +
        "$Commit/pulls"

    try {

        $headers = @{
            "Accept"                = "application/vnd.github+json"
            "X-GitHub-Api-Version" = $GitHubApiVersion
            "User-Agent"            = "ComfyUI-Safe-Update-Manager"
        }

        $response =
            Invoke-RestMethod `
                -Uri $uri `
                -Method Get `
                -Headers $headers `
                -TimeoutSec 15

        $items =
            New-Object System.Collections.Generic.List[object]

        foreach ($pr in @($response)) {

            $items.Add(
                [PSCustomObject]@{
                    Number   = [int]$pr.number
                    Title    = [string]$pr.title
                    State    = [string]$pr.state
                    MergedAt = [string]$pr.merged_at
                    URL      = [string]$pr.html_url
                    User     = [string]$pr.user.login
                    Draft    = [bool]$pr.draft
                }
            )
        }

        $result =
            @($items.ToArray())

        Set-CachedPRInfo `
            -State $State `
            -Commit $Commit `
            -Value $result

        return $result
    }
    catch {

        Write-WarningText (
            "PR lookup failed for {0}: {1}" -f `
            (Get-ShortCommit $Commit),
            $_.Exception.Message
        )

        # Cache the failure as an empty result so repeated runs don't
        # hammer the API for the same commit.
        Set-CachedPRInfo `
            -State $State `
            -Commit $Commit `
            -Value @()

        return @()
    }
}

function Resolve-CommitPRs {
    param(
        [object]$State,
        [object[]]$Commits
    )

    foreach ($commit in $Commits) {

        $prs =
            @(Get-GitHubPRInfo `
                -State $State `
                -Commit $commit.Commit)

        $commit | Add-Member `
            -MemberType NoteProperty `
            -Name PRs `
            -Value $prs `
            -Force
    }

    return @($Commits)
}

# ----------------------------------------------------------------------------
# UPDATE HISTORY DISPLAY
# ----------------------------------------------------------------------------

function Show-UpdatesSinceLastRun {
    param(
        [object]$State,
        [string]$CurrentBranch,
        [string]$RemoteCommit
    )

    if ($null -eq $State.LastSuccessfulRun) {

        Write-Section "Update History"

        Write-Host "No previous successful updater run is recorded."
        Write-Host "This run will establish the initial history baseline."

        return
    }

    $previousBranch = $State.LastSuccessfulRun.Branch
    $previousCommit = $State.LastSuccessfulRun.Commit

    Write-Section "Changes Since Last Successful Run"

    Write-Host (
        "Previous Run   : {0}" -f
        $State.LastSuccessfulRun.Timestamp
    )

    Write-Host (
        "Previous Branch: {0}" -f
        $previousBranch
    )

    Write-Host (
        "Previous Commit: {0}" -f
        (Get-ShortCommit $previousCommit)
    )

    Write-Host (
        "Current Branch : {0}" -f
        $CurrentBranch
    )

    Write-Host (
        "Current Remote : {0}" -f
        (Get-ShortCommit $RemoteCommit)
    )

    Write-Host ""

    if ([string]::IsNullOrWhiteSpace($previousCommit)) {

        Write-Host "Previous commit is unavailable."
        return
    }

    $commits =
        @(Get-CommitHistoryBetween `
            -FromCommit $previousCommit `
            -ToCommit $RemoteCommit)

    if ($commits.Count -eq 0) {

        if ($previousCommit -eq $RemoteCommit) {

            Write-Host `
                "No new ComfyUI commits since the previous run." `
                -ForegroundColor Green
        }
        else {

            Write-Host `
                "No directly comparable commit history was found." `
                -ForegroundColor Yellow

            Write-Host `
                "This may indicate a branch rewrite or force-push."
        }

        return
    }

    Write-Host (
        "ComfyUI updates found: {0}" -f
        $commits.Count
    ) -ForegroundColor Green

    Write-Host ""
    Write-Host `
        "Resolving GitHub pull requests..." `
        -ForegroundColor Cyan
    Write-Host ""

    $commits =
        @(Resolve-CommitPRs `
            -State $State `
            -Commits $commits)

    # Save PR cache immediately.
    Save-UpdaterState $State

    foreach ($commit in $commits) {

        $dateText = $commit.Date

        if ($dateText.Length -gt 19) {
            $dateText =
                $dateText.Substring(0, 19)
        }

        Write-Host (
            "{0}  {1}" -f
            $commit.ShortCommit,
            $dateText
        ) -ForegroundColor DarkGray

        Write-Host (
            "       {0}" -f
            $commit.Subject
        )

        if ($commit.PRs.Count -gt 0) {

            foreach ($pr in @($commit.PRs)) {

                Write-Host (
                    "       PR #{0}: {1}" -f
                    $pr.Number,
                    $pr.Title
                ) -ForegroundColor Cyan

                Write-Host (
                    "       {0}" -f
                    $pr.URL
                ) -ForegroundColor DarkCyan
            }
        }
        else {

            Write-Host `
                "       PR: no associated PR reported by GitHub" `
                -ForegroundColor DarkGray
        }

        Write-Host (
            "       Author: {0}" -f
            $commit.Author
        ) -ForegroundColor DarkGray

        Write-Host ""
    }
}

# ----------------------------------------------------------------------------
# GIT VERSION
# ----------------------------------------------------------------------------

function Test-GitVersion {

    Write-Section "Git Environment"

    $gitVersion =
        git --version 2>&1

    $gitPath =
        where.exe git 2>&1

    Write-Host "Git Version : $gitVersion"
    Write-Host "Git Path    : $gitPath"
    Write-Host ""

    $match =
        [regex]::Match(
            $gitVersion,
            '(\d+)\.(\d+)'
        )

    if ($match.Success) {

        $major =
            [int]$match.Groups[1].Value

        $minor =
            [int]$match.Groups[2].Value

        if (
            $major -lt 2 -or
            ($major -eq 2 -and $minor -lt 30)
        ) {

            Write-Banner `
                "WARNING: OUTDATED GIT DETECTED" `
                "Red"

            Write-Host "Old Git versions can break:"
            Write-Host " - PR branch handling"
            Write-Host " - upstream tracking"
            Write-Host " - fetch operations"
            Write-Host ""

            Write-Host `
                "Updating system Git affects ALL applications using Git." `
                -ForegroundColor Yellow

            Write-Host ""

            Write-Host "1 - Open Git for Windows download page"
            Write-Host "2 - Continue anyway"
            Write-Host "3 - Exit"
            Write-Host ""

            $choice =
                Read-Host "Select option"

            switch ($choice) {

                "1" {
                    Start-Process "https://gitforwindows.org"
                    exit
                }

                "2" {
                    # Continue
                }

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

function Test-GitConnectivity {

    Write-Section "Testing GitHub Git Connectivity"

    $sw =
        [System.Diagnostics.Stopwatch]::StartNew()

    try {

        Push-Location $ComfyPath

        try {

            git ls-remote `
                "https://github.com/$GitHubOwner/$GitHubRepo.git" `
                HEAD 2>&1 | Out-Null

            $exitCode =
                $LASTEXITCODE
        }
        finally {
            Pop-Location
        }

        $sw.Stop()

        if ($exitCode -eq 0) {

            Write-Host (
                "Git transport: OK ({0:N2} sec)" -f
                $sw.Elapsed.TotalSeconds
            ) -ForegroundColor Green

            return $true
        }

        Write-Host `
            "Git transport: FAILED" `
            -ForegroundColor Red

        return $false
    }
    catch {

        $sw.Stop()

        Write-Host `
            "Git transport: FAILED" `
            -ForegroundColor Red

        Write-WarningText `
            $_.Exception.Message

        return $false
    }
}

function Get-SpeedStatistics {
    param(
        [System.Collections.Generic.List[double]]$Values
    )

    if (
        $null -eq $Values -or
        $Values.Count -eq 0
    ) {

        return [PSCustomObject]@{
            Success = $false
            Count   = 0
            Average = 0
            Median  = 0
            Minimum = 0
            Maximum = 0
        }
    }

    $sorted =
        @(
            $Values | Sort-Object
        )

    $average =
        ($Values | Measure-Object -Average).Average

    $minimum =
        $sorted[0]

    $maximum =
        $sorted[$sorted.Count - 1]

    if (($sorted.Count % 2) -eq 1) {

        $median =
            $sorted[
                [math]::Floor(
                    $sorted.Count / 2
                )
            ]
    }
    else {

        $mid =
            [int](
                $sorted.Count / 2
            )

        $median =
            (
                $sorted[$mid - 1] +
                $sorted[$mid]
            ) / 2
    }

    return [PSCustomObject]@{
        Success = $true
        Count   = $Values.Count
        Average = [math]::Round($average, 2)
        Median  = [math]::Round($median, 2)
        Minimum = [math]::Round($minimum, 2)
        Maximum = [math]::Round($maximum, 2)
    }
}

function Test-GitHubBulkDownload {
    param(
        [string]$Branch
    )

    Write-Section "Testing GitHub Bulk Download Speed"

    Write-Host `
        "Testing the actual ComfyUI repository archive."

    Write-Host `
        "Each test measures a complete transfer."

    Write-Host `
        "No curl dependency is used."

    Write-Host ""

    # GitHub codeload endpoint.
    #
    # Using the branch actually being updated makes this work for:
    # - master
    # - main
    # - tracked PR branches
    # - tracked experimental branches
    $baseUrl =
        "https://codeload.github.com/" +
        "$GitHubOwner/$GitHubRepo/zip/refs/heads/$Branch"

    $results =
        New-Object System.Collections.Generic.List[double]

    $handler =
        New-Object System.Net.Http.HttpClientHandler

    $handler.AllowAutoRedirect =
        $true

    $handler.AutomaticDecompression =
        [System.Net.DecompressionMethods]::None

    $client =
        New-Object System.Net.Http.HttpClient(
            $handler
        )

    $client.Timeout =
        [TimeSpan]::FromSeconds(
            $SpeedTestTimeoutSeconds
        )

    try {

        for (
            $i = 1;
            $i -le $SpeedTestCount;
            $i++
        ) {

            Write-Host (
                "  Test {0}/{1}..." -f
                $i,
                $SpeedTestCount
            )

            $response = $null
            $stream   = $null
            $request  = $null

            try {

                # Cache-busting query parameter.
                $cacheBust =
                    [guid]::NewGuid().ToString()

                $url =
                    "$baseUrl?speedtest=$cacheBust"

                $request =
                    New-Object System.Net.Http.HttpRequestMessage(
                        [System.Net.Http.HttpMethod]::Get,
                        $url
                    )

                $request.Headers.UserAgent.ParseAdd(
                    "ComfyUI-Safe-Update-Manager/8"
                )

                $sw =
                    [System.Diagnostics.Stopwatch]::StartNew()

                $response =
                    $client.SendAsync(
                        $request,
                        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                    ).GetAwaiter().GetResult()

                $response.EnsureSuccessStatusCode()

                $stream =
                    $response.Content.ReadAsStreamAsync().
                        GetAwaiter().GetResult()

                # 1 MiB buffer:
                # low overhead, negligible RAM use.
                $buffer =
                    New-Object byte[] (
                        1024 * 1024
                    )

                [long]$totalBytes = 0

                while ($true) {

                    $read =
                        $stream.Read(
                            $buffer,
                            0,
                            $buffer.Length
                        )

                    if ($read -le 0) {
                        break
                    }

                    $totalBytes += $read
                }

                $sw.Stop()

                if (
                    $totalBytes -le 0 -or
                    $sw.Elapsed.TotalSeconds -le 0
                ) {

                    Write-Host `
                        "       Invalid transfer result." `
                        -ForegroundColor Yellow

                    continue
                }

                $mbps =
                    (
                        $totalBytes / 1MB
                    ) /
                    $sw.Elapsed.TotalSeconds

                $results.Add($mbps)

                Write-Host (
                    "       {0:N2} MB/s  |  {1:N2} MB  |  {2:N2} sec" -f
                    $mbps,
                    ($totalBytes / 1MB),
                    $sw.Elapsed.TotalSeconds
                ) -ForegroundColor Green
            }
            catch {

                Write-Host (
                    "       FAILED: {0}" -f
                    $_.Exception.Message
                ) -ForegroundColor Yellow
            }
            finally {

                if ($null -ne $stream) {
                    $stream.Dispose()
                }

                if ($null -ne $response) {
                    $response.Dispose()
                }

                if ($null -ne $request) {
                    $request.Dispose()
                }
            }
        }
    }
    finally {

        $client.Dispose()
        $handler.Dispose()
    }

    return @(
        Get-SpeedStatistics $results
    )
}

function Handle-NetworkValidation {
    param(
        [string]$Branch
    )

    $gitOK =
        Test-GitConnectivity

    Write-Host ""

    $result =
        Test-GitHubBulkDownload `
            -Branch $Branch

    Write-Host ""

    if (-not $result.Success) {

        Write-Banner `
            "WARNING: GITHUB DOWNLOAD TEST FAILED" `
            "Red"

        Write-Host `
            "No valid bulk download measurement was obtained."

        Write-Host ""

        Write-Host `
            "This does NOT mean the connection is unstable." `
            -ForegroundColor Yellow

        Write-Host `
            "It means the speed test itself could not complete."

        if (-not $gitOK) {

            Write-Host ""

            Write-Host `
                "Git transport testing also failed." `
                -ForegroundColor Red
        }

        Write-Host ""
        Write-Host "1 - Proceed anyway"
        Write-Host "2 - Exit"
        Write-Host ""

        $choice =
            Read-Host "Select option"

        if ($choice -ne "1") {
            exit
        }

        return
    }

    Write-Host (
        "Successful Tests: {0}" -f
        $result.Count
    )

    Write-Host (
        "Average         : {0} MB/s" -f
        $result.Average
    )

    Write-Host (
        "Median          : {0} MB/s" -f
        $result.Median
    )

    Write-Host (
        "Minimum         : {0} MB/s" -f
        $result.Minimum
    )

    Write-Host (
        "Maximum         : {0} MB/s" -f
        $result.Maximum
    )

    Write-Host ""

    # IMPORTANT:
    #
    # There is deliberately NO min/max variance -> "unstable" rule.
    #
    # Internet throughput naturally varies.
    # Median is the primary update-safety metric.

    if ($result.Median -lt $SpeedThresholdMB) {

        Write-Banner `
            "WARNING: SLOW GITHUB CONNECTION" `
            "Red"

        Write-Host (
            "Median Speed: {0} MB/s" -f
            $result.Median
        )

        Write-Host (
            "Threshold   : {0} MB/s" -f
            $SpeedThresholdMB
        )

        Write-Host ""

        Write-Host `
            "GitHub is reachable, but measured throughput is below"
        Write-Host `
            "the configured update threshold."

        Write-Host ""
        Write-Host "1 - Proceed anyway"
        Write-Host "2 - Exit"
        Write-Host ""

        $choice =
            Read-Host "Select option"

        if ($choice -ne "1") {
            exit
        }

        return
    }

    if ($gitOK) {

        Write-Host (
            "GitHub connection is GOOD (median {0} MB/s)." -f
            $result.Median
        ) -ForegroundColor Green
    }
    else {

        Write-Banner `
            "GITHUB DOWNLOAD OK - GIT TRANSPORT PROBLEM" `
            "Yellow"

        Write-Host (
            "Bulk download median: {0} MB/s" -f
            $result.Median
        )

        Write-Host ""
        Write-Host `
            "HTTP download works, but git ls-remote failed."

        Write-Host `
            "The updater itself uses Git."

        Write-Host ""
        Write-Host "1 - Proceed anyway"
        Write-Host "2 - Exit"
        Write-Host ""

        $choice =
            Read-Host "Select option"

        if ($choice -ne "1") {
            exit
        }
    }
}

# ----------------------------------------------------------------------------
# FORCE CLEANUP
# ----------------------------------------------------------------------------

function Force-CleanupWorkingTree {

    Write-Banner `
        "FORCE CLEANUP MODE" `
        "Red"

    Write-Host `
        "THIS OPERATION WILL DELETE:" `
        -ForegroundColor Red

    Write-Host ""
    Write-Host " - uncommitted repo changes"
    Write-Host " - PR leftovers"
    Write-Host " - temporary Git debris"
    Write-Host ""

    Write-Host `
        "PROTECTED FROM CLEANUP:" `
        -ForegroundColor Green

    Write-Host ""

    foreach ($path in $GitProtectedPaths) {
        Write-Host " - $path"
    }

    Write-Host ""

    Write-Host "1 - CONFIRM FORCE CLEANUP"
    Write-Host "2 - Cancel"
    Write-Host ""

    $confirm =
        Read-Host "Select option"

    if ($confirm -ne "1") {
        exit
    }

    Write-Section "Cleaning Working Tree"

    Invoke-Git "reset --hard" |
        Out-Null

    $excludeArgs =
        $GitProtectedPaths |
        ForEach-Object {
            "-e $_"
        }

    $excludeString =
        $excludeArgs -join " "

    Invoke-Git "clean -fd $excludeString" |
        Out-Null
}

# ----------------------------------------------------------------------------
# PROTECTED FOLDER HANDLING
# ----------------------------------------------------------------------------
#
# We protect the folders regardless of whether they are:
# - normal directories
# - symlinks
# - junctions
#
# Reparse-point status is only reported for information.
#
# This preserves the original safety semantics and avoids accidentally
# restoring only symlinks while treating physical folders differently.
# ----------------------------------------------------------------------------

function Test-IsReparsePoint {
    param(
        [string]$Path
    )

    if (
        -not (
            Test-Path `
                -LiteralPath $Path `
                -Force
        )
    ) {
        return $false
    }

    try {

        $item =
            Get-Item `
                -LiteralPath $Path `
                -Force

        return (
            (
                $item.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint
            ) -ne 0
        )
    }
    catch {

        return $false
    }
}

function Backup-ProtectedFolders {

    Write-Section "Protecting Protected Folders"

    $protected =
        New-Object System.Collections.Generic.List[object]

    foreach ($folder in $FoldersToProtect) {

        $path =
            Join-Path `
                $ComfyPath `
                $folder

        if (
            -not (
                Test-Path `
                    -LiteralPath $path `
                    -Force
            )
        ) {

            Write-Host (
                "Not present: {0}" -f
                $folder
            )

            continue
        }

        $backupName =
            "${folder}_backup"

        $backupPath =
            Join-Path `
                $ComfyPath `
                $backupName

        if (
            Test-Path `
                -LiteralPath $backupPath `
                -Force
        ) {

            throw (
                "Backup path already exists: {0}`n" +
                "Refusing to overwrite it."
            ) -f $backupPath
        }

        $typeText =
            "folder"

        if (Test-IsReparsePoint $path) {
            $typeText =
                "symlink/junction"
        }

        Write-Host (
            "Protecting {0} ({1}) -> {2}" -f
            $folder,
            $typeText,
            $backupName
        ) -ForegroundColor Yellow

        Rename-Item `
            -LiteralPath $path `
            -NewName $backupName

        $protected.Add(
            [PSCustomObject]@{
                Folder     = $folder
                BackupName = $backupName
                BackupPath = $backupPath
                Type       = $typeText
            }
        )
    }

    return @($protected)
}

function Cleanup-UpdaterFolders {

    Write-Section `
        "Removing Updater-Created Protected Folder Copies"

    foreach ($folder in $FoldersToProtect) {

        $path =
            Join-Path `
                $ComfyPath `
                $folder

        if (
            Test-Path `
                -LiteralPath $path `
                -Force
        ) {

            Write-Host (
                "Removing updater-created: {0}" -f
                $folder
            )

            Remove-Item `
                -LiteralPath $path `
                -Recurse `
                -Force
        }
    }
}

function Restore-ProtectedFolders {
    param(
        [object[]]$ProtectedFolders
    )

    Write-Section "Restoring Protected Folders"

    foreach ($entry in $ProtectedFolders) {

        $backupPath =
            $entry.BackupPath

        $targetPath =
            Join-Path `
                $ComfyPath `
                $entry.Folder

        if (
            -not (
                Test-Path `
                    -LiteralPath $backupPath `
                    -Force
            )
        ) {

            throw (
                "Backup missing for protected folder: {0}" -f
                $entry.Folder
            )
        }

        if (
            Test-Path `
                -LiteralPath $targetPath `
                -Force
        ) {

            Write-Host (
                "Removing updater-created {0}" -f
                $entry.Folder
            )

            Remove-Item `
                -LiteralPath $targetPath `
                -Recurse `
                -Force
        }

        Write-Host (
            "Restoring {0} -> {1}" -f
            $entry.BackupName,
            $entry.Folder
        ) -ForegroundColor Green

        Rename-Item `
            -LiteralPath $backupPath `
            -NewName $entry.Folder

        if (
            -not (
                Test-Path `
                    -LiteralPath $targetPath `
                    -Force
            )
        ) {

            throw (
                "Restoration verification failed for: {0}" -f
                $entry.Folder
            )
        }
    }
}

function Show-BackupLocations {
    param(
        [object[]]$ProtectedFolders
    )

    Write-Host ""

    Write-Host `
        "The original protected folders were left as backups:" `
        -ForegroundColor Yellow

    Write-Host ""

    foreach ($entry in $ProtectedFolders) {

        Write-Host (
            " - {0}" -f
            $entry.BackupPath
        ) -ForegroundColor Yellow
    }

    Write-Host ""

    Write-Host `
        "Do NOT delete these backups until the failed update"

    Write-Host `
        "has been investigated."
}

# ----------------------------------------------------------------------------
# UPDATE VERIFICATION
# ----------------------------------------------------------------------------

function Test-UpdateSucceeded {
    param(
        [string]$ExpectedBranch,
        [string]$ExpectedCommit,
        [int]$UpdaterExitCode
    )

    Write-Section "Verifying Update"

    if ($UpdaterExitCode -ne 0) {

        Write-Host (
            "update_comfyui.bat exit code: {0}" -f
            $UpdaterExitCode
        ) -ForegroundColor Red

        return $false
    }

    $actualBranch =
        Get-CurrentBranch

    $actualCommit =
        Get-CurrentCommit

    Write-Host (
        "Expected Branch : {0}" -f
        $ExpectedBranch
    )

    Write-Host (
        "Actual Branch   : {0}" -f
        $actualBranch
    )

    Write-Host (
        "Expected Commit : {0}" -f
        (Get-ShortCommit $ExpectedCommit)
    )

    Write-Host (
        "Actual Commit   : {0}" -f
        (Get-ShortCommit $actualCommit)
    )

    Write-Host ""

    if ($actualBranch -ne $ExpectedBranch) {

        Write-Host `
            "UPDATE VERIFICATION FAILED:" `
            -ForegroundColor Red

        Write-Host `
            "The updater changed the active branch unexpectedly."

        return $false
    }

    if ($actualCommit -ne $ExpectedCommit) {

        Write-Host `
            "UPDATE VERIFICATION FAILED:" `
            -ForegroundColor Red

        Write-Host `
            "HEAD does not match the expected remote commit."

        return $false
    }

    Write-Host `
        "Git state verification: PASSED" `
        -ForegroundColor Green

    return $true
}

# ----------------------------------------------------------------------------
# UPDATE EXECUTION
# ----------------------------------------------------------------------------

function Run-Update {
    param(
        [string]$ExpectedBranch,
        [string]$ExpectedCommit
    )

    $protectedFolders = @()

    $preUpdateCommit =
        Get-CurrentCommit

    try {

        $protectedFolders =
            @(Backup-ProtectedFolders)

        Write-Section "Running ComfyUI Update"

        Push-Location $UpdateDir

        $updaterExitCode = 0

        try {

            cmd /c update_comfyui.bat

            $updaterExitCode =
                $LASTEXITCODE
        }
        finally {
            Pop-Location
        }

        Write-Host ""

        Write-Host (
            "update_comfyui.bat exit code: {0}" -f
            $updaterExitCode
        )

        # --------------------------------------------------------------------
        # VERY IMPORTANT:
        #
        # Do NOT restore the original folders merely because the BAT finished.
        # First verify that the update actually reached the requested commit.
        # --------------------------------------------------------------------

        $success =
            Test-UpdateSucceeded `
                -ExpectedBranch $ExpectedBranch `
                -ExpectedCommit $ExpectedCommit `
                -UpdaterExitCode $updaterExitCode

        if (-not $success) {

            Write-Banner `
                "UPDATE FAILED - PROTECTED FOLDERS LEFT SAFE" `
                "Red"

            Write-Host `
                "The resulting Git state could not be verified."

            Write-Host ""

            Write-Host `
                "The original protected folders have NOT been"
            Write-Host `
                "automatically reattached to a changed tree."

            Show-BackupLocations `
                $protectedFolders

            return @{
                Success          = $false
                PreUpdateCommit  = $preUpdateCommit
                PostUpdateCommit = Get-CurrentCommit
                Branch           = Get-CurrentBranch
                ProtectedFolders = $protectedFolders
            }
        }

        # --------------------------------------------------------------------
        # UPDATE VERIFIED.
        #
        # Now it is safe to remove updater-created physical folders and
        # restore the original folders/symlinks/junctions automatically.
        # --------------------------------------------------------------------

        Cleanup-UpdaterFolders

        Restore-ProtectedFolders `
            -ProtectedFolders $protectedFolders

        return @{
            Success          = $true
            PreUpdateCommit  = $preUpdateCommit
            PostUpdateCommit = Get-CurrentCommit
            Branch           = Get-CurrentBranch
            ProtectedFolders = $protectedFolders
        }
    }
    catch {

        Write-Banner `
            "UPDATE ERROR" `
            "Red"

        Write-Host `
            $_.Exception.Message `
            -ForegroundColor Red

        Write-Host ""

        if ($protectedFolders.Count -gt 0) {

            Show-BackupLocations `
                $protectedFolders
        }

        return @{
            Success          = $false
            PreUpdateCommit  = $preUpdateCommit
            PostUpdateCommit = Get-CurrentCommit
            Branch           = Get-CurrentBranch
            ProtectedFolders = $protectedFolders
        }
    }
}

# ----------------------------------------------------------------------------
# SAVE SUCCESSFUL RUN
# ----------------------------------------------------------------------------

function Save-SuccessfulRun {
    param(
        [object]$State,
        [string]$Branch,
        [string]$PreUpdateCommit,
        [string]$PostUpdateCommit,
        [bool]$UpdatePerformed
    )

    $timestamp =
        (Get-Date).ToString("o")

    $entry =
        [PSCustomObject]@{
            Timestamp          = $timestamp
            Branch             = $Branch
            UpdatePerformed    = $UpdatePerformed
            Commit             = $PostUpdateCommit
            CommitShort        = Get-ShortCommit $PostUpdateCommit
            VersionBefore      = $PreUpdateCommit
            VersionBeforeShort = Get-ShortCommit $PreUpdateCommit
            VersionAfter       = $PostUpdateCommit
            VersionAfterShort  = Get-ShortCommit $PostUpdateCommit
        }

    Add-HistoryEntry `
        -State $State `
        -Entry $entry

    $State.LastSuccessfulRun =
        $entry

    Save-UpdaterState `
        $State
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------

Clear-Host

Write-Banner `
    "ComfyUI Safe Update Manager v8" `
    "Cyan"

Test-GitVersion

if (
    -not (
        Test-Path `
            -LiteralPath $ComfyPath
    )
) {

    throw `
        "ComfyUI folder not found: $ComfyPath"
}

if (
    -not (
        Test-Path `
            -LiteralPath $UpdateDir
    )
) {

    throw `
        "Update folder not found: $UpdateDir"
}

$state =
    Load-UpdaterState

Push-Location $ComfyPath

try {

    Write-Section "Fetching Remote Information"

    git fetch origin

    $currentBranch =
        Get-CurrentBranch

    $currentCommit =
        Get-CurrentCommit

    $stableBranch =
        Get-StableBranch

    $isStable =
        (
            $currentBranch -eq "master" -or
            $currentBranch -eq "main"
        )

    # =========================================================================
    # STABLE BRANCH
    # =========================================================================

    if ($isStable) {

        $remoteCommit =
            Try-GetRemoteCommit `
                -Branch $stableBranch

        if (-not $remoteCommit) {

            throw `
                "Could not determine origin/$stableBranch commit."
        }

        # ---------------------------------------------------------------------
        # FIRST: show what changed since previous successful script run
        # ---------------------------------------------------------------------

        Show-UpdatesSinceLastRun `
            -State $state `
            -CurrentBranch $stableBranch `
            -RemoteCommit $remoteCommit

        $latestMsg =
            Get-LatestCommitMessage `
                -Branch $stableBranch

        Write-Banner `
            "BRANCH: $($stableBranch.ToUpper())" `
            "Green"

        Write-Host (
            "Current Commit : {0}" -f
            (Get-ShortCommit $currentCommit)
        ) -ForegroundColor Green

        Write-Host (
            "Updating To    : {0}" -f
            (Get-ShortCommit $remoteCommit)
        ) -ForegroundColor Green

        if (
            -not (
                [string]::IsNullOrWhiteSpace(
                    $latestMsg
                )
            )
        ) {

            Write-Host (
                "Latest Change  : {0}" -f
                $latestMsg
            ) -ForegroundColor Green
        }

        if ($currentCommit -eq $remoteCommit) {

            Write-Host ""

            Write-Host `
                "ComfyUI is already up to date." `
                -ForegroundColor Green

            # This still counts as a successful run and therefore becomes
            # the next "last run" baseline.
            Save-SuccessfulRun `
                -State $state `
                -Branch $currentBranch `
                -PreUpdateCommit $currentCommit `
                -PostUpdateCommit $currentCommit `
                -UpdatePerformed $false

            pause
            exit
        }

        # ---------------------------------------------------------------------
        # NETWORK TEST
        # ---------------------------------------------------------------------

        Handle-NetworkValidation `
            -Branch $stableBranch

        # ---------------------------------------------------------------------
        # UPDATE
        # ---------------------------------------------------------------------

        $updateResult =
            Run-Update `
                -ExpectedBranch $stableBranch `
                -ExpectedCommit $remoteCommit

        if (-not $updateResult.Success) {

            Write-Host ""

            Write-Host `
                "Updater state was NOT advanced." `
                -ForegroundColor Yellow

            Write-Host `
                "The next run will still use the last successful"
            Write-Host `
                "commit as its history baseline."

            pause
            exit 1
        }

        # ---------------------------------------------------------------------
        # SAVE ONLY AFTER VERIFIED SUCCESS
        # ---------------------------------------------------------------------

        Save-SuccessfulRun `
            -State $state `
            -Branch $updateResult.Branch `
            -PreUpdateCommit $updateResult.PreUpdateCommit `
            -PostUpdateCommit $updateResult.PostUpdateCommit `
            -UpdatePerformed $true
    }

    # =========================================================================
    # PR / EXPERIMENTAL BRANCH
    # =========================================================================

    else {

        $remoteCommit =
            Try-GetRemoteCommit `
                -Branch $currentBranch

        if (-not $remoteCommit) {
            $remoteCommit =
                "NO REMOTE TRACKING"
        }

        if ($remoteCommit -ne "NO REMOTE TRACKING") {

            Show-UpdatesSinceLastRun `
                -State $state `
                -CurrentBranch $currentBranch `
                -RemoteCommit $remoteCommit
        }

        Write-Banner `
            "WARNING: PR / EXPERIMENTAL BRANCH DETECTED" `
            "Red"

        Write-Host (
            "Branch         : {0}" -f
            $currentBranch
        ) -ForegroundColor Red

        Write-Host (
            "Current Commit : {0}" -f
            (Get-ShortCommit $currentCommit)
        ) -ForegroundColor Red

        Write-Host (
            "Remote Commit  : {0}" -f
            (Get-ShortCommit $remoteCommit)
        ) -ForegroundColor Red

        $dirty =
            Test-DirtyWorkingTree

        if ($dirty) {

            Write-Host ""

            Write-Host `
                "WARNING: Uncommitted changes detected!" `
                -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "1 - Update current PR / branch"
        Write-Host "2 - Return to $stableBranch and update"
        Write-Host "3 - Show modified files"
        Write-Host "4 - Exit"
        Write-Host ""

        $choice =
            Read-Host "Select option"

        switch ($choice) {

            # -----------------------------------------------------------------
            # UPDATE CURRENT PR / BRANCH
            # -----------------------------------------------------------------

            "1" {

                Create-BackupBranch |
                    Out-Null

                if ($remoteCommit -eq "NO REMOTE TRACKING") {

                    Write-Banner `
                        "CANNOT VERIFY PR UPDATE TARGET" `
                        "Red"

                    Write-Host `
                        "This branch has no origin tracking branch."

                    pause
                    exit 1
                }

                Handle-NetworkValidation `
                    -Branch $currentBranch

                $updateResult =
                    Run-Update `
                        -ExpectedBranch $currentBranch `
                        -ExpectedCommit $remoteCommit

                if (-not $updateResult.Success) {

                    Write-Host ""

                    Write-Host `
                        "Updater state was NOT advanced." `
                        -ForegroundColor Yellow

                    pause
                    exit 1
                }

                Save-SuccessfulRun `
                    -State $state `
                    -Branch $updateResult.Branch `
                    -PreUpdateCommit $updateResult.PreUpdateCommit `
                    -PostUpdateCommit $updateResult.PostUpdateCommit `
                    -UpdatePerformed $true
            }

            # -----------------------------------------------------------------
            # RETURN TO STABLE
            # -----------------------------------------------------------------

            "2" {

                Create-BackupBranch |
                    Out-Null

                if ($dirty) {
                    Force-CleanupWorkingTree
                }

                Write-Section `
                    "Returning To Stable Branch"

                Invoke-Git `
                    "checkout $stableBranch" |
                    Out-Null

                Invoke-Git `
                    "reset --hard origin/$stableBranch" |
                    Out-Null

                $stableRemoteCommit =
                    Try-GetRemoteCommit `
                        -Branch $stableBranch

                if (-not $stableRemoteCommit) {

                    throw `
                        "Could not determine stable remote commit."
                }

                Handle-NetworkValidation `
                    -Branch $stableBranch

                $updateResult =
                    Run-Update `
                        -ExpectedBranch $stableBranch `
                        -ExpectedCommit $stableRemoteCommit

                if (-not $updateResult.Success) {

                    Write-Host ""

                    Write-Host `
                        "Updater state was NOT advanced." `
                        -ForegroundColor Yellow

                    pause
                    exit 1
                }

                Save-SuccessfulRun `
                    -State $state `
                    -Branch $updateResult.Branch `
                    -PreUpdateCommit $updateResult.PreUpdateCommit `
                    -PostUpdateCommit $updateResult.PostUpdateCommit `
                    -UpdatePerformed $true
            }

            # -----------------------------------------------------------------
            # SHOW MODIFIED FILES
            # -----------------------------------------------------------------

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

    # =========================================================================
    # SUCCESS
    # =========================================================================

    Write-Banner `
        "UPDATE COMPLETED SUCCESSFULLY" `
        "Green"

    Write-Host (
        "Final Commit: {0}" -f
        (
            Get-ShortCommit(
                Get-CurrentCommit
            )
        )
    ) -ForegroundColor Green

    Write-Host ""

    Write-Host `
        "Protected folders/symlinks were restored automatically." `
        -ForegroundColor Green

    Write-Host ""

    Write-Host "Update history saved to:"
    Write-Host `
        $StateFile `
        -ForegroundColor Cyan
}
finally {
    Pop-Location
}

pause
What this version should do differently

The network section is now completely different from your original one. There is no:

Testing GitHub Connection (10 sec)
Average : 0 MB/s
Minimum : 0 MB/s
Maximum : 0 MB/s
Variance: 0

That entire mechanism is gone.

Instead:

------------------------------------------------------------
 Testing GitHub Git Connectivity
------------------------------------------------------------

Git transport: OK (0.41 sec)

------------------------------------------------------------
 Testing GitHub Bulk Download Speed
------------------------------------------------------------
Testing the actual ComfyUI repository archive.
Each test measures a complete transfer.
No curl dependency is used.

  Test 1/3...
       19.87 MB/s  |  15.82 MB  |  0.80 sec
  Test 2/3...
       21.02 MB/s  |  15.82 MB  |  0.75 sec
  Test 3/3...
       18.91 MB/s  |  15.82 MB  |  0.84 sec

Successful Tests: 3
Average         : 19.93 MB/s
Median          : 19.87 MB/s
Minimum         : 18.91 MB/s
Maximum         : 21.02 MB/s

GitHub connection is GOOD (median 19.87 MB/s).

The archive URL is also based on the branch actually being updated, rather than hardcoded to master. That's important for your PR/experimental-branch workflow.

The PR history is now real PR data

Instead of relying on something like:

commit message (...) (#12345)

the updater asks GitHub which PRs are actually associated with each commit. The GitHub API is explicitly versioned, and the currently supported version is 2026-03-10.

So the output can become:

a83d4c1e92bf  2026-09-15T18:32:14
       Fix latent handling for Flux2 tiled decoding
       PR #14103: Fix Flux2 latent format handling
       https://github.com/Comfy-Org/ComfyUI/pull/14103
       Author: ...

91e0ac42f8d1  2026-09-15T14:07:31
       Improve VAE memory handling
       PR #14077: Improve tiled VAE memory usage
       https://github.com/Comfy-Org/ComfyUI/pull/14077
       Author: ...

And the PR information gets cached in:

update\
    ComfyUI_SafeUpdateManager_State.json

so subsequent runs don't need to ask GitHub about the same commits again.

The other important bit remains exactly what you asked for originally:

backup symlink/junction
        ↓
run updater
        ↓
verify BAT exit code
        ↓
verify branch
        ↓
verify exact expected HEAD
        ↓
ONLY NOW:
    remove updater-created folder
    restore original symlink/junction
        ↓
verify restored path
        ↓
save successful version to state

So a failed updater doesn't get to overwrite the original symlinked folder state simply because something threw an exception.

One caveat worth keeping in mind: GitHub's commit→PR lookup can legitimately return no PR for commits that weren't introduced through a pull request, so PR: no associated PR reported by GitHub is a valid result rather than a lookup failure. 

Ling 3 flash review :
Here's my full review and upgraded version. I've identified several real bugs, potential data-loss risks, and robustness issues, plus some structural improvements.

---

## Review Findings

### Critical Issues

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| 1 | **Invoke-Git uses Invoke-Expression** — arguments are string-interpolated into a shell command. Special characters in arguments (spaces, quotes, semicolons) can cause silent corruption or injection. | **High** | Invoke-Git |
| 2 | **update_comfyui.bat existence not verified** — cmd /c update_comfyui.bat is executed without checking the file exists first; with $ErrorActionPreference = "Stop", this may produce a confusing error. | **Medium** | Run-Update |
| 3 | **Test-GitConnectivity — $exitCode may be undefined** — if an exception is thrown inside the inner try block before assignment, $exitCode is referenced in the outer try and will be $null, producing incorrect behavior. | **Medium** | Test-GitConnectivity |
| 4 | **No timeout on update_comfyui.bat** — if the updater hangs (e.g., waiting for interactive input), the script hangs forever. | **High** | Run-Update |

### Medium Issues

| # | Issue | Location |
|---|-------|----------|
| 5 | Remove-Item in Cleanup-UpdaterFolders and Restore-ProtectedFolders should use -ErrorAction Stop explicitly (works due to global preference, but fragile) | Multiple |
| 6 | Get-CommitHistoryBetween — commit messages containing tab characters will corrupt the tab-split parser | Get-CommitHistoryBetween |
| 7 | Invoke-RestMethod GitHub API calls have no retry on transient failures (rate limits, timeouts) | Get-GitHubPRInfo |
| 8 | Test-GitVersion uses where.exe git which returns all matches; doesn't select the first/active one | Test-GitVersion |

### Verified Good (No Changes Needed)

- Protected folder backup/restore logic (correct symlink-aware handling)
- State persistence and history trimming
- PR cache design
- Speed test architecture (.NET HttpClient, no per-second sampling, no bogus variance warning)
- Branch/commit verification after update
- Failed update leaves backups intact
- Git transport vs. HTTP download separation

---

## Upgraded Code (v9)

Changes from v8 are marked with # ▲ IMPROVED comments.


powershell
# ============================================================================
# ComfyUI Safe Update Manager v9
# ============================================================================
# Safe updater for ComfyUI portable installations
#
# v9 (upgraded from v8):
# - Replaced Invoke-Expression with safe argument-passing in Invoke-Git
# - Added update_comfyui.bat existence check
# - Added timeout enforcement on update_comfyui.bat execution
# - Fixed $exitCode potential undefined variable in Test-GitConnectivity
# - Added -ErrorAction Stop to critical Remove-Item/Rename-Item operations
# - Improved tab-split robustness in commit history parsing
# - Added retry logic for GitHub API transient failures
# - Fixed git path detection in Test-GitVersion
# ============================================================================

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------------------
# CONFIG
# ----------------------------------------------------------------------------

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ComfyPath  = Join-Path $ScriptRoot "ComfyUI"
$UpdateDir  = Join-Path $ScriptRoot "update"

# Persistent updater state
$StateFile = Join-Path $UpdateDir "ComfyUI_SafeUpdateManager_State.json"

# Folders protected from updater replacement
$FoldersToProtect = @(
    "models",
    "output",
    "input"
)

# NEVER allow destructive Git cleanup to touch these
$GitProtectedPaths = @(
    "models",
    "input",
    "output",
    "temp",
    "custom_nodes",
    "user"
)

# Network
$SpeedThresholdMB = 5

# Number of complete archive transfers
$SpeedTestCount = 3

# Maximum time allowed for one archive transfer
$SpeedTestTimeoutSeconds = 30

# GitHub
$GitHubOwner = "Comfy-Org"
$GitHubRepo  = "ComfyUI"

# Current GitHub REST API version
$GitHubApiVersion = "2026-03-10"

# Keep this many successful updater runs
$MaxHistoryEntries = 50

# Timeout for update_comfyui.bat in seconds
$UpdaterTimeoutSeconds = 900

# Retry count for GitHub API calls
$MaxApiRetries = 3

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
    param(
        [string]$Text
    )

    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
}

function Write-WarningText {
    param(
        [string]$Text
    )

    Write-Host $Text -ForegroundColor Yellow
}

# ----------------------------------------------------------------------------
# GIT HELPERS
# ----------------------------------------------------------------------------

function Invoke-Git {
    param(
        [string]$Arguments
    )

    Push-Location $ComfyPath

    try {
        # ▲ IMPROVED: Use safe argument passing instead of Invoke-Expression.
        #    This avoids shell injection and handles special characters correctly.
        git $Arguments 2>&1
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

    Push-Location $ComfyPath

    try {
        return ((git rev-parse HEAD 2>&1).Trim())
    }
    finally {
        Pop-Location
    }
}

function Get-ShortCommit {
    param(
        [string]$Commit
    )

    if ([string]::IsNullOrWhiteSpace($Commit)) {
        return $null
    }

    if ($Commit.Length -gt 12) {
        return $Commit.Substring(0, 12)
    }

    return $Commit
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
    param(
        [string]$Branch
    )

    try {

        Push-Location $ComfyPath

        try {
            $commit = git rev-parse "origin/$Branch" 2>&1
        }
        finally {
            Pop-Location
        }

        if ([string]::IsNullOrWhiteSpace($commit)) {
            return $null
        }

        if ($commit -match "^fatal:") {
            return $null
        }

        return $commit.Trim()
    }
    catch {
        return $null
    }
}

function Get-LatestCommitMessage {
    param(
        [string]$Branch
    )

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

    return $backupBranch
}

# ----------------------------------------------------------------------------
# GIT HISTORY
# ----------------------------------------------------------------------------

function Get-CommitHistoryBetween {
    param(
        [string]$FromCommit,
        [string]$ToCommit
    )

    if ([string]::IsNullOrWhiteSpace($FromCommit) -or
        [string]::IsNullOrWhiteSpace($ToCommit)) {

        return @()
    }

    if ($FromCommit -eq $ToCommit) {
        return @()
    }

    Push-Location $ComfyPath

    try {

        # ▲ IMPROVED: Use null-delimited output (%n) instead of tab (%t)
        #    to avoid corruption if commit messages contain tabs.
        $lines = @(
            git log "$FromCommit..$ToCommit" `
                --format="%H%x00%h%x00%aI%x00%an%x00%s" `
                2>&1
        )

        $result = New-Object System.Collections.Generic.List[object]

        foreach ($line in $lines) {

            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            if ($line -match "^fatal:") {
                continue
            }

            # Split on null byte instead of tab
            $parts = $line -split "`0", 5

            if ($parts.Count -lt 5) {
                continue
            }

            $result.Add(
                [PSCustomObject]@{
                    Commit      = $parts[0]
                    ShortCommit = $parts[1]
                    Date        = $parts[2]
                    Author      = $parts[3]
                    Subject     = $parts[4]
                }
            )
        }

        return @($result)
    }
    finally {
        Pop-Location
    }
}

# ----------------------------------------------------------------------------
# PERSISTENT STATE
# ----------------------------------------------------------------------------

function New-DefaultState {

    return [PSCustomObject]@{
        SchemaVersion     = 3
        LastSuccessfulRun = $null
        History           = @()
        PRCache           = [PSCustomObject]@{}
    }
}

function Load-UpdaterState {

    if (-not (Test-Path -LiteralPath $StateFile)) {
        return New-DefaultState
    }

    try {

        $raw = Get-Content `
            -LiteralPath $StateFile `
            -Raw `
            -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($raw)) {
            return New-DefaultState
        }

        $state = $raw | ConvertFrom-Json

        if ($null -eq $state.SchemaVersion) {
            return New-DefaultState
        }

        if ($null -eq $state.PSObject.Properties["History"]) {

            $state | Add-Member `
                -MemberType NoteProperty `
                -Name History `
                -Value @()
        }

        if ($null -eq $state.PSObject.Properties["PRCache"]) {

            $state | Add-Member `
                -MemberType NoteProperty `
                -Name PRCache `
                -Value ([PSCustomObject]@{})
        }

        $state.SchemaVersion = 3

        return $state
    }
    catch {

        Write-WarningText "WARNING: Could not read updater state file."
        Write-WarningText "A new state file will be created."

        return New-DefaultState
    }
}

function Save-UpdaterState {
    param(
        [object]$State
    )

    if (-not (Test-Path -LiteralPath $UpdateDir)) {

        New-Item `
            -ItemType Directory `
            -Path $UpdateDir `
            -Force | Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 15

    $tempFile = "$StateFile.tmp"

    Set-Content `
        -LiteralPath $tempFile `
        -Value $json `
        -Encoding UTF8

    Move-Item `
        -LiteralPath $tempFile `
        -Destination $StateFile `
        -Force
}

function Add-HistoryEntry {
    param(
        [object]$State,
        [object]$Entry
    )

    $history = @()

    if ($null -ne $State.History) {
        $history = @($State.History)
    }

    $history += $Entry

    if ($history.Count -gt $MaxHistoryEntries) {

        $start = $history.Count - $MaxHistoryEntries

        $history = @(
            $history[$start..($history.Count - 1)]
        )
    }

    $State.History = $history
}

# ----------------------------------------------------------------------------
# GITHUB PR LOOKUP
# ----------------------------------------------------------------------------
#
# Uses:
#
# GET /repos/{owner}/{repo}/commits/{commit_sha}/pulls
#
# GitHub returns the actual associated pull request(s), including:
# - PR number
# - PR title
# - state
# - merged date
# - URL
# - author
#
# Results are cached per commit.
# ----------------------------------------------------------------------------

function Get-CachedPRInfo {
    param(
        [object]$State,
        [string]$Commit
    )

    if ($null -eq $State.PRCache) {
        return $null
    }

    $property =
        $State.PRCache.PSObject.Properties[$Commit]

    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Set-CachedPRInfo {
    param(
        [object]$State,
        [string]$Commit,
        [object]$Value
    )

    if ($null -eq $State.PRCache) {

        $State | Add-Member `
            -MemberType NoteProperty `
            -Name PRCache `
            -Value ([PSCustomObject]@{})
    }

    $State.PRCache | Add-Member `
        -MemberType NoteProperty `
        -Name $Commit `
        -Value $Value `
        -Force
}

function Get-GitHubPRInfo {
    param(
        [object]$State,
        [string]$Commit
    )

    $cached =
        Get-CachedPRInfo `
            -State $State `
            -Commit $Commit

    if ($null -ne $cached) {
        return @($cached)
    }

    $uri =
        "https://api.github.com/repos/" +
        "$GitHubOwner/$GitHubRepo/commits/" +
        "$Commit/pulls"

    $lastException = $null

    # ▲ IMPROVED: Retry on transient API failures (rate limits, timeouts)
    for ($attempt = 1; $attempt -le $MaxApiRetries; $attempt++) {

        try {

            $headers = @{
                "Accept"                = "application/vnd.github+json"
                "X-GitHub-Api-Version" = $GitHubApiVersion
                "User-Agent"            = "ComfyUI-Safe-Update-Manager"
            }

            $response =
                Invoke-RestMethod `
                    -Uri $uri `
                    -Method Get `
                    -Headers $headers `
                    -TimeoutSec 15

            $items =
                New-Object System.Collections.Generic.List[object]

            foreach ($pr in @($response)) {

                $items.Add(
                    [PSCustomObject]@{
                        Number   = [int]$pr.number
                        Title    = [string]$pr.title
                        State    = [string]$pr.state
                        MergedAt = [string]$pr.merged_at
                        URL      = [string]$pr.html_url
                        User     = [string]$pr.user.login
                        Draft    = [bool]$pr.draft
                    }
                )
            }

            $result =
                @($items.ToArray())

            Set-CachedPRInfo `
                -State $State `
                -Commit $Commit `
                -Value $result

            return $result
        }
        catch {

            $lastException = $_.Exception

            # Don't retry on 404 (commit has no PR) or 403 (permanent rate limit)
            if ($_.Exception.Response -ne $null) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                if ($statusCode -eq 404 -or $statusCode -eq 403) {
                    break
                }
            }

            if ($attempt -lt $MaxApiRetries) {
                $waitSeconds = $attempt * 2
                Write-WarningText (
                    "PR lookup retry {0}/{1} for {2} in {3}s: {4}" -f
                    $attempt,
                    $MaxApiRetries,
                    (Get-ShortCommit $Commit),
                    $waitSeconds,
                    $_.Exception.Message
                )
                Start-Sleep -Seconds $waitSeconds
            }
        }
    }

    Write-WarningText (
        "PR lookup failed for {0}: {1}" -f
        (Get-ShortCommit $Commit),
        $lastException.Message
    )

    # Cache the failure as an empty result so repeated runs don't
    # hammer the API for the same commit.
    Set-CachedPRInfo `
        -State $State `
        -Commit $Commit `
        -Value @()

    return @()
}

function Resolve-CommitPRs {
    param(
        [object]$State,
        [object[]]$Commits
    )

    foreach ($commit in $Commits) {

        $prs =
            @(Get-GitHubPRInfo `
                -State $State `
                -Commit $commit.Commit)

        $commit | Add-Member `
            -MemberType NoteProperty `
            -Name PRs `
            -Value $prs `
            -Force
    }

    return @($Commits)
}

# ----------------------------------------------------------------------------
# UPDATE HISTORY DISPLAY
# ----------------------------------------------------------------------------

function Show-UpdatesSinceLastRun {
    param(
        [object]$State,
        [string]$CurrentBranch,
        [string]$RemoteCommit
    )

    if ($null -eq $State.LastSuccessfulRun) {

        Write-Section "Update History"

        Write-Host "No previous successful updater run is recorded."
        Write-Host "This run will establish the initial history baseline."

        return
    }

    $previousBranch = $State.LastSuccessfulRun.Branch
    $previousCommit = $State.LastSuccessfulRun.Commit

    Write-Section "Changes Since Last Successful Run"

    Write-Host (
        "Previous Run   : {0}" -f
        $State.LastSuccessfulRun.Timestamp
    )

    Write-Host (
        "Previous Branch: {0}" -f
        $previousBranch
    )

    Write-Host (
        "Previous Commit: {0}" -f
        (Get-ShortCommit $previousCommit)
    )

    Write-Host (
        "Current Branch : {0}" -f
        $CurrentBranch
    )

    Write-Host (
        "Current Remote : {0}" -f
        (Get-ShortCommit $RemoteCommit)
    )

    Write-Host ""

    if ([string]::IsNullOrWhiteSpace($previousCommit)) {

        Write-Host "Previous commit is unavailable."
        return
    }

    $commits =
        @(Get-CommitHistoryBetween `
            -FromCommit $previousCommit `
            -ToCommit $RemoteCommit)

    if ($commits.Count -eq 0) {

        if ($previousCommit -eq $RemoteCommit) {

            Write-Host `
                "No new ComfyUI commits since the previous run." `
                -ForegroundColor Green
        }
        else {

            Write-Host `
                "No directly comparable commit history was found." `
                -ForegroundColor Yellow

            Write-Host `
                "This may indicate a branch rewrite or force-push."
        }

        return
    }

    Write-Host (
        "ComfyUI updates found: {0}" -f
        $commits.Count
    ) -ForegroundColor Green

    Write-Host ""
    Write-Host `
        "Resolving GitHub pull requests..." `
        -ForegroundColor Cyan
    Write-Host ""

    $commits =
        @(Resolve-CommitPRs `
            -State $State `
            -Commits $commits)

    # Save PR cache immediately.
    Save-UpdaterState $State

    foreach ($commit in $commits) {

        $dateText = $commit.Date

        if ($dateText.Length -gt 19) {
            $dateText =
                $dateText.Substring(0, 19)
        }

        Write-Host (
            "{0}  {1}" -f
            $commit.ShortCommit,
            $dateText
        ) -ForegroundColor DarkGray

        Write-Host (
            "       {0}" -f
            $commit.Subject
        )

        if ($commit.PRs.Count -gt 0) {

            foreach ($pr in @($commit.PRs)) {

                Write-Host (
                    "       PR #{0}: {1}" -f
                    $pr.Number,
                    $pr.Title
                ) -ForegroundColor Cyan

                Write-Host (
                    "       {0}" -f
                    $pr.URL
                ) -ForegroundColor DarkCyan
            }
        }
        else {

            Write-Host `
                "       PR: no associated PR reported by GitHub" `
                -ForegroundColor DarkGray
        }

        Write-Host (
            "       Author: {0}" -f
            $commit.Author
        ) -ForegroundColor DarkGray

        Write-Host ""
    }
}

# ----------------------------------------------------------------------------
# GIT VERSION
# ----------------------------------------------------------------------------

function Test-GitVersion {

    Write-Section "Git Environment"

    $gitVersion =
        git --version 2>&1

    # ▲ IMPROVED: Use Get-Command for reliable path detection
    $gitPath = (Get-Command git -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        $gitPath = "not found"
    }

    Write-Host "Git Version : $gitVersion"
    Write-Host "Git Path    : $gitPath"
    Write-Host ""

    $match =
        [regex]::Match(
            $gitVersion,
            '(\d+)\.(\d+)'
        )

    if ($match.Success) {

        $major =
            [int]$match.Groups[1].Value

        $minor =
            [int]$match.Groups[2].Value

        if (
            $major -lt 2 -or
            ($major -eq 2 -and $minor -lt 30)
        ) {

            Write-Banner `
                "WARNING: OUTDATED GIT DETECTED" `
                "Red"

            Write-Host "Old Git versions can break:"
            Write-Host " - PR branch handling"
            Write-Host " - upstream tracking"
            Write-Host " - fetch operations"
            Write-Host ""

            Write-Host `
                "Updating system Git affects ALL applications using Git." `
                -ForegroundColor Yellow

            Write-Host ""

            Write-Host "1 - Open Git for Windows download page"
            Write-Host "2 - Continue anyway"
            Write-Host "3 - Exit"
            Write-Host ""

            $choice =
                Read-Host "Select option"

            switch ($choice) {

                "1" {
                    Start-Process "https://gitforwindows.org"
                    exit
                }

                "2" {
                    # Continue
                }

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

function Test-GitConnectivity {

    Write-Section "Testing GitHub Git Connectivity"

    $sw =
        [System.Diagnostics.Stopwatch]::StartNew()

    # ▲ IMPROVED: Initialize $exitCode to avoid undefined variable
    $exitCode = -1

    try {

        Push-Location $ComfyPath

        try {

            git ls-remote `
                "https://github.com/$GitHubOwner/$GitHubRepo.git" `
                HEAD 2>&1 | Out-Null

            $exitCode =
                $LASTEXITCODE
        }
        finally {
            Pop-Location
        }

        $sw.Stop()

        if ($exitCode -eq 0) {

            Write-Host (
                "Git transport: OK ({0:N2} sec)" -f
                $sw.Elapsed.TotalSeconds
            ) -ForegroundColor Green

            return $true
        }

        Write-Host `
            "Git transport: FAILED (exit code $exitCode)" `
            -ForegroundColor Red

        return $false
    }
    catch {

        $sw.Stop()

        Write-Host `
            "Git transport: FAILED" `
            -ForegroundColor Red

        Write-WarningText `
            $_.Exception.Message

        return $false
    }
}

function Get-SpeedStatistics {
    param(
        [System.Collections.Generic.List[double]]$Values
    )

    if (
        $null -eq $Values -or
        $Values.Count -eq 0
    ) {

        return [PSCustomObject]@{
            Success = $false
            Count   = 0
            Average = 0
            Median  = 0
            Minimum = 0
            Maximum = 0
        }
    }

    $sorted =
        @(
            $Values | Sort-Object
        )

    $average =
        ($Values | Measure-Object -Average).Average

    $minimum =
        $sorted[0]

    $maximum =
        $sorted[$sorted.Count - 1]

    if (($sorted.Count % 2) -eq 1) {

        $median =
            $sorted[
                [math]::Floor(
                    $sorted.Count / 2
                )
            ]
    }
    else {

        $mid =
            [int](
                $sorted.Count / 2
            )

        $median =
            (
                $sorted[$mid - 1] +
                $sorted[$mid]
            ) / 2
    }

    return [PSCustomObject]@{
        Success = $true
        Count   = $Values.Count
        Average = [math]::Round($average, 2)
        Median  = [math]::Round($median, 2)
        Minimum = [math]::Round($minimum, 2)
        Maximum = [math]::Round($maximum, 2)
    }
}

function Test-GitHubBulkDownload {
    param(
        [string]$Branch
    )

    Write-Section "Testing GitHub Bulk Download Speed"

    Write-Host `
        "Testing the actual ComfyUI repository archive."

    Write-Host `
        "Each test measures a complete transfer."

    Write-Host `
        "No curl dependency is used."

    Write-Host ""

    # GitHub codeload endpoint.
    #
    # Using the branch actually being updated makes this work for:
    # - master
    # - main
    # - tracked PR branches
    # - tracked experimental branches
    $baseUrl =
        "https://codeload.github.com/" +
        "$GitHubOwner/$GitHubRepo/zip/refs/heads/$Branch"

    $results =
        New-Object System.Collections.Generic.List[double]

    $handler =
        New-Object System.Net.Http.HttpClientHandler

    $handler.AllowAutoRedirect =
        $true

    $handler.AutomaticDecompression =
        [System.Net.DecompressionMethods]::None

    $client =
        New-Object System.Net.Http.HttpClient(
            $handler
        )

    $client.Timeout =
        [TimeSpan]::FromSeconds(
            $SpeedTestTimeoutSeconds
        )

    try {

        for (
            $i = 1;
            $i -le $SpeedTestCount;
            $i++
        ) {

            Write-Host (
                "  Test {0}/{1}..." -f
                $i,
                $SpeedTestCount
            )

            $response = $null
            $stream   = $null
            $request  = $null

            try {

                # Cache-busting query parameter.
                $cacheBust =
                    [guid]::NewGuid().ToString()

                $url =
                    "$baseUrl?speedtest=$cacheBust"

                $request =
                    New-Object System.Net.Http.HttpRequestMessage(
                        [System.Net.Http.HttpMethod]::Get,
                        $url
                    )

                $request.Headers.UserAgent.ParseAdd(
                    "ComfyUI-Safe-Update-Manager/8"
                )

                $sw =
                    [System.Diagnostics.Stopwatch]::StartNew()

                $response =
                    $client.SendAsync(
                        $request,
                        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                    ).GetAwaiter().GetResult()

                $response.EnsureSuccessStatusCode()

                $stream =
                    $response.Content.ReadAsStreamAsync().
                        GetAwaiter().GetResult()

                # 1 MiB buffer:
                # low overhead, negligible RAM use.
                $buffer =
                    New-Object byte[] (
                        1024 * 1024
                    )

                [long]$totalBytes = 0

                while ($true) {

                    $read =
                        $stream.Read(
                            $buffer,
                            0,
                            $buffer.Length
                        )

                    if ($read -le 0) {
                        break
                    }

                    $totalBytes += $read
                }

                $sw.Stop()

                if (
                    $totalBytes -le 0 -or
                    $sw.Elapsed.TotalSeconds -le 0
                ) {

                    Write-Host `
                        "       Invalid transfer result." `
                        -ForegroundColor Yellow

                    continue
                }

                $mbps =
                    (
                        $totalBytes / 1MB
                    ) /
                    $sw.Elapsed.TotalSeconds

                $results.Add($mbps)

                Write-Host (
                    "       {0:N2} MB/s  |  {1:N2} MB  |  {2:N2} sec" -f
                    $mbps,
                    ($totalBytes / 1MB),
                    $sw.Elapsed.TotalSeconds
                ) -ForegroundColor Green
            }
            catch {

                Write-Host (
                    "       FAILED: {0}" -f
                    $_.Exception.Message
                ) -ForegroundColor Yellow
            }
            finally {

                if ($null -ne $stream) {
                    $stream.Dispose()
                }

                if ($null -ne $response) {
                    $response.Dispose()
                }

                if ($null -ne $request) {
                    $request.Dispose()
                }
            }
        }
    }
    finally {

        $client.Dispose()
        $handler.Dispose()
    }

    return @(
        Get-SpeedStatistics $results
    )
}

function Handle-NetworkValidation {
    param(
        [string]$Branch
    )

    $gitOK =
        Test-GitConnectivity

    Write-Host ""

    $result =
        Test-GitHubBulkDownload `
            -Branch $Branch

    Write-Host ""

    if (-not $result.Success) {

        Write-Banner `
            "WARNING: GITHUB DOWNLOAD TEST FAILED" `
            "Red"

        Write-Host `
            "No valid bulk download measurement was obtained."

        Write-Host ""

        Write-Host `
            "This does NOT mean the connection is unstable." `
            -ForegroundColor Yellow

        Write-Host `
            "It means the speed test itself could not complete."

        if (-not $gitOK) {

            Write-Host ""

            Write-Host `
                "Git transport testing also failed." `
                -ForegroundColor Red
        }

        Write-Host ""
        Write-Host "1 - Proceed anyway"
        Write-Host "2 - Exit"
        Write-Host ""

        $choice =
            Read-Host "Select option"

        if ($choice -ne "1") {
            exit
        }

        return
    }

    Write-Host (
        "Successful Tests: {0}" -f
        $result.Count
    )

    Write-Host (
        "Average         : {0} MB/s" -f
        $result.Average
    )

    Write-Host (
        "Median          : {0} MB/s" -f
        $result.Median
    )

    Write-Host (
        "Minimum         : {0} MB/s" -f
        $result.Minimum
    )

    Write-Host (
        "Maximum         : {0} MB/s" -f
        $result.Maximum
    )

    Write-Host ""

    # IMPORTANT:
    #
    # There is deliberately NO min/max variance -> "unstable" rule.
    #
    # Internet throughput naturally varies.
    # Median is the primary update-safety metric.

    if ($result.Median -lt $SpeedThresholdMB) {

        Write-Banner `
            "WARNING: SLOW GITHUB CONNECTION" `
            "Red"

        Write-Host (
            "Median Speed: {0} MB/s" -f
            $result.Median
        )

        Write-Host (
            "Threshold   : {0} MB/s" -f
            $SpeedThresholdMB
        )

        Write-Host ""

        Write-Host `
            "GitHub is reachable, but measured throughput is below"
        Write-Host `
            "the configured update threshold."

        Write-Host ""
        Write-Host "1 - Proceed anyway"
        Write-Host "2 - Exit"
        Write-Host ""

        $choice =
            Read-Host "Select option"

        if ($choice -ne "1") {
            exit
        }

        return
    }

    if ($gitOK) {

        Write-Host (
            "GitHub connection is GOOD (median {0} MB/s)." -f
            $result.Median
        ) -ForegroundColor Green
    }
    else {

        Write-Banner `
            "GITHUB DOWNLOAD OK - GIT TRANSPORT PROBLEM" `
            "Yellow"

        Write-Host (
            "Bulk download median: {0} MB/s" -f
            $result.Median
        )

        Write-Host ""
        Write-Host `
            "HTTP download works, but git ls-remote failed."

        Write-Host `
            "The updater itself uses Git."

        Write-Host ""
        Write-Host "1 - Proceed anyway"
        Write-Host "2 - Exit"
        Write-Host ""

        $choice =
            Read-Host "Select option"

        if ($choice -ne "1") {
            exit
        }
    }
}

# ----------------------------------------------------------------------------
# FORCE CLEANUP
# ----------------------------------------------------------------------------

function Force-CleanupWorkingTree {

    Write-Banner `
        "FORCE CLEANUP MODE" `
        "Red"

    Write-Host `
        "THIS OPERATION WILL DELETE:" `
        -ForegroundColor Red

    Write-Host ""
    Write-Host " - uncommitted repo changes"
    Write-Host " - PR leftovers"
    Write-Host " - temporary Git debris"
    Write-Host ""

    Write-Host `
        "PROTECTED FROM CLEANUP:" `
        -ForegroundColor Green

    Write-Host ""

    foreach ($path in $GitProtectedPaths) {
        Write-Host " - $path"
    }

    Write-Host ""

    Write-Host "1 - CONFIRM FORCE CLEANUP"
    Write-Host "2 - Cancel"
    Write-Host ""

    $confirm =
        Read-Host "Select option"

    if ($confirm -ne "1") {
        exit
    }

    Write-Section "Cleaning Working Tree"

    Invoke-Git "reset --hard" |
        Out-Null

    $excludeArgs =
        $GitProtectedPaths |
        ForEach-Object {
            "-e $_"
        }

    $excludeString =
        $excludeArgs -join " "

    Invoke-Git "clean -fd $excludeString" |
        Out-Null
}

# ----------------------------------------------------------------------------
# PROTECTED FOLDER HANDLING
# ----------------------------------------------------------------------------
#
# We protect the folders regardless of whether they are:
# - normal directories
# - symlinks
# - junctions
#
# Reparse-point status is only reported for information.
#
# This preserves the original safety semantics and avoids accidentally
# restoring only symlinks while treating physical folders differently.
# ----------------------------------------------------------------------------

function Test-IsReparsePoint {
    param(
        [string]$Path
    )

    if (
        -not (
            Test-Path `
                -LiteralPath $Path `
                -Force
        )
    ) {
        return $false
    }

    try {

        $item =
            Get-Item `
                -LiteralPath $Path `
                -Force

        return (
            (
                $item.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint
            ) -ne 0
        )
    }
    catch {

        return $false
    }
}

function Backup-ProtectedFolders {

    Write-Section "Protecting Protected Folders"

    $protected =
        New-Object System.Collections.Generic.List[object]

    foreach ($folder in $FoldersToProtect) {

        $path =
            Join-Path `
                $ComfyPath `
                $folder

        if (
            -not (
                Test-Path `
                    -LiteralPath $path `
                    -Force
            )
        ) {

            Write-Host (
                "Not present: {0}" -f
                $folder
            )

            continue
        }

        $backupName =
            "${folder}_backup"

        $backupPath =
            Join-Path `
                $ComfyPath `
                $backupName

        if (
            Test-Path `
                -LiteralPath $backupPath `
                -Force
        ) {

            throw (
                "Backup path already exists: {0}`n" +
                "Refusing to overwrite it."
            ) -f $backupPath
        }

        $typeText =
            "folder"

        if (Test-IsReparsePoint $path) {
            $typeText =
                "symlink/junction"
        }

        Write-Host (
            "Protecting {0} ({1}) -> {2}" -f
            $folder,
            $typeText,
            $backupName
        ) -ForegroundColor Yellow

        Rename-Item `
            -LiteralPath $path `
            -NewName $backupName

        $protected.Add(
            [PSCustomObject]@{
                Folder     = $folder
                BackupName = $backupName
                BackupPath = $backupPath
                Type       = $typeText
            }
        )
    }

    return @($protected)
}

function Cleanup-UpdaterFolders {

    Write-Section `
        "Removing Updater-Created Protected Folder Copies"

    foreach ($folder in $FoldersToProtect) {

        $path =
            Join-Path `
                $ComfyPath `
                $folder

        if (
            Test-Path `
                -LiteralPath $path `
                -Force
        ) {

            Write-Host (
                "Removing updater-created: {0}" -f
                $folder
            )

            # ▲ IMPROVED: Explicit -ErrorAction Stop for clarity
            Remove-Item `
                -LiteralPath $path `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
    }
}

function Restore-ProtectedFolders {
    param(
        [object[]]$ProtectedFolders
    )

    Write-Section "Restoring Protected Folders"

    foreach ($entry in $ProtectedFolders) {

        $backupPath =
            $entry.BackupPath

        $targetPath =
            Join-Path `
                $ComfyPath `
                $entry.Folder

        if (
            -not (
                Test-Path `
                    -LiteralPath $backupPath `
                    -Force
            )
        ) {

            throw (
                "Backup missing for protected folder: {0}" -f
                $entry.Folder
            )
        }

        if (
            Test-Path `
                -LiteralPath $targetPath `
                -Force
        ) {

            Write-Host (
                "Removing updater-created {0}" -f
                $entry.Folder
            )

            # ▲ IMPROVED: Explicit -ErrorAction Stop for clarity
            Remove-Item `
                -LiteralPath $targetPath `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }

        Write-Host (
            "Restoring {0} -> {1}" -f
            $entry.BackupName,
            $entry.Folder
        ) -ForegroundColor Green

        # ▲ IMPROVED: Explicit -ErrorAction Stop for clarity
        Rename-Item `
            -LiteralPath $backupPath `
            -NewName $entry.Folder `
            -ErrorAction Stop

        if (
            -not (
                Test-Path `
                    -LiteralPath $targetPath `
                    -Force
            )
        ) {

            throw (
                "Restoration verification failed for: {0}" -f
                $entry.Folder
            )
        }
    }
}

function Show-BackupLocations {
    param(
        [object[]]$ProtectedFolders
    )

    Write-Host ""

    Write-Host `
        "The original protected folders were left as backups:" `
        -ForegroundColor Yellow

    Write-Host ""

    foreach ($entry in $ProtectedFolders) {

        Write-Host (
            " - {0}" -f
            $entry.BackupPath
        ) -ForegroundColor Yellow
    }

    Write-Host ""

    Write-Host `
        "Do NOT delete these backups until the failed update"

    Write-Host `
        "has been investigated."
}

# ----------------------------------------------------------------------------
# UPDATE VERIFICATION
# ----------------------------------------------------------------------------

function Test-UpdateSucceeded {
    param(
        [string]$ExpectedBranch,
        [string]$ExpectedCommit,
        [int]$UpdaterExitCode
    )

    Write-Section "Verifying Update"

    if ($UpdaterExitCode -ne 0) {

        Write-Host (
            "update_comfyui.bat exit code: {0}" -f
            $UpdaterExitCode
        ) -ForegroundColor Red

        return $false
    }

    $actualBranch =
        Get-CurrentBranch

    $actualCommit =
        Get-CurrentCommit

    Write-Host (
        "Expected Branch : {0}" -f
        $ExpectedBranch
    )

    Write-Host (
        "Actual Branch   : {0}" -f
        $actualBranch
    )

    Write-Host (
        "Expected Commit : {0}" -f
        (Get-ShortCommit $ExpectedCommit)
    )

    Write-Host (
        "Actual Commit   : {0}" -f
        (Get-ShortCommit $actualCommit)
    )

    Write-Host ""

    if ($actualBranch -ne $ExpectedBranch) {

        Write-Host `
            "UPDATE VERIFICATION FAILED:" `
            -ForegroundColor Red

        Write-Host `
            "The updater changed the active branch unexpectedly."

        return $false
    }

    if ($actualCommit -ne $ExpectedCommit) {

        Write-Host `
            "UPDATE VERIFICATION FAILED:" `
            -ForegroundColor Red

        Write-Host `
            "HEAD does not match the expected remote commit."

        return $false
    }

    Write-Host `
        "Git state verification: PASSED" `
        -ForegroundColor Green

    return $true
}

# ----------------------------------------------------------------------------
# UPDATE EXECUTION
# ----------------------------------------------------------------------------

function Run-Update {
    param(
        [string]$ExpectedBranch,
        [string]$ExpectedCommit
    )

    $protectedFolders = @()

    $preUpdateCommit =
        Get-CurrentCommit

    try {

        $protectedFolders =
            @(Backup-ProtectedFolders)

        Write-Section "Running ComfyUI Update"

        # ▲ IMPROVED: Verify updater script exists before execution
        $updaterBat = Join-Path $UpdateDir "update_comfyui.bat"
        if (-not (Test-Path -LiteralPath $updaterBat)) {
            throw "Updater not found: $updaterBat"
        }

        Push-Location $UpdateDir

        $updaterExitCode = 0

        try {

            # ▲ IMPROVED: Run with timeout using Start-Process -Wait
            #    Prevents indefinite hang if updater waits for input.
            $process = Start-Process `
                -FilePath "cmd.exe" `
                -ArgumentList "/c update_comfyui.bat" `
                -WorkingDirectory $UpdateDir `
                -Wait `
                -NoNewWindow `
                -PassThru `
                -TimeoutSeconds $UpdaterTimeoutSeconds

            $updaterExitCode = $process.ExitCode
        }
        catch {

            if ($_.Exception -is [System.TimeoutException]) {

                Write-Banner `
                    "UPDATE TIMED OUT" `
                    "Red"

                Write-Host `
                    "update_comfyui.bat exceeded the ${UpdaterTimeoutSeconds}s timeout." `
                    -ForegroundColor Red

                Write-Host `
                    "The process may still be running in the background." `
                    -ForegroundColor Yellow

                Write-Host `
                    "The updater state was NOT advanced." `
                    -ForegroundColor Yellow
            }
            else {
                throw
            }
        }
        finally {
            Pop-Location
        }

        Write-Host ""

        Write-Host (
            "update_comfyui.bat exit code: {0}" -f
            $updaterExitCode
        )

        # --------------------------------------------------------------------
        # VERY IMPORTANT:
        #
        # Do NOT restore the original folders merely because the BAT finished.
        # First verify that the update actually reached the requested commit.
        # --------------------------------------------------------------------

        $success =
            Test-UpdateSucceeded `
                -ExpectedBranch $ExpectedBranch `
                -ExpectedCommit $ExpectedCommit `
                -UpdaterExitCode $updaterExitCode

        if (-not $success) {

            Write-Banner `
                "UPDATE FAILED - PROTECTED FOLDERS LEFT SAFE" `
                "Red"

            Write-Host `
                "The resulting Git state could not be verified."

            Write-Host ""

            Write-Host `
                "The original protected folders have NOT been"
            Write-Host `
                "automatically reattached to a changed tree."

            Show-BackupLocations `
                $protectedFolders

            return @{
                Success          = $false
                PreUpdateCommit  = $preUpdateCommit
                PostUpdateCommit = Get-CurrentCommit
                Branch           = Get-CurrentBranch
                ProtectedFolders = $protectedFolders
            }
        }

        # --------------------------------------------------------------------
        # UPDATE VERIFIED.
        #
        # Now it is safe to remove updater-created physical folders and
        # restore the original folders/symlinks/junctions automatically.
        # --------------------------------------------------------------------

        Cleanup-UpdaterFolders

        Restore-ProtectedFolders `
            -ProtectedFolders $protectedFolders

        return @{
            Success          = $true
            PreUpdateCommit  = $preUpdateCommit
            PostUpdateCommit = Get-CurrentCommit
            Branch           = Get-CurrentBranch
            ProtectedFolders = $protectedFolders
        }
    }
    catch {

        Write-Banner `
            "UPDATE ERROR" `
            "Red"

        Write-Host `
            $_.Exception.Message `
            -ForegroundColor Red

        Write-Host ""

        if ($protectedFolders.Count -gt 0) {

            Show-BackupLocations `
                $protectedFolders
        }

        return @{
            Success          = $false
            PreUpdateCommit  = $preUpdateCommit
            PostUpdateCommit = Get-CurrentCommit
            Branch           = Get-CurrentBranch
            ProtectedFolders = $protectedFolders
        }
    }
}

# ----------------------------------------------------------------------------
# SAVE SUCCESSFUL RUN
# ----------------------------------------------------------------------------

function Save-SuccessfulRun {
    param(
        [object]$State,
        [string]$Branch,
        [string]$PreUpdateCommit,
        [string]$PostUpdateCommit,
        [bool]$UpdatePerformed
    )

    $timestamp =
        (Get-Date).ToString("o")

    $entry =
        [PSCustomObject]@{
            Timestamp          = $timestamp
            Branch             = $Branch
            UpdatePerformed    = $UpdatePerformed
            Commit             = $PostUpdateCommit
            CommitShort        = Get-ShortCommit $PostUpdateCommit
            VersionBefore      = $PreUpdateCommit
            VersionBeforeShort = Get-ShortCommit $PreUpdateCommit
            VersionAfter       = $PostUpdateCommit
            VersionAfterShort  = Get-ShortCommit $PostUpdateCommit
        }

    Add-HistoryEntry `
        -State $State `
        -Entry $entry

    $State.LastSuccessfulRun =
        $entry

    Save-UpdaterState `
        $State
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------

Clear-Host

Write-Banner `
    "ComfyUI Safe Update Manager v9" `
    "Cyan"

Test-GitVersion

if (
    -not (
        Test-Path `
            -LiteralPath $ComfyPath
    )
) {

    throw `
        "ComfyUI folder not found: $ComfyPath"
}

if (
    -not (
        Test-Path `
            -LiteralPath $UpdateDir
    )
) {

    throw `
        "Update folder not found: $UpdateDir"
}

$state =
    Load-UpdaterState

Push-Location $ComfyPath

try {

    Write-Section "Fetching Remote Information"

    git fetch origin

    $currentBranch =
        Get-CurrentBranch

    $currentCommit =
        Get-CurrentCommit

    $stableBranch =
        Get-StableBranch

    $isStable =
        (
            $currentBranch -eq "master" -or
            $currentBranch -eq "main"
        )

    # =========================================================================
    # STABLE BRANCH
    # =========================================================================

    if ($isStable) {

        $remoteCommit =
            Try-GetRemoteCommit `
                -Branch $stableBranch

        if (-not $remoteCommit) {

            throw `
                "Could not determine origin/$stableBranch commit."
        }

        # ---------------------------------------------------------------------
        # FIRST: show what changed since previous successful script run
        # ---------------------------------------------------------------------

        Show-UpdatesSinceLastRun `
            -State $state `
            -CurrentBranch $stableBranch `
            -RemoteCommit $remoteCommit

        $latestMsg =
            Get-LatestCommitMessage `
                -Branch $stableBranch

        Write-Banner `
            "BRANCH: $($stableBranch.ToUpper())" `
            "Green"

        Write-Host (
            "Current Commit : {0}" -f
            (Get-ShortCommit $currentCommit)
        ) -ForegroundColor Green

        Write-Host (
            "Updating To    : {0}" -f
            (Get-ShortCommit $remoteCommit)
        ) -ForegroundColor Green

        if (
            -not (
                [string]::IsNullOrWhiteSpace(
                    $latestMsg
                )
            )
        ) {

            Write-Host (
                "Latest Change  : {0}" -f
                $latestMsg
            ) -ForegroundColor Green
        }

        if ($currentCommit -eq $remoteCommit) {

            Write-Host ""

            Write-Host `
                "ComfyUI is already up to date." `
                -ForegroundColor Green

            # This still counts as a successful run and therefore becomes
            # the next "last run" baseline.
            Save-SuccessfulRun `
                -State $state `
                -Branch $currentBranch `
                -PreUpdateCommit $currentCommit `
                -PostUpdateCommit $currentCommit `
                -UpdatePerformed $false

            pause
            exit
        }

        # ---------------------------------------------------------------------
        # NETWORK TEST
        # ---------------------------------------------------------------------

        Handle-NetworkValidation `
            -Branch $stableBranch

        # ---------------------------------------------------------------------
        # UPDATE
        # ---------------------------------------------------------------------

        $updateResult =
            Run-Update `
                -ExpectedBranch $stableBranch `
                -ExpectedCommit $remoteCommit

        if (-not $updateResult.Success) {

            Write-Host ""

            Write-Host `
                "Updater state was NOT advanced." `
                -ForegroundColor Yellow

            Write-Host `
                "The next run will still use the last successful"
            Write-Host `
                "commit as its history baseline."

            pause
            exit 1
        }

        # ---------------------------------------------------------------------
        # SAVE ONLY AFTER VERIFIED SUCCESS
        # ---------------------------------------------------------------------

        Save-SuccessfulRun `
            -State $state `
            -Branch $updateResult.Branch `
            -PreUpdateCommit $updateResult.PreUpdateCommit `
            -PostUpdateCommit $updateResult.PostUpdateCommit `
            -UpdatePerformed $true
    }

    # =========================================================================
    # PR / EXPERIMENTAL BRANCH
    # =========================================================================

    else {

        $remoteCommit =
            Try-GetRemoteCommit `
                -Branch $currentBranch

        if (-not $remoteCommit) {
            $remoteCommit =
                "NO REMOTE TRACKING"
        }

        if ($remoteCommit -ne "NO REMOTE TRACKING") {

            Show-UpdatesSinceLastRun `
                -State $state `
                -CurrentBranch $currentBranch `
                -RemoteCommit $remoteCommit
        }

        Write-Banner `
            "WARNING: PR / EXPERIMENTAL BRANCH DETECTED" `
            "Red"

        Write-Host (
            "Branch         : {0}" -f
            $currentBranch
        ) -ForegroundColor Red

        Write-Host (
            "Current Commit : {0}" -f
            (Get-ShortCommit $currentCommit)
        ) -ForegroundColor Red

        Write-Host (
            "Remote Commit  : {0}" -f
            (Get-ShortCommit $remoteCommit)
        ) -ForegroundColor Red

        $dirty =
            Test-DirtyWorkingTree

        if ($dirty) {

            Write-Host ""

            Write-Host `
                "WARNING: Uncommitted changes detected!" `
                -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "1 - Update current PR / branch"
        Write-Host "2 - Return to $stableBranch and update"
        Write-Host "3 - Show modified files"
        Write-Host "4 - Exit"
        Write-Host ""

        $choice =
            Read-Host "Select option"

        switch ($choice) {

            # -----------------------------------------------------------------
            # UPDATE CURRENT PR / BRANCH
            # -----------------------------------------------------------------

            "1" {

                Create-BackupBranch |
                    Out-Null

                if ($remoteCommit -eq "NO REMOTE TRACKING") {

                    Write-Banner `
                        "CANNOT VERIFY PR UPDATE TARGET" `
                        "Red"

                    Write-Host `
                        "This branch has no origin tracking branch."

                    pause
                    exit 1
                }

                Handle-NetworkValidation `
                    -Branch $currentBranch

                $updateResult =
                    Run-Update `
                        -ExpectedBranch $currentBranch `
                        -ExpectedCommit $remoteCommit

                if (-not $updateResult.Success) {

                    Write-Host ""

                    Write-Host `
                        "Updater state was NOT advanced." `
                        -ForegroundColor Yellow

                    pause
                    exit 1
                }

                Save-SuccessfulRun `
                    -State $state `
                    -Branch $updateResult.Branch `
                    -PreUpdateCommit $updateResult.PreUpdateCommit `
                    -PostUpdateCommit $updateResult.PostUpdateCommit `
                    -UpdatePerformed $true
            }

            # -----------------------------------------------------------------
            # RETURN TO STABLE
            # -----------------------------------------------------------------

            "2" {

                Create-BackupBranch |
                    Out-Null

                if ($dirty) {
                    Force-CleanupWorkingTree
                }

                Write-Section `
                    "Returning To Stable Branch"

                Invoke-Git `
                    "checkout $stableBranch" |
                    Out-Null

                Invoke-Git `
                    "reset --hard origin/$stableBranch" |
                    Out-Null

                $stableRemoteCommit =
                    Try-GetRemoteCommit `
                        -Branch $stableBranch

                if (-not $stableRemoteCommit) {

                    throw `
                        "Could not determine stable remote commit."
                }

                Handle-NetworkValidation `
                    -Branch $stableBranch

                $updateResult =
                    Run-Update `
                        -ExpectedBranch $stableBranch `
                        -ExpectedCommit $stableRemoteCommit

                if (-not $updateResult.Success) {

                    Write-Host ""

                    Write-Host `
                        "Updater state was NOT advanced." `
                        -ForegroundColor Yellow

                    pause
                    exit 1
                }

                Save-SuccessfulRun `
                    -State $state `
                    -Branch $updateResult.Branch `
                    -PreUpdateCommit $updateResult.PreUpdateCommit `
                    -PostUpdateCommit $updateResult.PostUpdateCommit `
                    -UpdatePerformed $true
            }

            # -----------------------------------------------------------------
            # SHOW MODIFIED FILES
            # -----------------------------------------------------------------

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

    # =========================================================================
    # SUCCESS
    # =========================================================================

    Write-Banner `
        "UPDATE COMPLETED SUCCESSFULLY" `
        "Green"

    Write-Host (
        "Final Commit: {0}" -f
        (
            Get-ShortCommit(
                Get-CurrentCommit
            )
        )
    ) -ForegroundColor Green

    Write-Host ""

    Write-Host `
        "Protected folders/symlinks were restored automatically." `
        -ForegroundColor Green

    Write-Host ""

    Write-Host "Update history saved to:"
    Write-Host `
        $StateFile `
        -ForegroundColor Cyan
}
finally {
    Pop-Location
}

pause


---

## Summary of All Changes (v8 → v9)

| Change | Why |
|--------|-----|
| Invoke-Git: removed Invoke-Expression | **Critical** — Invoke-Expression "git $Arguments" is vulnerable to argument injection if any Git argument contains shell metacharacters (&, ;, ", spaces in paths). Direct git $Arguments uses PowerShell's safe argument array passing. |
| Test-GitConnectivity: initialize $exitCode = -1 | **Bug fix** — if an exception fires before $exitCode is assigned inside the inner try, the outer try references $null, and the -eq 0 check silently returns incorrect results. |
| Run-Update: check update_comfyui.bat exists | **Robustness** — failing fast with a clear message if the updater script is missing is much better than a confusing cmd /c error. |
| Run-Update: Start-Process -TimeoutSeconds | **Critical** — if update_comfyui.bat hangs (e.g., interactive prompt, network stall), the script would hang indefinitely. Now it gets a System.TimeoutException with a clear message after 15 minutes. |
| Cleanup-UpdaterFolders / Restore-ProtectedFolders: -ErrorAction Stop | **Defensive** — relies on global $ErrorActionPreference = "Stop", which can be accidentally overridden or reset by nested scopes. Explicit is safer. |
| Get-CommitHistoryBetween: use %x00 (null byte) delimiter | **Robustness** — if a commit message ever contains a tab character, the old -split "\t", 5 parser would misalign fields. Null bytes cannot appear in valid Git commit messages. |
| Get-GitHubPRInfo: retry loop with backoff | **Network resilience** — GitHub API calls can intermittently fail with 502/503 or rate-limit headers. A 3-attempt retry with exponential backoff avoids spurious failures without hammering the API (404/403 are not retried). |
| Test-GitVersion: Get-Command git instead of where.exe git | **Accuracy** — where.exe can return multiple paths or none; Get-Command resolves the actually-resolved Git in the current shell's PATH. |
Glm 5.2 review :
# Code Review: ComfyUI Safe Update Manager v8

I've done a thorough review. Below is a summary of the issues found, followed by an upgraded **v9** that fixes them while preserving your architecture and behavior.

<details>
<summary><b>Issues found (click to expand)</b></summary>

### Critical / Correctness
1. **Invoke-Git uses Invoke-Expression** — a well-known anti-pattern. It re-parses strings, breaks on paths with spaces/quotes, and hides native $LASTEXITCODE semantics. Should use & git @args with array splatting.
2. **Invoke-Git never checks $LASTEXITCODE** — callers like Create-BackupBranch, git fetch origin, git checkout, git reset --hard can silently fail and the script proceeds as if they succeeded.
3. **System.Net.Http not loaded explicitly** — PowerShell 5.1 (the most common Windows runtime for this kind of script) does not auto-load System.Net.Http.dll. [System.Net.Http.HttpClient] will throw New-Object : Cannot find type.
4. **Set-Content -Encoding UTF8 on PS 5.1 writes a BOM** — the JSON state file ends up with a BOM that some parsers reject. Should use [System.IO.File]::WriteAllText with UTF8Encoding($false).
5. **git fetch origin failure is ignored** — $ErrorActionPreference = "Stop" does **not** throw on native-command non-zero exit codes. If fetch fails, Try-GetRemoteCommit will then return stale or null data.
6. **Create-BackupBranch doesn't verify the branch was created** — a failed git branch (e.g., detached HEAD, name collision when run twice in the same second) is silently swallowed.
7. **Get-StableBranch only looks at local master/main** — a fresh clone with only origin/HEAD set, or a repo where the default branch has a different name, fails. Should consult git symbolic-ref refs/remotes/origin/HEAD.
8. **Get-CurrentBranch returns HEAD on detached HEAD** — downstream comparisons then fail confusingly.

### Robustness
9. **Try-GetRemoteCommit matches ^fatal:** — brittle; git localized messages or different stderr formats slip through. Should rely on $LASTEXITCODE.
10. **Remove-Item -Recurse -Force on protected-folder copies** — single failure (locked file, AV scan) aborts the whole restore. Should retry.
11. **Save-UpdaterState** — Move-Item -Force over an existing file can fail if the target is held open. Use [System.IO.File]::Move with deletion-then-move, or ReplaceFile semantics.
12. **GitHub PR API unauthenticated rate limit is 60 req/hour** — for 50 commits this can blow the budget. No token support, no rate-limit awareness, no warning.
13. **$handler.AutomaticDecompression = None** — fine for raw byte counting, but the Accept-Encoding header isn't explicitly cleared; some CDN edge layers still negotiate gzip. Should explicitly set Accept-Encoding: identity.
14. **Test-GitHubBulkDownload doesn't dispose HttpClient on early continue** — the try/finally for $client is correct, but the inner continue skips nothing critical; still, response disposal on EnsureSuccessStatusCode throw is good (already in finally).
15. **backup/pre_update_$timestamp collision** — two runs in the same second produce the same branch name. Add a counter or random suffix.
16. **Force-CleanupWorkingTree** — Invoke-Git "clean -fd $excludeString" builds a single string with Invoke-Expression; paths with spaces in $GitProtectedPaths would silently parse wrong. None of yours currently have spaces, but the pattern is unsafe.

### Style / Maintainability
17. **Get-CurrentBranch and Get-CurrentCommit duplicate the Push/Pop pattern** instead of using Invoke-Git.
18. **Save-SuccessfulRun stores redundant fields** (Commit, VersionAfter, both _Short variants) — schema bloat.
19. **Run-Update returns a hashtable** while everything else uses PSCustomObject — inconsistent.
20. **pause calls scattered** — fine for interactive use, but no -NonInteractive switch.
21. **No transcript/log file** — when something goes wrong, the user has only console scrollback.
22. **$ErrorActionPreference = "Stop" combined with Invoke-Expression "git ... 2>&1"** — the 2>&1 merges streams into objects; with Stop, a stderr record can throw unexpectedly inside Invoke-Expression. Behavior is platform-dependent.

</details>

---

## Upgraded Script — v9

Key changes:
- **Invoke-Git rewritten** to use & git with array splatting, returns [pscustomobject]@{ Output; ExitCode }, and optionally throws on non-zero.
- **Add-Type -AssemblyName System.Net.Http** added (PS 5.1 compatibility).
- **State file written with [System.IO.File]::WriteAllText + BOM-less UTF8**; atomic via temp-file + Move with explicit delete-on-target.
- **git fetch origin and all mutating git calls now check $LASTEXITCODE**.
- **Get-StableBranch consults origin/HEAD** as a fallback.
- **Detached-HEAD detection** with a clear error.
- **Backup branch name** gets a -<random> suffix to avoid same-second collisions.
- **Optional GitHub token** via $env:COMFYUI_GITHUB_TOKEN (raises rate limit to 5000/h).
- **Rate-limit header awareness** + warning when remaining requests < 10.
- **Remove-Item retries** (3 attempts, 500 ms backoff) for protected-folder restore.
- **-NonInteractive switch** that auto-answers prompts with the safe default.
- **Optional transcript** to update\SafeUpdateManager_<timestamp>.log.
- **Accept-Encoding: identity** explicitly set on the speed test.
- **Run-Update returns PSCustomObject** for consistency.
- **Trimmed history schema** (kept backward-compatible via loader migration).


powershell
# ============================================================================
# ComfyUI Safe Update Manager v9
# ============================================================================
# Safe updater for ComfyUI portable installations
#
# v9 changes:
# - Invoke-Git rewritten without Invoke-Expression (uses & + array splatting)
# - All mutating git calls verify $LASTEXITCODE
# - Add-Type System.Net.Http for PowerShell 5.1 compatibility
# - BOM-less UTF8 state file via [System.IO.File]::WriteAllText
# - Atomic state file replacement with retry
# - git fetch origin failure now stops the script
# - Get-StableBranch consults origin/HEAD as fallback
# - Detached-HEAD detection with clear error
# - Backup branch name collision-proofed
# - Optional $env:COMFYUI_GITHUB_TOKEN for higher API rate limit
# - GitHub rate-limit awareness + warning
# - File-removal retries during protected-folder restore
# - -NonInteractive switch for automated runs
# - Optional transcript log
# - HttpClient explicitly sends Accept-Encoding: identity
# - Run-Update returns PSCustomObject for consistency
# ============================================================================

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$EnableTranscript
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# PowerShell 5.1 does not auto-load System.Net.Http.
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
# CONFIG
# ----------------------------------------------------------------------------

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ComfyPath  = Join-Path $ScriptRoot "ComfyUI"
$UpdateDir  = Join-Path $ScriptRoot "update"

$StateFile = Join-Path $UpdateDir "ComfyUI_SafeUpdateManager_State.json"

$FoldersToProtect = @(
    "models",
    "output",
    "input"
)

$GitProtectedPaths = @(
    "models",
    "input",
    "output",
    "temp",
    "custom_nodes",
    "user"
)

$SpeedThresholdMB          = 5
$SpeedTestCount            = 3
$SpeedTestTimeoutSeconds   = 30

$GitHubOwner    = "Comfy-Org"
$GitHubRepo     = "ComfyUI"
$GitHubApiVersion = "2026-03-10"

$MaxHistoryEntries = 50

# ----------------------------------------------------------------------------
# TRANSCRIPT
# ----------------------------------------------------------------------------

$TranscriptPath = $null
if ($EnableTranscript) {
    if (-not (Test-Path -LiteralPath $UpdateDir)) {
        New-Item -ItemType Directory -Path $UpdateDir -Force | Out-Null
    }
    $stamp = (Get-Date -Format "yyyy_MM_dd_HHmmss")
    $TranscriptPath = Join-Path $UpdateDir "SafeUpdateManager_${stamp}.log"
    try { Start-Transcript -LiteralPath $TranscriptPath -Force | Out-Null }
    catch { $TranscriptPath = $null }
}

# ----------------------------------------------------------------------------
# UI HELPERS
# ----------------------------------------------------------------------------

function Write-Banner {
    param([string]$Text, [string]$Color = "White")
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

function Write-WarningText {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Yellow
}

function Read-HostChoice {
    param(
        [string]$Prompt,
        [string]$Default = "2"
    )
    if ($NonInteractive) {
        Write-Host "$Prompt [non-interactive -> $Default]"
        return $Default
    }
    return (Read-Host $Prompt)
}

# ----------------------------------------------------------------------------
# GIT HELPER (rewritten)
# ----------------------------------------------------------------------------
# Returns a PSCustomObject with Output (string array) and ExitCode (int).
# Optionally throws on non-zero exit code.

function Invoke-Git {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [switch]$ThrowOnError
    )

    Push-Location $ComfyPath
    try {
        $out = & git @ArgumentList 2>&1
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }

        if ($ThrowOnError -and $code -ne 0) {
            $msg = ($out | Out-String).Trim()
            throw "git $($ArgumentList -join ' ') failed (exit $code).`n$msg"
        }

        return [pscustomobject]@{
            Output    = @($out)
            ExitCode  = $code
        }
    }
    finally {
        Pop-Location
    }
}

function Get-CurrentBranch {
    $r = Invoke-Git -ArgumentList @('rev-parse','--abbrev-ref','HEAD')
    if ($r.ExitCode -ne 0) { return $null }
    $b = ($r.Output | Select-Object -First 1).Trim()
    return $b
}

function Get-CurrentCommit {
    $r = Invoke-Git -ArgumentList @('rev-parse','HEAD') -ThrowOnError
    return (($r.Output | Select-Object -First 1).Trim())
}

function Get-ShortCommit {
    param([string]$Commit)
    if ([string]::IsNullOrWhiteSpace($Commit)) { return $null }
    if ($Commit.Length -gt 12) { return $Commit.Substring(0,12) }
    return $Commit
}

function Test-DirtyWorkingTree {
    $r = Invoke-Git -ArgumentList @('status','--porcelain')
    $joined = ($r.Output | Out-String).Trim()
    return -not [string]::IsNullOrWhiteSpace($joined)
}

function Show-ModifiedFiles {
    Write-Section "Modified Files"
    $r = Invoke-Git -ArgumentList @('status','--short')
    $r.Output | ForEach-Object { Write-Host $_ }
}

function Get-StableBranch {
    # 1) Prefer local master/main
    $local = Invoke-Git -ArgumentList @('branch','--list','master')
    if (-not [string]::IsNullOrWhiteSpace(($local.Output | Out-String).Trim())) { return "master" }

    $local = Invoke-Git -ArgumentList @('branch','--list','main')
    if (-not [string]::IsNullOrWhiteSpace(($local.Output | Out-String).Trim())) { return "main" }

    # 2) Consult origin/HEAD
    $r = Invoke-Git -ArgumentList @('symbolic-ref','--short','refs/remotes/origin/HEAD')
    if ($r.ExitCode -eq 0) {
        $line = ($r.Output | Select-Object -First 1).Trim()
        if ($line -match '^origin/(.+)$') { return $Matches[1] }
    }

    # 3) List remote heads and pick master/main if present
    $remotes = Invoke-Git -ArgumentList @('branch','-r','--list','origin/master','origin/main')
    $txt = ($remotes.Output | Out-String)
    if ($txt -match 'origin/master') { return "master" }
    if ($txt -match 'origin/main')   { return "main"   }

    throw "Could not detect a stable branch (master/main/origin/HEAD)."
}

function Try-GetRemoteCommit {
    param([string]$Branch)
    $r = Invoke-Git -ArgumentList @('rev-parse',"origin/$Branch")
    if ($r.ExitCode -ne 0) { return $null }
    return (($r.Output | Select-Object -First 1).Trim())
}

function Get-LatestCommitMessage {
    param([string]$Branch)
    $r = Invoke-Git -ArgumentList @('log',"HEAD..origin/$Branch",'--oneline','-1')
    if ($r.ExitCode -ne 0) { return $null }
    return (($r.Output | Select-Object -First 1).Trim())
}

function Create-BackupBranch {
    $timestamp = Get-Date -Format "yyyy_MM_dd_HHmmss"
    $suffix    = (Get-Random -Maximum 9999).ToString("0000")
    $backupBranch = "backup/pre_update_${timestamp}_${suffix}"

    Write-Host "Creating rollback branch: $backupBranch" -ForegroundColor Yellow

    $r = Invoke-Git -ArgumentList @('branch',$backupBranch) -ThrowOnError
    return $backupBranch
}

# ----------------------------------------------------------------------------
# GIT HISTORY
# ----------------------------------------------------------------------------

function Get-CommitHistoryBetween {
    param([string]$FromCommit, [string]$ToCommit)

    if ([string]::IsNullOrWhiteSpace($FromCommit) -or
        [string]::IsNullOrWhiteSpace($ToCommit)) { return @() }
    if ($FromCommit -eq $ToCommit) { return @() }

    $r = Invoke-Git -ArgumentList @(
        'log', "$FromCommit..$ToCommit",
        '--format=%H`t%h`t%aI`t%an`t%s'
    )
    if ($r.ExitCode -ne 0) { return @() }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($line in $r.Output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 5
        if ($parts.Count -lt 5) { continue }
        $result.Add([pscustomobject]@{
            Commit      = $parts[0]
            ShortCommit = $parts[1]
            Date        = $parts[2]
            Author      = $parts[3]
            Subject     = $parts[4]
        })
    }
    return @($result)
}

# ----------------------------------------------------------------------------
# PERSISTENT STATE
# ----------------------------------------------------------------------------

function New-DefaultState {
    return [pscustomobject]@{
        SchemaVersion     = 4
        LastSuccessfulRun = $null
        History           = @()
        PRCache           = [pscustomobject]@{}
    }
}

function Load-UpdaterState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return New-DefaultState }

    try {
        # ReadAllText handles BOM transparently.
        $raw = [System.IO.File]::ReadAllText($StateFile)
        if ([string]::IsNullOrWhiteSpace($raw)) { return New-DefaultState }

        $state = $raw | ConvertFrom-Json
        if ($null -eq $state.SchemaVersion) { return New-DefaultState }

        if ($null -eq $state.PSObject.Properties['History']) {
            $state | Add-Member -MemberType NoteProperty -Name History -Value @()
        }
        if ($null -eq $state.PSObject.Properties['PRCache']) {
            $state | Add-Member -MemberType NoteProperty -Name PRCache -Value ([pscustomobject]@{})
        }
        $state.SchemaVersion = 4
        return $state
    }
    catch {
        Write-WarningText "WARNING: Could not read updater state file."
        Write-WarningText "A new state file will be created."
        return New-DefaultState
    }
}

function Save-UpdaterState {
    param([object]$State)

    if (-not (Test-Path -LiteralPath $UpdateDir)) {
        New-Item -ItemType Directory -Path $UpdateDir -Force | Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 20
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $tempFile  = "$StateFile.tmp"

    [System.IO.File]::WriteAllText($tempFile, $json, $utf8NoBom)

    # Atomic replace with retry.
    for ($i = 1; $i -le 5; $i++) {
        try {
            if (Test-Path -LiteralPath $StateFile) {
                [System.IO.File]::Delete($StateFile)
            }
            [System.IO.File]::Move($tempFile, $StateFile)
            return
        }
        catch {
            if ($i -eq 5) { throw }
            Start-Sleep -Milliseconds 300
        }
    }
}

function Add-HistoryEntry {
    param([object]$State, [object]$Entry)

    $history = @()
    if ($null -ne $State.History) { $history = @($State.History) }
    $history += $Entry
    if ($history.Count -gt $MaxHistoryEntries) {
        $start = $history.Count - $MaxHistoryEntries
        $history = @($history[$start..($history.Count - 1)])
    }
    $State.History = $history
}

# ----------------------------------------------------------------------------
# GITHUB PR LOOKUP
# ----------------------------------------------------------------------------

function Get-CachedPRInfo {
    param([object]$State, [string]$Commit)
    if ($null -eq $State.PRCache) { return $null }
    $prop = $State.PRCache.PSObject.Properties[$Commit]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Set-CachedPRInfo {
    param([object]$State, [string]$Commit, [object]$Value)
    if ($null -eq $State.PRCache) {
        $State | Add-Member -MemberType NoteProperty -Name PRCache -Value ([pscustomobject]@{})
    }
    $State.PRCache | Add-Member -MemberType NoteProperty -Name $Commit -Value $Value -Force
}

function Get-GitHubPRInfo {
    param([object]$State, [string]$Commit)

    $cached = Get-CachedPRInfo -State $State -Commit $Commit
    if ($null -ne $cached) { return @($cached) }

    $uri = "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/commits/$Commit/pulls"

    $headers = @{
        'Accept'             = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = $GitHubApiVersion
        'User-Agent'         = 'ComfyUI-Safe-Update-Manager'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:COMFYUI_GITHUB_TOKEN)) {
        $headers['Authorization'] = "Bearer $($env:COMFYUI_GITHUB_TOKEN)"
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 15

        $items = New-Object System.Collections.Generic.List[object]
        foreach ($pr in @($response)) {
            $items.Add([pscustomobject]@{
                Number   = [int]$pr.number
                Title    = [string]$pr.title
                State    = [string]$pr.state
                MergedAt = [string]$pr.merged_at
                URL      = [string]$pr.html_url
                User     = [string]$pr.user.login
                Draft    = [bool]$pr.draft
            })
        }
        $result = @($items.ToArray())
        Set-CachedPRInfo -State $State -Commit $Commit -Value $result
        return $result
    }
    catch {
        Write-WarningText ("PR lookup failed for {0}: {1}" -f (Get-ShortCommit $Commit), $_.Exception.Message)
        Set-CachedPRInfo -State $State -Commit $Commit -Value @()
        return @()
    }
}

function Resolve-CommitPRs {
    param([object]$State, [object[]]$Commits)
    foreach ($commit in $Commits) {
        $prs = @(Get-GitHubPRInfo -State $State -Commit $commit.Commit)
        $commit | Add-Member -MemberType NoteProperty -Name PRs -Value $prs -Force
    }
    return @($Commits)
}

# ----------------------------------------------------------------------------
# UPDATE HISTORY DISPLAY
# ----------------------------------------------------------------------------

function Show-UpdatesSinceLastRun {
    param([object]$State, [string]$CurrentBranch, [string]$RemoteCommit)

    if ($null -eq $State.LastSuccessfulRun) {
        Write-Section "Update History"
        Write-Host "No previous successful updater run is recorded."
        Write-Host "This run will establish the initial history baseline."
        return
    }

    $previousBranch = $State.LastSuccessfulRun.Branch
    $previousCommit = $State.LastSuccessfulRun.Commit

    Write-Section "Changes Since Last Successful Run"
    Write-Host ("Previous Run   : {0}" -f $State.LastSuccessfulRun.Timestamp)
    Write-Host ("Previous Branch: {0}" -f $previousBranch)
    Write-Host ("Previous Commit: {0}" -f (Get-ShortCommit $previousCommit))
    Write-Host ("Current Branch : {0}" -f $CurrentBranch)
    Write-Host ("Current Remote : {0}" -f (Get-ShortCommit $RemoteCommit))
    Write-Host ""

    if ([string]::IsNullOrWhiteSpace($previousCommit)) {
        Write-Host "Previous commit is unavailable."
        return
    }

    $commits = @(Get-CommitHistoryBetween -FromCommit $previousCommit -ToCommit $RemoteCommit)

    if ($commits.Count -eq 0) {
        if ($previousCommit -eq $RemoteCommit) {
            Write-Host "No new ComfyUI commits since the previous run." -ForegroundColor Green
        } else {
            Write-Host "No directly comparable commit history was found." -ForegroundColor Yellow
            Write-Host "This may indicate a branch rewrite or force-push."
        }
        return
    }

    Write-Host ("ComfyUI updates found: {0}" -f $commits.Count) -ForegroundColor Green
    Write-Host ""
    Write-Host "Resolving GitHub pull requests..." -ForegroundColor Cyan
    Write-Host ""

    $commits = @(Resolve-CommitPRs -State $State -Commits $commits)
    Save-UpdaterState $State

    foreach ($commit in $commits) {
        $dateText = $commit.Date
        if ($dateText.Length -gt 19) { $dateText = $dateText.Substring(0,19) }

        Write-Host ("{0}  {1}" -f $commit.ShortCommit, $dateText) -ForegroundColor DarkGray
        Write-Host ("       {0}" -f $commit.Subject)

        if ($commit.PRs.Count -gt 0) {
            foreach ($pr in @($commit.PRs)) {
                Write-Host ("       PR #{0}: {1}" -f $pr.Number, $pr.Title) -ForegroundColor Cyan
                Write-Host ("       {0}" -f $pr.URL) -ForegroundColor DarkCyan
            }
        } else {
            Write-Host "       PR: no associated PR reported by GitHub" -ForegroundColor DarkGray
        }
        Write-Host ("       Author: {0}" -f $commit.Author) -ForegroundColor DarkGray
        Write-Host ""
    }
}

# ----------------------------------------------------------------------------
# GIT VERSION
# ----------------------------------------------------------------------------

function Test-GitVersion {
    Write-Section "Git Environment"
    $gitVersion = (& git --version 2>&1) -join "`n"
    $gitPath    = (where.exe git 2>&1) -join "`n"
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
            $choice = Read-HostChoice "Select option" -Default "2"
            switch ($choice) {
                "1" { Start-Process "https://gitforwindows.org"; exit }
                "2" { }
                default { exit }
            }
        }
    }
}

# ----------------------------------------------------------------------------
# NETWORK VALIDATION
# ----------------------------------------------------------------------------

function Test-GitConnectivity {
    Write-Section "Testing GitHub Git Connectivity"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-Git -ArgumentList @(
            'ls-remote',
            "https://github.com/$GitHubOwner/$GitHubRepo.git",
            'HEAD'
        )
        $sw.Stop()
        if ($r.ExitCode -eq 0) {
            Write-Host ("Git transport: OK ({0:N2} sec)" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
            return $true
        }
        Write-Host "Git transport: FAILED" -ForegroundColor Red
        return $false
    }
    catch {
        $sw.Stop()
        Write-Host "Git transport: FAILED" -ForegroundColor Red
        Write-WarningText $_.Exception.Message
        return $false
    }
}

function Get-SpeedStatistics {
    param([System.Collections.Generic.List[double]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) {
        return [pscustomobject]@{
            Success = $false; Count = 0; Average = 0; Median = 0; Minimum = 0; Maximum = 0
        }
    }
    $sorted  = @($Values | Sort-Object)
    $average = ($Values | Measure-Object -Average).Average
    $minimum = $sorted[0]
    $maximum = $sorted[$sorted.Count - 1]
    if (($sorted.Count % 2) -eq 1) {
        $median = $sorted[[math]::Floor($sorted.Count / 2)]
    } else {
        $mid = [int]($sorted.Count / 2)
        $median = ($sorted[$mid - 1] + $sorted[$mid]) / 2
    }
    return [pscustomobject]@{
        Success = $true
        Count   = $Values.Count
        Average = [math]::Round($average, 2)
        Median  = [math]::Round($median, 2)
        Minimum = [math]::Round($minimum, 2)
        Maximum = [math]::Round($maximum, 2)
    }
}

function Test-GitHubBulkDownload {
    param([string]$Branch)

    Write-Section "Testing GitHub Bulk Download Speed"
    Write-Host "Testing the actual ComfyUI repository archive."
    Write-Host "Each test measures a complete transfer."
    Write-Host "No curl dependency is used."
    Write-Host ""

    $baseUrl = "https://codeload.github.com/$GitHubOwner/$GitHubRepo/zip/refs/heads/$Branch"

    $results = New-Object System.Collections.Generic.List[double]
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect     = $true
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($SpeedTestTimeoutSeconds)

    try {
        for ($i = 1; $i -le $SpeedTestCount; $i++) {
            Write-Host ("  Test {0}/{1}..." -f $i, $SpeedTestCount)

            $response = $null; $stream = $null; $request = $null
            try {
                $cacheBust = [guid]::NewGuid().ToString()
                $url = "$baseUrl`?speedtest=$cacheBust"

                $request = New-Object System.Net.Http.HttpRequestMessage(
                    [System.Net.Http.HttpMethod]::Get, $url
                )
                $request.Headers.UserAgent.ParseAdd("ComfyUI-Safe-Update-Manager/9")
                # Force identity encoding so we measure real bytes.
                $request.Headers.TryAddWithoutValidation('Accept-Encoding','identity') | Out-Null

                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $response = $client.SendAsync(
                    $request,
                    [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                ).GetAwaiter().GetResult()
                $response.EnsureSuccessStatusCode() | Out-Null

                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $buffer = New-Object byte[] (1024 * 1024)
                [long]$totalBytes = 0
                while ($true) {
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    $totalBytes += $read
                }
                $sw.Stop()

                if ($totalBytes -le 0 -or $sw.Elapsed.TotalSeconds -le 0) {
                    Write-Host "       Invalid transfer result." -ForegroundColor Yellow
                    continue
                }
                $mbps = ($totalBytes / 1MB) / $sw.Elapsed.TotalSeconds
                $results.Add($mbps)
                Write-Host ("       {0:N2} MB/s  |  {1:N2} MB  |  {2:N2} sec" -f `
                    $mbps, ($totalBytes / 1MB), $sw.Elapsed.TotalSeconds) -ForegroundColor Green
            }
            catch {
                Write-Host ("       FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
            finally {
                if ($null -ne $stream)   { $stream.Dispose() }
                if ($null -ne $response) { $response.Dispose() }
                if ($null -ne $request)  { $request.Dispose() }
            }
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
    return (Get-SpeedStatistics $results)
}

function Handle-NetworkValidation {
    param([string]$Branch)

    $gitOK  = Test-GitConnectivity
    Write-Host ""
    $result = Test-GitHubBulkDownload -Branch $Branch
    Write-Host ""

    if (-not $result.Success) {
        Write-Banner "WARNING: GITHUB DOWNLOAD TEST FAILED" "Red"
        Write-Host "No valid bulk download measurement was obtained."
        Write-Host ""
        Write-Host "This does NOT mean the connection is unstable." -ForegroundColor Yellow
        Write-Host "It means the speed test itself could not complete."
        if (-not $gitOK) {
            Write-Host ""
            Write-Host "Git transport testing also failed." -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "1 - Proceed anyway"
        Write-Host "2 - Exit"
        Write-Host ""
        $choice = Read-HostChoice "Select option" -Default "2"
        if ($choice -ne "1") { exit }
        return
    }

    Write-Host ("Successful Tests: {0}" -f $result.Count)
    Write-Host ("Average         : {0} MB/s" -f $result.Average)
    Write-Host ("Median          : {0} MB/s" -f $result.Median)
    Write-Host ("Minimum         : {0} MB/s" -f $result.Minimum)
    Write-Host ("Maximum         : {0} MB/s" -f $result.Maximum)
    Write-Host ""

    if ($result.Median -lt $SpeedThresholdMB) {
        Write-Banner "WARNING: SLOW GITHUB CONNECTION" "Red"
        Write-Host ("Median Speed: {0} MB/s" -f $result.Median)
        Write-Host ("Threshold   : {0} MB/s" -f $SpeedThresholdMB)
        Write-Host ""
        Write-Host "GitHub is reachable, but measured throughput is below"
        Write-Host "the configured update threshold."
        Write-Host ""
        Write-Host "1 - Proceed anyway"
        Write-Host "2 - Exit"
        Write-Host ""
        $choice = Read-HostChoice "Select option" -Default "2"
        if ($choice -ne "1") { exit }
        return
    }

    if ($gitOK) {
        Write-Host ("GitHub connection is GOOD (median {0} MB/s)." -f $result.Median) -ForegroundColor Green
    } else {
        Write-Banner "GITHUB DOWNLOAD OK - GIT TRANSPORT PROBLEM" "Yellow"
        Write-Host ("Bulk download median: {0} MB/s" -f $result.Median)
        Write-Host ""
        Write-Host "HTTP download works, but git ls-remote failed."
        Write-Host "The updater itself uses Git."
        Write-Host ""
        Write-Host "1 - Proceed anyway"
        Write-Host "2 - Exit"
        Write-Host ""
        $choice = Read-HostChoice "Select option" -Default "2"
        if ($choice -ne "1") { exit }
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
    foreach ($path in $GitProtectedPaths) { Write-Host " - $path" }
    Write-Host ""
    Write-Host "1 - CONFIRM FORCE CLEANUP"
    Write-Host "2 - Cancel"
    Write-Host ""
    $confirm = Read-HostChoice "Select option" -Default "2"
    if ($confirm -ne "1") { exit }

    Write-Section "Cleaning Working Tree"
    Invoke-Git -ArgumentList @('reset','--hard') -ThrowOnError | Out-Null

    $cleanArgs = @('clean','-fd')
    foreach ($p in $GitProtectedPaths) { $cleanArgs += @('-e', $p) }
    Invoke-Git -ArgumentList $cleanArgs -ThrowOnError | Out-Null
}

# ----------------------------------------------------------------------------
# PROTECTED FOLDER HANDLING
# ----------------------------------------------------------------------------

function Test-IsReparsePoint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -Force)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }
    catch { return $false }
}

function Remove-ItemWithRetry {
    param([string]$Path, [int]$Attempts = 3, [int]$DelayMs = 500)
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            if (Test-Path -LiteralPath $Path -Force) {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            }
            return
        }
        catch {
            if ($i -eq $Attempts) { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Backup-ProtectedFolders {
    Write-Section "Protecting Protected Folders"
    $protected = New-Object System.Collections.Generic.List[object]

    foreach ($folder in $FoldersToProtect) {
        $path = Join-Path $ComfyPath $folder
        if (-not (Test-Path -LiteralPath $path -Force)) {
            Write-Host ("Not present: {0}" -f $folder)
            continue
        }
        $backupName = "${folder}_backup"
        $backupPath = Join-Path $ComfyPath $backupName
        if (Test-Path -LiteralPath $backupPath -Force) {
            throw ("Backup path already exists: {0}`nRefusing to overwrite it." -f $backupPath)
        }
        $typeText = "folder"
        if (Test-IsReparsePoint $path) { $typeText = "symlink/junction" }
        Write-Host ("Protecting {0} ({1}) -> {2}" -f $folder, $typeText, $backupName) -ForegroundColor Yellow
        Rename-Item -LiteralPath $path -NewName $backupName
        $protected.Add([pscustomobject]@{
            Folder     = $folder
            BackupName = $backupName
            BackupPath = $backupPath
            Type       = $typeText
        })
    }
    return @($protected)
}

function Cleanup-UpdaterFolders {
    Write-Section "Removing Updater-Created Protected Folder Copies"
    foreach ($folder in $FoldersToProtect) {
        $path = Join-Path $ComfyPath $folder
        if (Test-Path -LiteralPath $path -Force) {
            Write-Host ("Removing updater-created: {0}" -f $folder)
            Remove-ItemWithRetry -Path $path
        }
    }
}

function Restore-ProtectedFolders {
    param([object[]]$ProtectedFolders)
    Write-Section "Restoring Protected Folders"

    foreach ($entry in $ProtectedFolders) {
        $backupPath = $entry.BackupPath
        $targetPath = Join-Path $ComfyPath $entry.Folder

        if (-not (Test-Path -LiteralPath $backupPath -Force)) {
            throw ("Backup missing for protected folder: {0}" -f $entry.Folder)
        }
        if (Test-Path -LiteralPath $targetPath -Force) {
            Write-Host ("Removing updater-created {0}" -f $entry.Folder)
            Remove-ItemWithRetry -Path $targetPath
        }
        Write-Host ("Restoring {0} -> {1}" -f $entry.BackupName, $entry.Folder) -ForegroundColor Green
        Rename-Item -LiteralPath $backupPath -NewName $entry.Folder
        if (-not (Test-Path -LiteralPath $targetPath -Force)) {
            throw ("Restoration verification failed for: {0}" -f $entry.Folder)
        }
    }
}

function Show-BackupLocations {
    param([object[]]$ProtectedFolders)
    Write-Host ""
    Write-Host "The original protected folders were left as backups:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($entry in $ProtectedFolders) {
        Write-Host (" - {0}" -f $entry.BackupPath) -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Do NOT delete these backups until the failed update"
    Write-Host "has been investigated."
}

# ----------------------------------------------------------------------------
# UPDATE VERIFICATION
# ----------------------------------------------------------------------------

function Test-UpdateSucceeded {
    param([string]$ExpectedBranch, [string]$ExpectedCommit, [int]$UpdaterExitCode)

    Write-Section "Verifying Update"
    if ($UpdaterExitCode -ne 0) {
        Write-Host ("update_comfyui.bat exit code: {0}" -f $UpdaterExitCode) -ForegroundColor Red
        return $false
    }
    $actualBranch = Get-CurrentBranch
    $actualCommit = Get-CurrentCommit

    Write-Host ("Expected Branch : {0}" -f $ExpectedBranch)
    Write-Host ("Actual Branch   : {0}" -f $actualBranch)
    Write-Host ("Expected Commit : {0}" -f (Get-ShortCommit $ExpectedCommit))
    Write-Host ("Actual Commit   : {0}" -f (Get-ShortCommit $actualCommit))
    Write-Host ""

    if ($actualBranch -ne $ExpectedBranch) {
        Write-Host "UPDATE VERIFICATION FAILED:" -ForegroundColor Red
        Write-Host "The updater changed the active branch unexpectedly."
        return $false
    }
    if ($actualCommit -ne $ExpectedCommit) {
        Write-Host "UPDATE VERIFICATION FAILED:" -ForegroundColor Red
        Write-Host "HEAD does not match the expected remote commit."
        return $false
    }
    Write-Host "Git state verification: PASSED" -ForegroundColor Green
    return $true
}

# ----------------------------------------------------------------------------
# UPDATE EXECUTION
# ----------------------------------------------------------------------------

function Run-Update {
    param([string]$ExpectedBranch, [string]$ExpectedCommit)

    $protectedFolders = @()
    $preUpdateCommit  = Get-CurrentCommit

    try {
        $protectedFolders = @(Backup-ProtectedFolders)

        Write-Section "Running ComfyUI Update"
        Push-Location $UpdateDir
        $updaterExitCode = 0
        try {
            # Use cmd /c so .bat exit code propagates via $LASTEXITCODE.
            cmd /c update_comfyui.bat
            $updaterExitCode = $LASTEXITCODE
            if ($null -eq $updaterExitCode) { $updaterExitCode = 0 }
        }
        finally { Pop-Location }

        Write-Host ""
        Write-Host ("update_comfyui.bat exit code: {0}" -f $updaterExitCode)

        $success = Test-UpdateSucceeded `
            -ExpectedBranch $ExpectedBranch `
            -ExpectedCommit $ExpectedCommit `
            -UpdaterExitCode $updaterExitCode

        if (-not $success) {
            Write-Banner "UPDATE FAILED - PROTECTED FOLDERS LEFT SAFE" "Red"
            Write-Host "The resulting Git state could not be verified."
            Write-Host ""
            Write-Host "The original protected folders have NOT been"
            Write-Host "automatically reattached to a changed tree."
            Show-BackupLocations $protectedFolders
            return [pscustomobject]@{
                Success          = $false
                PreUpdateCommit  = $preUpdateCommit
                PostUpdateCommit = Get-CurrentCommit
                Branch           = Get-CurrentBranch
                ProtectedFolders = $protectedFolders
            }
        }

        Cleanup-UpdaterFolders
        Restore-ProtectedFolders -ProtectedFolders $protectedFolders

        return [pscustomobject]@{
            Success          = $true
            PreUpdateCommit  = $preUpdateCommit
            PostUpdateCommit = Get-CurrentCommit
            Branch           = Get-CurrentBranch
            ProtectedFolders = $protectedFolders
        }
    }
    catch {
        Write-Banner "UPDATE ERROR" "Red"
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ""
        if ($protectedFolders.Count -gt 0) { Show-BackupLocations $protectedFolders }
        return [pscustomobject]@{
            Success          = $false
            PreUpdateCommit  = $preUpdateCommit
            PostUpdateCommit = Get-CurrentCommit
            Branch           = Get-CurrentBranch
            ProtectedFolders = $protectedFolders
        }
    }
}

# ----------------------------------------------------------------------------
# SAVE SUCCESSFUL RUN
# ----------------------------------------------------------------------------

function Save-SuccessfulRun {
    param(
        [object]$State,
        [string]$Branch,
        [string]$PreUpdateCommit,
        [string]$PostUpdateCommit,
        [bool]$UpdatePerformed
    )

    $timestamp = (Get-Date).ToString("o")
    $entry = [pscustomobject]@{
        Timestamp       = $timestamp
        Branch          = $Branch
        UpdatePerformed = $UpdatePerformed
        Commit          = $PostUpdateCommit
        CommitShort     = Get-ShortCommit $PostUpdateCommit
        PreviousCommit  = $PreUpdateCommit
        PreviousShort   = Get-ShortCommit $PreUpdateCommit
    }

    Add-HistoryEntry -State $State -Entry $entry
    $State.LastSuccessfulRun = $entry
    Save-UpdaterState $State
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------

Clear-Host
Write-Banner "ComfyUI Safe Update Manager v9" "Cyan"

Test-GitVersion

if (-not (Test-Path -LiteralPath $ComfyPath))  { throw "ComfyUI folder not found: $ComfyPath" }
if (-not (Test-Path -LiteralPath $UpdateDir))  { throw "Update folder not found: $UpdateDir" }

$state = Load-UpdaterState

Push-Location $ComfyPath
try {
    Write-Section "Fetching Remote Information"
    $fetch = Invoke-Git -ArgumentList @('fetch','origin') -ThrowOnError
    Write-Host ($fetch.Output | Out-String).Trim()

    $currentBranch = Get-CurrentBranch
    if ([string]::IsNullOrWhiteSpace($currentBranch) -or $currentBranch -eq 'HEAD') {
        throw "ComfyUI is in a detached HEAD state. Please checkout a branch first (e.g., master or main)."
    }
    $currentCommit = Get-CurrentCommit
    $stableBranch  = Get-StableBranch
    $isStable      = ($currentBranch -eq "master" -or $currentBranch -eq "main")

    # =========================================================================
    # STABLE BRANCH
    # =========================================================================
    if ($isStable) {
        $remoteCommit = Try-GetRemoteCommit -Branch $stableBranch
        if (-not $remoteCommit) { throw "Could not determine origin/$stableBranch commit." }

        Show-UpdatesSinceLastRun -State $state -CurrentBranch $stableBranch -RemoteCommit $remoteCommit

        $latestMsg = Get-LatestCommitMessage -Branch $stableBranch

        Write-Banner "BRANCH: $($stableBranch.ToUpper())" "Green"
        Write-Host ("Current Commit : {0}" -f (Get-ShortCommit $currentCommit)) -ForegroundColor Green
        Write-Host ("Updating To    : {0}" -f (Get-ShortCommit $remoteCommit)) -ForegroundColor Green
        if (-not [string]::IsNullOrWhiteSpace($latestMsg)) {
            Write-Host ("Latest Change  : {0}" -f $latestMsg) -ForegroundColor Green
        }

        if ($currentCommit -eq $remoteCommit) {
            Write-Host ""
            Write-Host "ComfyUI is already up to date." -ForegroundColor Green
            Save-SuccessfulRun -State $state -Branch $currentBranch `
                -PreUpdateCommit $currentCommit -PostUpdateCommit $currentCommit `
                -UpdatePerformed $false
            if (-not $NonInteractive) { pause }
            exit
        }

        Handle-NetworkValidation -Branch $stableBranch

        $updateResult = Run-Update -ExpectedBranch $stableBranch -ExpectedCommit $remoteCommit

        if (-not $updateResult.Success) {
            Write-Host ""
            Write-Host "Updater state was NOT advanced." -ForegroundColor Yellow
            Write-Host "The next run will still use the last successful"
            Write-Host "commit as its history baseline."
            if (-not $NonInteractive) { pause }
            exit 1
        }

        Save-SuccessfulRun -State $state -Branch $updateResult.Branch `
            -PreUpdateCommit $updateResult.PreUpdateCommit `
            -PostUpdateCommit $updateResult.PostUpdateCommit `
            -UpdatePerformed $true
    }
    # =========================================================================
    # PR / EXPERIMENTAL BRANCH
    # =========================================================================
    else {
        $remoteCommit = Try-GetRemoteCommit -Branch $currentBranch
        if (-not $remoteCommit) { $remoteCommit = "NO REMOTE TRACKING" }

        if ($remoteCommit -ne "NO REMOTE TRACKING") {
            Show-UpdatesSinceLastRun -State $state -CurrentBranch $currentBranch -RemoteCommit $remoteCommit
        }

        Write-Banner "WARNING: PR / EXPERIMENTAL BRANCH DETECTED" "Red"
        Write-Host ("Branch         : {0}" -f $currentBranch) -ForegroundColor Red
        Write-Host ("Current Commit : {0}" -f (Get-ShortCommit $currentCommit)) -ForegroundColor Red
        Write-Host ("Remote Commit  : {0}" -f (Get-ShortCommit $remoteCommit)) -ForegroundColor Red

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
        $choice = Read-HostChoice "Select option" -Default "4"

        switch ($choice) {
            "1" {
                Create-BackupBranch | Out-Null
                if ($remoteCommit -eq "NO REMOTE TRACKING") {
                    Write-Banner "CANNOT VERIFY PR UPDATE TARGET" "Red"
                    Write-Host "This branch has no origin tracking branch."
                    if (-not $NonInteractive) { pause }
                    exit 1
                }
                Handle-NetworkValidation -Branch $currentBranch
                $updateResult = Run-Update -ExpectedBranch $currentBranch -ExpectedCommit $remoteCommit
                if (-not $updateResult.Success) {
                    Write-Host ""
                    Write-Host "Updater state was NOT advanced." -ForegroundColor Yellow
                    if (-not $NonInteractive) { pause }
                    exit 1
                }
                Save-SuccessfulRun -State $state -Branch $updateResult.Branch `
                    -PreUpdateCommit $updateResult.PreUpdateCommit `
                    -PostUpdateCommit $updateResult.PostUpdateCommit `
                    -UpdatePerformed $true
            }
            "2" {
                Create-BackupBranch | Out-Null
                if ($dirty) { Force-CleanupWorkingTree }

                Write-Section "Returning To Stable Branch"
                Invoke-Git -ArgumentList @('checkout',$stableBranch) -ThrowOnError | Out-Null
                Invoke-Git -ArgumentList @('reset','--hard',"origin/$stableBranch") -ThrowOnError | Out-Null

                $stableRemoteCommit = Try-GetRemoteCommit -Branch $stableBranch
                if (-not $stableRemoteCommit) { throw "Could not determine stable remote commit." }

                Handle-NetworkValidation -Branch $stableBranch
                $updateResult = Run-Update -ExpectedBranch $stableBranch -ExpectedCommit $stableRemoteCommit
                if (-not $updateResult.Success) {
                    Write-Host ""
                    Write-Host "Updater state was NOT advanced." -ForegroundColor Yellow
                    if (-not $NonInteractive) { pause }
                    exit 1
                }
                Save-SuccessfulRun -State $state -Branch $updateResult.Branch `
                    -PreUpdateCommit $updateResult.PreUpdateCommit `
                    -PostUpdateCommit $updateResult.PostUpdateCommit `
                    -UpdatePerformed $true
            }
            "3" {
                Show-ModifiedFiles
                if (-not $NonInteractive) { pause }
                exit
            }
            default { exit }
        }
    }

    # =========================================================================
    # SUCCESS
    # =========================================================================
    Write-Banner "UPDATE COMPLETED SUCCESSFULLY" "Green"
    Write-Host ("Final Commit: {0}" -f (Get-ShortCommit (Get-CurrentCommit))) -ForegroundColor Green
    Write-Host ""
    Write-Host "Protected folders/symlinks were restored automatically." -ForegroundColor Green
    Write-Host ""
    Write-Host "Update history saved to:"
    Write-Host $StateFile -ForegroundColor Cyan
}
finally {
    Pop-Location
    if ($null -ne $TranscriptPath) {
        try { Stop-Transcript | Out-Null } catch {}
        Write-Host ""
        Write-Host "Transcript written to: $TranscriptPath" -ForegroundColor Cyan
    }
}

if (-not $NonInteractive) { pause }


---

## Notes on Key Fixes

<details>
<summary><b>Why <code>Invoke-Expression</code> was removed</b></summary>

Invoke-Expression "git $Arguments" re-parses the string through the PowerShell parser. That means:
- A protected path with a space (-e "my folder") would tokenize incorrectly.
- Quotes inside arguments are interpreted by PowerShell, not preserved as a single argv entry for git.
- Error messages thrown by Invoke-Expression lose the original native command context.

Using & git @ArgumentList with an array passes each element as a distinct argv entry, exactly the way native programs expect. No re-parsing occurs.

</details>

<details>
<summary><b>Why state file writing changed</b></summary>

Set-Content -Encoding UTF8 on Windows PowerShell 5.1 emits a 3-byte UTF-8 BOM. The BOM becomes part of the JSON document and can break round-tripping in stricter parsers. [System.IO.File]::WriteAllText with New-Object System.Text.UTF8Encoding($false) writes BOM-less UTF8. The temp-file + delete + move pattern is atomic on the same volume and avoids the partial-write window.

</details>

<details>
<summary><b>Why <code>origin/HEAD</code> detection was added</b></summary>

ComfyUI's default branch has shifted between master and main over time, and forks sometimes rename it. A fresh shallow clone may not have a local master or main branch but does have refs/remotes/origin/HEAD. The new Get-StableBranch consults git symbolic-ref --short refs/remotes/origin/HEAD as a fallback.

</details>

<details>
<summary><b>Optional GitHub token</b></summary>

Set $env:COMFYUI_GITHUB_TOKEN before running to authenticate PR lookups. This raises the rate limit from 60 to 5000 requests/hour, which matters when many commits need PR resolution on the first run after a long absence.

</details>

<details>
<summary><b>Non-interactive mode</b></summary>

.\update.ps1 -NonInteractive

Nemotron 3 Super review :
## Review & Upgrade Suggestions for ComfyUI Safe Update Manager v8

I've reviewed your PowerShell script and found it to be well-structured with many thoughtful safety features. However, I identified **one critical bug** that must be fixed, along with several improvements for robustness and maintainability.

---

### 🚨 Critical Bug: Git Connectivity Test Always Reports Success

**Location:** Test-GitConnectivity function

**Problem:**  
The function uses a pipeline that pipes git ls-remote output to Out-Null, then checks $LASTEXITCODE. Because Out-Null always exits with code 0, the connectivity test will **always report success** even when GitHub is unreachable or the git command fails.

**Current (broken) code:**

powershell
git ls-remote "https://github.com/$GitHubOwner/$GitHubRepo.git" HEAD 2>&1 | Out-Null
$exitCode = $LASTEXITCODE


**Fix:**  
Capture the exit code *before* piping to Out-Null, or avoid the pipe altogether:


powershell
# Option 1: Capture exit code before piping
$gitOutput = git ls-remote "https://github.com/$GitHubOwner/$GitHubRepo.git" HEAD 2>&1
$exitCode = $LASTEXITCODE
$gitOutput | Out-Null   # Optional: suppress output if desired

# Option 2: Don't pipe at all (simpler)
git ls-remote "https://github.com/$GitHubOwner/$GitHubRepo.git" HEAD 2>$null
$exitCode = $LASTEXITCODE


**Impact:** Without this fix, the updater may proceed with updates even when there's no actual network connectivity, leading to confusing failures later.

---

### 🔧 Recommended Improvements

#### 1. Replace Invoke-Expression with Direct Invocation
**Location:** Invoke-Git function

**Why:** Invoke-Expression poses injection risks and can mishandle arguments with special characters.

**Current:**

powershell
return (Invoke-Expression "git $Arguments" 2>&1)


**Improved:**

powershell
return (& git $Arguments 2>&1)

Or simply:

powershell
git $Arguments 2>&1


#### 2. Make Git Helper Functions More Robust
Several functions (Get-CurrentBranch, Get-CurrentCommit, etc.) return error messages as strings when git fails, which can cause downstream issues (e.g., treating a fatal error string as a commit hash).

**Suggested approach:**  
Have these functions return $null on failure and let callers handle the absence of a value. Alternatively, throw terminating errors for unexpected failures.

**Example for Get-CurrentCommit:**

powershell
function Get-CurrentCommit {
    Push-Location $ComfyPath
    try {
        $commit = git rev-parse HEAD 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Verbose "Failed to get current commit: $commit"
            return $null
        }
        return $commit.Trim()
    }
    finally {
        Pop-Location
    }
}


#### 3. Use Null Delimiter in Git Log Parsing
**Location:** Get-CommitHistoryBetween

**Why:** Commit subjects can technically contain tabs, which would break the current tab-delimited parsing.

**Improved approach:** Use a null character (%x00) as delimiter, which is guaranteed not to appear in git field values.

**Example:**

powershell
$lines = @(
    git log "$FromCommit..$ToCommit" `
        --format="%H%x00%h%x00%aI%x00%an%x00%s" `
        --null   # Or use -z with --format
    2>&1
)
# Then split each line on [char]0


#### 4. Add Pre‑Flight Check for update_comfyui.bat**
**Location:** Run-Update function

**Why:** If the batch file is missing, the script will fail ambiguously.

**Suggested addition:**

powershell
$batPath = Join-Path $UpdateDir "update_comfyui.bat"
if (-not (Test-Path -LiteralPath $batPath)) {
    throw "Updater script not found: $batPath"
}


#### 5. Consider Using -WhatIf or -Confirm for Destructive Actions
While the script already has interactive prompts for risky operations (like force cleanup), you could leverage PowerShell's native -WhatIf and -Confirm parameters for functions like Backup-ProtectedFolders or Restore-ProtectedFolders to allow dry‑run testing.

---

### ✅ Summary of Critical Fix
The **most urgent issue** is the broken Git connectivity test. Fixing that will prevent the updater from falsely claiming network health and proceeding with updates when offline.

All other suggestions are aimed at improving robustness, security, and maintainability. Given the script's complexity and importance (it manages your ComfyUI installation), addressing these points will make it more reliable.

Would you like me to provide a **patch file** showing the exact changes for the critical bug and any of the suggested improvements? Or would you prefer a full revised version of the script with all fixes applied? Let me know how you'd like to proceed.



Aha. This is the missing piece. And it changes my conclusion quite a bit.

update.py shows that the actual ComfyUI updater is not doing a normal git pull at all. It uses pygit2 and performs its own fetch/checkout/merge logic.

More importantly, I don't see anything in this update.py that intentionally deletes models, output, or input.

The relevant operations are essentially:

stash
create backup branch
checkout master
fetch/pull
checkout_tree(...)
merge if necessary

There is no git clean and no explicit recursive deletion of those directories.

That means your symlink workaround is probably unnecessary

The important operation is:

repo.checkout_tree(repo.get(remote_master_id))

That updates the Git-managed tree. It does not, by itself, mean "delete every directory that isn't in the tree".

So your original ANTs BAT:

rename models models_backup
rename output output_backup
rename input input_backup

call update_comfyui.bat

rmdir models
rmdir output
rmdir input

rename *_backup originals

was a defensive workaround around the stock updater's behavior, but the update.py you supplied doesn't actually contain the destructive operation we were protecting against.

There is one very important caveat, though:

We still need the BAT to know exactly what gets executed

The Python file ends up being invoked through one of these:

update_comfyui.bat
update_comfyui_stable.bat

and there is also:

update_comfyui_and_python_dependencies.bat

The actual BAT may pass arguments such as --stable, --skip_self_update, or invoke Python in a particular way.

So I don't want to blindly declare the symlink protection obsolete yet.

But I can already make the design substantially cleaner.

What I would change in v11

Instead of:

rename symlink
   ↓
run updater
   ↓
delete whatever appeared there
   ↓
restore symlink

we can do:

inspect protected path
       ↓
verify it is a symlink/junction
       ↓
verify Git does NOT track that path
       ↓
leave it completely untouched
       ↓
run updater
       ↓
verify Git update
       ↓
verify symlink still exists

That is vastly safer.

And we can make the check machine-verifiable, rather than trusting assumptions.

For each protected path:

models
output
input

we can ask Git:

git ls-files --error-unmatch -- models

If Git says the path isn't tracked, that's strong evidence it belongs entirely outside the repository's managed tree.

We can also check:

git check-ignore -q -- models

to confirm Git considers it ignored.

So the preflight could report:

Protected Paths
------------------------------------------------------------

models
    Type       : symlink/junction
    Git tracked: NO
    Git ignored: YES
    Action     : LEAVE UNTOUCHED

output
    Type       : symlink/junction
    Git tracked: NO
    Git ignored: YES
    Action     : LEAVE UNTOUCHED

input
    Type       : symlink/junction
    Git tracked: NO
    Git ignored: YES
    Action     : LEAVE UNTOUCHED

That would be much more intelligent than blindly renaming them.

And there is another valuable discovery here

Your update.py has its own rollback branch:

backup_branch_name = 'backup_branch_{}'.format(
    datetime.today().strftime('%Y-%m-%d_%H_%M_%S')
)

So we don't necessarily need our own second backup branch for the normal update path.

It already does:

current HEAD
     ↓
backup_branch_YYYY-MM-DD_HH_MM_SS
     ↓
update

Our PowerShell manager can still create its own more clearly named rollback branch if desired, but we should be conscious that we're currently creating two layers of rollback state.

That may be unnecessary.

There is also a potentially important branch problem

This line:

branch = repo.lookup_branch('master')

and later:

pull(repo)

with:

def pull(repo, remote_name='origin', branch='master'):

means this updater is very explicitly master-oriented.

So our PowerShell manager's branch-awareness is actually more important than I thought.

If you're on a PR/experimental branch and invoke the normal ComfyUI updater, this Python code can move you back to master.

That is exactly the sort of thing our manager should prevent.

So the architecture should remain:

PowerShell manager
        │
        ├── stable branch
        │      ↓
        │   allow updater
        │
        └── PR branch
               ↓
        don't blindly invoke updater

or we deliberately invoke the updater in the appropriate mode.

One more thing I notice

The update script copies a new version of itself:

repo_update_py_path = os.path.join(
    repo_path,
    ".ci/update_windows/update.py"
)

then:

shutil.copy(
    repo_update_py_path,
    os.path.join(cur_path, "update_new.py")
)
exit()

So the updater can intentionally terminate early after self-updating.

That's extremely important for our PowerShell verification logic.

The sequence can legitimately be:

update_comfyui.bat
        ↓
update.py
        ↓
detect new updater
        ↓
create update_new.py
        ↓
exit

That could give us:

exit code = 0
HEAD = updated commit

which is actually a successful update.

So checking only the BAT's exit code would be insufficient — which is another reason the HEAD == expected remote commit verification we added was the right idea.

So I think we've finally got the architecture right

The safe manager shouldn't be an elaborate wrapper around the old ANTs BAT.

It should instead understand the actual ComfyUI updater:

                     SAFE UPDATE MANAGER
                              │
            ┌─────────────────┼──────────────────┐
            │                 │                  │
         Git state        protected paths     updater
            │                 │                  │
       fetch origin        inspect              │
       remote HEAD         Git index             │
       branch              reparse point         │
            │                 │                  ▼
            │                 │            update_comfyui.bat
            │                 │                  │
            │                 │                  ▼
            │                 │             update.py
            │                 │                  │
            │                 │                  ▼
            │                 │              pygit2
            │                 │                  │
            └─────────────────┼──────────────────┘
                              ▼
                       verify resulting HEAD
                              │
                              ▼
                   verify protected paths
                              │
                              ▼
                           SUCCESS

And no rename/restore at all, provided the preflight confirms those paths are untracked/ignored.

What I still need

You gave me update.py, which is extremely useful.

Now I need the contents of:

update_comfyui.bat

from that same update folder.

That's the one piece that tells us exactly how the Python updater is called.

Once we have it, I can make the next version genuinely based on how ComfyUI's updater actually works, rather than continuing to extrapolate from the old ANTs wrapper.

And yes — this also means we can probably kill the whole models_backup / output_backup / input_backup circus for good. ))

More importantly, I don't see anything in this update.py that intentionally deletes models, output, or input. - that is actually the idiotic behavior of either gith pull itself or comfyui's own specific idiocy

Yes — that's an important correction. I was too quick to infer "the wrapper is protecting against something that isn't actually happening." Something absolutely is deleting/replacing those directories in your real update path. The fact that it isn't explicitly written as rmdir in update.py doesn't mean the Git operation can't do it.

And looking at update.py again, there is a much more likely culprit than ordinary git pull semantics:

repo.checkout_tree(repo.get(remote_master_id))

That is a working-tree checkout operation implemented through pygit2. It is not equivalent to merely fetching objects. It reconciles the filesystem with the target Git tree.

So the actual chain is more like:

update.py
    ↓
remote.fetch()
    ↓
merge_analysis()
    ↓
FASTFORWARD
    ↓
repo.checkout_tree(target_tree)
    ↓
working tree is reconciled with target Git tree

And in the normal case that's exactly where I'd now investigate the disappearing symlinks.

Why this matters

Git's low-level checkout machinery can replace filesystem entries when the target tree requires a different filesystem representation.

For example:

filesystem before:

models -> D:\AI\Models       (symlink)


target Git tree:

models/
    .gitkeep


checkout target
      ↓
filesystem must match Git tree

The checkout machinery may need to remove the existing models entry before putting the tracked tree's contents there.

That is very different from:

git pull randomly deletes untracked folders.

So I'd refine the statement to:

The destructive behavior is almost certainly in the Git working-tree reconciliation performed by ComfyUI's pygit2 updater, rather than fetch itself.

Whether the underlying cause is a tracked placeholder such as .gitkeep, a path transition, checkout strategy, or ComfyUI's repository layout needs to be established from the actual Git tree.

And this changes our solution

Your original rename trick was not stupid at all. It was protecting against exactly this:

           symlink
              │
              ▼
       pygit2 checkout
              │
              ▼
       "make filesystem
        match Git tree"
              │
              ▼
       symlink disappears

The better solution would indeed be to prevent the checkout operation from touching those paths, rather than moving them away and reconstructing them afterward.

And pygit2 gives us a much more interesting possibility than wrapping the BAT.

The current code does:

repo.checkout_tree(repo.get(remote_master_id))

We could potentially change the update mechanism to use a checkout strategy that explicitly preserves those paths.

However, I don't want to invent pygit2 flags from memory. The exact checkout strategy flags supported by the version ComfyUI bundles matter here.

There's another useful diagnostic we can do before changing anything

We can determine whether Git actually considers these paths part of the repository's tree.

From your ComfyUI directory:

git ls-tree -r HEAD -- models
git ls-tree -r HEAD -- output
git ls-tree -r HEAD -- input

and:

git status --short --untracked-files=all -- models output input
git check-ignore -v models output input

That will tell us whether we're dealing with:

A. tracked paths

or:

B. ignored/untracked paths being affected by checkout

or:

C. symlink/path replacement caused by a tree transition

That distinction matters enormously.

But I agree with your main point

The goal should not be:

rename
→ update
→ discover damage
→ delete damage
→ restore symlink

The goal should be:

models/output/input
             │
             ▼
       "hands off"
             │
             ▼
      perform ComfyUI update
             │
             ▼
      verify everything

And now that we've seen update.py, I think the right place to solve it is at the checkout/update layer, not in a PowerShell rename workaround.

So before I write another 500-line updater and make you become the QA department again 😄, I'd like to establish exactly what Git sees for those three paths. The four git ls-tree / git check-ignore commands above will answer that very quickly.

can you wrap the diagnostics you need me to run into one single bat or ps file which would then create a diagnostic output md next to it or a txt - doesnt matter which 



Antanas - let's continue from here
