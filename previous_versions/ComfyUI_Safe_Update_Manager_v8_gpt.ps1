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
