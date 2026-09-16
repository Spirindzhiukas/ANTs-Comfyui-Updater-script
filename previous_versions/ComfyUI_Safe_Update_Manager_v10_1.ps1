# ============================================================================
# ComfyUI Safe Update Manager v10.1
# ============================================================================
# Safe updater for ComfyUI portable installations.
#
# v10.1:
# - Safe native Git invocation using argument arrays; no Invoke-Expression
# - All important Git operations check exit codes
# - Fetch failure aborts before update decisions are made
# - Stable branch detection uses local master/main and origin/HEAD fallback
# - Detached HEAD is detected explicitly
# - Protected folders are backed up before update and restored automatically
#   ONLY after the Git update is fully verified
# - Failed/partial updates leave protected-folder backups intact
# - update_comfyui.bat existence check before changing protected folders
# - Real updater-process timeout implemented without nonexistent
#   Start-Process -TimeoutSeconds
# - Timeout can be extended interactively; non-interactive mode terminates
# - Timeout termination kills the cmd process tree
# - Persistent state with BOM-less UTF-8 and backup recovery
# - Stores successful-run commit and actual change set
# - Displays changes since last successful run
# - Resolves actual GitHub PR numbers/titles when possible
# - GitHub PR metadata is enrichment only; API failure never blocks updates
# - Transient PR API failures are NOT cached as "no PR"
# - Optional GitHub token support through COMFYUI_GITHUB_TOKEN
# - Rate-limit awareness and unauthenticated lookup cap
# - Reliable .NET bulk GitHub speed test; no curl and no per-second sampling
# - Explicit Accept-Encoding: identity for speed testing
# - Optional transcript logging
# - Optional -NonInteractive mode
#
# Target environment: Windows PowerShell 5.1+ / PowerShell 7+
# ============================================================================

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$EnableTranscript
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ----------------------------------------------------------------------------
# RUNTIME COMPATIBILITY
# ----------------------------------------------------------------------------

try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
}
catch {
    throw "System.Net.Http could not be loaded. $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# CONFIG
# ----------------------------------------------------------------------------

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ComfyPath  = Join-Path $ScriptRoot "ComfyUI"
$UpdateDir  = Join-Path $ScriptRoot "update"

# Persistent updater state
$StateFile     = Join-Path $UpdateDir "ComfyUI_SafeUpdateManager_State.json"
$StateBackup   = "$StateFile.bak"
$StateTemp     = "$StateFile.tmp"

# Protected folders
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

# GitHub
$GitHubOwner     = "Comfy-Org"
$GitHubRepo      = "ComfyUI"
$GitHubApiVersion = "2026-03-10"

# Network
$SpeedThresholdMB        = 5
$SpeedTestCount          = 3
$SpeedTestTimeoutSeconds = 30

# Updater BAT timeout
$UpdaterTimeoutSeconds = 900

# API / history
$MaxHistoryEntries = 50
$MaxApiRetries     = 3
$UnauthenticatedPRLookupLimit = 45

# Transcript
$TranscriptPath = $null

# ----------------------------------------------------------------------------
# TRANSCRIPT
# ----------------------------------------------------------------------------

if ($EnableTranscript) {
    if (-not (Test-Path -LiteralPath $UpdateDir)) {
        New-Item -ItemType Directory -Path $UpdateDir -Force | Out-Null
    }

    $stamp = Get-Date -Format "yyyy_MM_dd_HHmmss"
    $TranscriptPath = Join-Path $UpdateDir "SafeUpdateManager_$stamp.log"

    try {
        Start-Transcript -LiteralPath $TranscriptPath -Force | Out-Null
    }
    catch {
        $TranscriptPath = $null
        Write-Warning "Could not start transcript logging. Continuing without transcript."
    }
}

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

function Read-HostChoice {
    param(
        [string]$Prompt,
        [string]$NonInteractiveDefault = "2"
    )

    if ($NonInteractive) {
        Write-Host "$Prompt [non-interactive -> $NonInteractiveDefault]"
        return $NonInteractiveDefault
    }

    return (Read-Host $Prompt)
}

function Wait-ForExitPrompt {
    if (-not $NonInteractive) {
        pause
    }
}

# ----------------------------------------------------------------------------
# GIT HELPERS
# ----------------------------------------------------------------------------

function Invoke-Git {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [switch]$ThrowOnError
    )

    Push-Location $ComfyPath

    try {
        $output = @(& git @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE

        if ($null -eq $exitCode) {
            $exitCode = 0
        }

        if ($ThrowOnError -and $exitCode -ne 0) {
            $message = ($output | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = "git returned exit code $exitCode."
            }

            throw "git $($ArgumentList -join ' ') failed (exit $exitCode).`n$message"
        }

        return [PSCustomObject]@{
            Output   = $output
            ExitCode = $exitCode
        }
    }
    finally {
        Pop-Location
    }
}

function Get-CurrentBranch {

    $result = Invoke-Git -ArgumentList @(
        "rev-parse",
        "--abbrev-ref",
        "HEAD"
    )

    if ($result.ExitCode -ne 0) {
        return $null
    }

    $branch = ($result.Output | Select-Object -First 1).ToString().Trim()

    if ([string]::IsNullOrWhiteSpace($branch)) {
        return $null
    }

    return $branch
}

function Get-CurrentCommit {

    $result = Invoke-Git -ArgumentList @(
        "rev-parse",
        "HEAD"
    ) -ThrowOnError

    $commit = ($result.Output | Select-Object -First 1).ToString().Trim()

    if (-not ($commit -match '^[0-9a-fA-F]{40}$')) {
        throw "Could not determine current Git commit. Returned value: '$commit'"
    }

    return $commit
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

    $result = Invoke-Git -ArgumentList @(
        "status",
        "--porcelain"
    )

    $text = ($result.Output | Out-String).Trim()

    return -not [string]::IsNullOrWhiteSpace($text)
}

function Show-ModifiedFiles {

    Write-Section "Modified Files"

    $result = Invoke-Git -ArgumentList @(
        "status",
        "--short"
    )

    foreach ($line in $result.Output) {
        Write-Host $line
    }
}

function Get-StableBranch {

    # 1. Prefer local master/main when present.
    $master = Invoke-Git -ArgumentList @(
        "show-ref",
        "--verify",
        "--quiet",
        "refs/heads/master"
    )

    if ($master.ExitCode -eq 0) {
        return "master"
    }

    $main = Invoke-Git -ArgumentList @(
        "show-ref",
        "--verify",
        "--quiet",
        "refs/heads/main"
    )

    if ($main.ExitCode -eq 0) {
        return "main"
    }

    # 2. Ask the remote what its default branch is.
    $originHead = Invoke-Git -ArgumentList @(
        "symbolic-ref",
        "--short",
        "refs/remotes/origin/HEAD"
    )

    if ($originHead.ExitCode -eq 0) {
        $line = ($originHead.Output | Select-Object -First 1).ToString().Trim()

        if ($line -match '^origin/(.+)$') {
            return $Matches[1]
        }
    }

    # 3. Final fallback for a repo without origin/HEAD.
    $remoteMaster = Invoke-Git -ArgumentList @(
        "show-ref",
        "--verify",
        "--quiet",
        "refs/remotes/origin/master"
    )

    if ($remoteMaster.ExitCode -eq 0) {
        return "master"
    }

    $remoteMain = Invoke-Git -ArgumentList @(
        "show-ref",
        "--verify",
        "--quiet",
        "refs/remotes/origin/main"
    )

    if ($remoteMain.ExitCode -eq 0) {
        return "main"
    }

    throw "Could not detect a stable branch from local branches or origin/HEAD."
}

function Try-GetRemoteCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    $result = Invoke-Git -ArgumentList @(
        "rev-parse",
        "origin/$Branch"
    )

    if ($result.ExitCode -ne 0) {
        return $null
    }

    $commit = ($result.Output | Select-Object -First 1).ToString().Trim()

    if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
        return $null
    }

    return $commit
}

function Get-LatestCommitMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    $result = Invoke-Git -ArgumentList @(
        "log",
        "HEAD..origin/$Branch",
        "--oneline",
        "-1"
    )

    if ($result.ExitCode -ne 0) {
        return $null
    }

    return (($result.Output | Select-Object -First 1).ToString().Trim())
}

function Create-BackupBranch {

    $timestamp = Get-Date -Format "yyyy_MM_dd_HHmmss"
    $suffix = Get-Random -Minimum 1000 -Maximum 9999
    $backupBranch = "backup/pre_update_${timestamp}_$suffix"

    Write-Host "Creating rollback branch: $backupBranch" -ForegroundColor Yellow

    Invoke-Git -ArgumentList @(
        "branch",
        $backupBranch
    ) -ThrowOnError | Out-Null

    $verify = Invoke-Git -ArgumentList @(
        "show-ref",
        "--verify",
        "--quiet",
        "refs/heads/$backupBranch"
    )

    if ($verify.ExitCode -ne 0) {
        throw "Rollback branch creation could not be verified: $backupBranch"
    }

    return $backupBranch
}

# ----------------------------------------------------------------------------
# GIT HISTORY
# ----------------------------------------------------------------------------

function Get-CommitHistoryBetween {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FromCommit,

        [Parameter(Mandatory = $true)]
        [string]$ToCommit
    )

    if ([string]::IsNullOrWhiteSpace($FromCommit) -or
        [string]::IsNullOrWhiteSpace($ToCommit)) {
        return @()
    }

    if ($FromCommit -eq $ToCommit) {
        return @()
    }

    # ASCII Unit Separator is extremely unlikely in normal Git metadata and
    # avoids the common tab-delimiter problem with commit subjects.
    $separator = [char]31
    $format = "%H%x1f%h%x1f%aI%x1f%an%x1f%s"

    $result = Invoke-Git -ArgumentList @(
        "log",
        "$FromCommit..$ToCommit",
        "--format=$format"
    )

    if ($result.ExitCode -ne 0) {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[object]

    foreach ($lineObject in $result.Output) {

        if ($null -eq $lineObject) {
            continue
        }

        $line = $lineObject.ToString()

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = $line -split [regex]::Escape([string]$separator), 5

        if ($parts.Count -lt 5) {
            continue
        }

        $items.Add(
            [PSCustomObject]@{
                Commit      = $parts[0]
                ShortCommit = $parts[1]
                Date        = $parts[2]
                Author      = $parts[3]
                Subject     = $parts[4]
            }
        )
    }

    return @($items)
}

# ----------------------------------------------------------------------------
# PERSISTENT STATE
# ----------------------------------------------------------------------------

function New-DefaultState {

    return [PSCustomObject]@{
        SchemaVersion     = 4
        LastSuccessfulRun = $null
        History           = @()
        PRCache           = [PSCustomObject]@{}
    }
}

function Convert-StateToCompatibleObject {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    if ($null -eq $State.PSObject.Properties["History"]) {
        $State | Add-Member -MemberType NoteProperty -Name History -Value @()
    }

    if ($null -eq $State.PSObject.Properties["PRCache"]) {
        $State | Add-Member -MemberType NoteProperty -Name PRCache -Value ([PSCustomObject]@{})
    }

    $State.SchemaVersion = 4

    return $State
}

function Read-StateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $raw = [System.IO.File]::ReadAllText($Path)

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "State file is empty."
    }

    return ($raw | ConvertFrom-Json)
}

function Load-UpdaterState {

    if (Test-Path -LiteralPath $StateFile) {
        try {
            return (Convert-StateToCompatibleObject (Read-StateFile -Path $StateFile))
        }
        catch {
            Write-WarningText "WARNING: Main updater state file is unreadable."
        }
    }

    # Recovery path: previous valid state backup.
    if (Test-Path -LiteralPath $StateBackup) {
        try {
            Write-WarningText "Attempting recovery from state backup: $StateBackup"
            return (Convert-StateToCompatibleObject (Read-StateFile -Path $StateBackup))
        }
        catch {
            Write-WarningText "State backup is also unreadable. A new state file will be created."
        }
    }

    return New-DefaultState
}

function Save-UpdaterState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    if (-not (Test-Path -LiteralPath $UpdateDir)) {
        New-Item -ItemType Directory -Path $UpdateDir -Force | Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 20
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # Write complete new state to temp file first.
    [System.IO.File]::WriteAllText(
        $StateTemp,
        $json,
        $utf8NoBom
    )

    try {
        if (Test-Path -LiteralPath $StateFile) {

            # File.Replace gives us a backup of the previous known-good state.
            try {
                [System.IO.File]::Replace(
                    $StateTemp,
                    $StateFile,
                    $StateBackup,
                    $true
                )

                return
            }
            catch {
                # Fallback for filesystems/environments where Replace is not supported.
                Write-WarningText "State atomic replace unavailable; using safe fallback."
            }

            if (Test-Path -LiteralPath $StateBackup) {
                Remove-Item -LiteralPath $StateBackup -Force -ErrorAction Stop
            }

            Copy-Item -LiteralPath $StateFile -Destination $StateBackup -Force -ErrorAction Stop
            Move-Item -LiteralPath $StateTemp -Destination $StateFile -Force -ErrorAction Stop
            return
        }

        Move-Item -LiteralPath $StateTemp -Destination $StateFile -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $StateTemp) {
            Remove-Item -LiteralPath $StateTemp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-HistoryEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [object]$Entry
    )

    $history = @()

    if ($null -ne $State.History) {
        $history = @($State.History)
    }

    $history += $Entry

    if ($history.Count -gt $MaxHistoryEntries) {
        $start = $history.Count - $MaxHistoryEntries
        $history = @($history[$start..($history.Count - 1)])
    }

    $State.History = $history
}

# ----------------------------------------------------------------------------
# GITHUB API / PR METADATA
# ----------------------------------------------------------------------------

function Get-CachedPRInfo {
    param(
        [object]$State,
        [string]$Commit
    )

    if ($null -eq $State.PRCache) {
        return $null
    }

    $property = $State.PRCache.PSObject.Properties[$Commit]

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
        $State | Add-Member -MemberType NoteProperty -Name PRCache -Value ([PSCustomObject]@{})
    }

    $State.PRCache | Add-Member `
        -MemberType NoteProperty `
        -Name $Commit `
        -Value $Value `
        -Force
}

function Get-GitHubApiHeaders {

    $headers = New-Object 'System.Collections.Generic.Dictionary[string,string]'

    $headers.Add("Accept", "application/vnd.github+json")
    $headers.Add("X-GitHub-Api-Version", $GitHubApiVersion)
    $headers.Add("User-Agent", "ComfyUI-Safe-Update-Manager/10")

    if (-not [string]::IsNullOrWhiteSpace($env:COMFYUI_GITHUB_TOKEN)) {
        $headers.Add("Authorization", "Bearer $($env:COMFYUI_GITHUB_TOKEN)")
    }

    return $headers
}

function Get-HttpStatusCode {
    param(
        [object]$Exception
    )

    try {
        if ($null -ne $Exception.Response) {
            if ($Exception.Response.StatusCode) {
                return [int]$Exception.Response.StatusCode
            }
        }
    }
    catch {}

    return $null
}

function Get-GitHubPRInfo {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [string]$Commit
    )

    $cached = Get-CachedPRInfo -State $State -Commit $Commit

    if ($null -ne $cached) {
        # v4+ cache objects have Status. Older versions stored PR arrays directly.
        if ($cached.PSObject.Properties["Status"]) {
            if ($cached.Status -eq "success") {
                return [PSCustomObject]@{
                    Status = "success"
                    PRs    = @($cached.PRs)
                }
            }

            if ($cached.Status -eq "not_found") {
                return [PSCustomObject]@{
                    Status = "not_found"
                    PRs    = @()
                }
            }

            # temporary_failure / rate_limited are deliberately NOT reused forever.
        }
        else {
            # Backward compatibility with v3/v8/v9 cache entries.
            return [PSCustomObject]@{
                Status = "success"
                PRs    = @($cached)
            }
        }
    }

    $uri = "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/commits/$Commit/pulls"
    $headers = Get-GitHubApiHeaders

    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxApiRetries; $attempt++) {

        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(15)

        try {
            foreach ($key in $headers.Keys) {
                $client.DefaultRequestHeaders.TryAddWithoutValidation(
                    $key,
                    $headers[$key]
                ) | Out-Null
            }

            $response = $client.GetAsync($uri).GetAwaiter().GetResult()
            $statusCode = [int]$response.StatusCode
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

            # Useful rate information.
            $remaining = $null
            $resetUnix = $null

            if ($response.Headers.Contains("X-RateLimit-Remaining")) {
                $value = $response.Headers.GetValues("X-RateLimit-Remaining") | Select-Object -First 1
                $remaining = [int]$value
            }

            if ($response.Headers.Contains("X-RateLimit-Reset")) {
                $value = $response.Headers.GetValues("X-RateLimit-Reset") | Select-Object -First 1
                $resetUnix = [long]$value
            }

            if ($null -ne $remaining -and $remaining -lt 10) {
                Write-WarningText "GitHub API remaining requests: $remaining"
            }

            if ($statusCode -eq 200) {
                $json = $body | ConvertFrom-Json
                $items = New-Object System.Collections.Generic.List[object]

                foreach ($pr in @($json)) {
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

                $result = @($items)

                Set-CachedPRInfo -State $State -Commit $Commit -Value ([PSCustomObject]@{
                    Status    = "success"
                    Timestamp = (Get-Date).ToString("o")
                    PRs       = $result
                })

                return [PSCustomObject]@{
                    Status = "success"
                    PRs    = $result
                }
            }

            if ($statusCode -eq 404) {
                Set-CachedPRInfo -State $State -Commit $Commit -Value ([PSCustomObject]@{
                    Status    = "not_found"
                    Timestamp = (Get-Date).ToString("o")
                    PRs       = @()
                })

                return [PSCustomObject]@{
                    Status = "not_found"
                    PRs    = @()
                }
            }

            # Rate limit: do NOT cache as "no PR".
            if ($statusCode -eq 403 -or $statusCode -eq 429) {
                $lastError = "GitHub API rate limit/status $statusCode"

                if ($statusCode -eq 429 -and $response.Headers.Contains("Retry-After")) {
                    $retryAfter = [int]($response.Headers.GetValues("Retry-After") | Select-Object -First 1)
                    Write-WarningText "GitHub requested retry after $retryAfter seconds."
                    if ($retryAfter -le 30) {
                        Start-Sleep -Seconds $retryAfter
                    }
                }

                break
            }

            # Retry transient server errors.
            if ($statusCode -eq 500 -or
                $statusCode -eq 502 -or
                $statusCode -eq 503 -or
                $statusCode -eq 504) {

                $lastError = "GitHub API returned HTTP $statusCode"

                if ($attempt -lt $MaxApiRetries) {
                    $wait = $attempt * 2
                    Write-WarningText "PR lookup retry $attempt/$MaxApiRetries in ${wait}s: $lastError"
                    Start-Sleep -Seconds $wait
                    continue
                }

                break
            }

            $lastError = "GitHub API returned HTTP $statusCode"
            break
        }
        catch {
            $lastError = $_.Exception.Message

            if ($attempt -lt $MaxApiRetries) {
                $wait = $attempt * 2
                Write-WarningText "PR lookup retry $attempt/$MaxApiRetries in ${wait}s: $lastError"
                Start-Sleep -Seconds $wait
                continue
            }
        }
        finally {
            $client.Dispose()
        }
    }

    Write-WarningText (
        "PR lookup unavailable for {0}: {1}" -f
        (Get-ShortCommit $Commit),
        $lastError
    )

    # IMPORTANT: temporary failures are not cached as "no PR".
    return [PSCustomObject]@{
        Status = "temporary_failure"
        PRs    = @()
    }
}

function Resolve-CommitPRs {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [object[]]$Commits
    )

    $hasToken = -not [string]::IsNullOrWhiteSpace($env:COMFYUI_GITHUB_TOKEN)
    $limit = if ($hasToken) { $Commits.Count } else { [math]::Min($Commits.Count, $UnauthenticatedPRLookupLimit) }

    if (-not $hasToken -and $Commits.Count -gt $limit) {
        Write-WarningText (
            "There are {0} commits to resolve but the unauthenticated PR lookup cap is {1}. " +
            "Remaining commits will be resolved on a later run or when COMFYUI_GITHUB_TOKEN is set." -f
            $Commits.Count,
            $limit
        )
    }

    for ($index = 0; $index -lt $Commits.Count; $index++) {

        $commit = $Commits[$index]

        if ($index -ge $limit) {
            $commit | Add-Member -MemberType NoteProperty -Name PRStatus -Value "deferred" -Force
            $commit | Add-Member -MemberType NoteProperty -Name PRs -Value @() -Force
            continue
        }

        $lookup = Get-GitHubPRInfo -State $State -Commit $commit.Commit

        $commit | Add-Member -MemberType NoteProperty -Name PRStatus -Value $lookup.Status -Force
        $commit | Add-Member -MemberType NoteProperty -Name PRs -Value @($lookup.PRs) -Force
    }

    return @($Commits)
}

# ----------------------------------------------------------------------------
# HISTORY DISPLAY
# ----------------------------------------------------------------------------

function Resolve-AndDisplayChanges {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [object[]]$Commits
    )

    if ($Commits.Count -eq 0) {
        return @()
    }

    Write-Host ""
    Write-Host "Resolving GitHub pull requests..." -ForegroundColor Cyan
    Write-Host ""

    $resolved = @(Resolve-CommitPRs -State $State -Commits $Commits)

    # Save cache regardless of whether some lookups were temporarily unavailable.
    Save-UpdaterState -State $State

    foreach ($commit in $resolved) {

        $dateText = [string]$commit.Date

        if ($dateText.Length -gt 19) {
            $dateText = $dateText.Substring(0, 19)
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
        elseif ($commit.PRStatus -eq "deferred") {
            Write-Host "       PR: lookup deferred" -ForegroundColor DarkYellow
        }
        elseif ($commit.PRStatus -eq "temporary_failure") {
            Write-Host "       PR: GitHub lookup temporarily unavailable" -ForegroundColor DarkYellow
        }
        elseif ($commit.PRStatus -eq "not_found") {
            Write-Host "       PR: no associated PR reported by GitHub" -ForegroundColor DarkGray
        }
        else {
            Write-Host "       PR: no PR metadata" -ForegroundColor DarkGray
        }

        Write-Host (
            "       Author: {0}" -f
            $commit.Author
        ) -ForegroundColor DarkGray

        Write-Host ""
    }

    return $resolved
}

function Show-UpdatesSinceLastRun {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [string]$CurrentBranch,

        [Parameter(Mandatory = $true)]
        [string]$RemoteCommit
    )

    if ($null -eq $State.LastSuccessfulRun) {

        Write-Section "Update History"
        Write-Host "No previous successful updater run is recorded."
        Write-Host "This run will establish the initial history baseline."
        return @()
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
        return @()
    }

    $commits = @(Get-CommitHistoryBetween `
        -FromCommit $previousCommit `
        -ToCommit $RemoteCommit)

    if ($commits.Count -eq 0) {

        if ($previousCommit -eq $RemoteCommit) {
            Write-Host "No new ComfyUI commits since the previous run." -ForegroundColor Green
        }
        else {
            Write-Host "No directly comparable commit history was found." -ForegroundColor Yellow
            Write-Host "This may indicate a branch rewrite or force-push."
        }

        return @()
    }

    Write-Host (
        "ComfyUI updates found: {0}" -f
        $commits.Count
    ) -ForegroundColor Green

    return @(Resolve-AndDisplayChanges -State $State -Commits $commits)
}

# ----------------------------------------------------------------------------
# GIT VERSION
# ----------------------------------------------------------------------------

function Test-GitVersion {

    Write-Section "Git Environment"

    $versionOutput = @(& git --version 2>&1)
    $gitVersion = ($versionOutput | Out-String).Trim()

    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    $gitPath = if ($null -ne $gitCommand) { $gitCommand.Source } else { "NOT FOUND" }

    Write-Host "Git Version : $gitVersion"
    Write-Host "Git Path    : $gitPath"
    Write-Host ""

    if ($gitPath -eq "NOT FOUND") {
        throw "Git was not found in PATH."
    }

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

            $choice = Read-HostChoice "Select option" -NonInteractiveDefault "2"

            switch ($choice) {
                "1" {
                    Start-Process "https://gitforwindows.org"
                    exit
                }
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
        $result = Invoke-Git -ArgumentList @(
            "ls-remote",
            "https://github.com/$GitHubOwner/$GitHubRepo.git",
            "HEAD"
        )

        $sw.Stop()

        if ($result.ExitCode -eq 0) {
            Write-Host (
                "Git transport: OK ({0:N2} sec)" -f
                $sw.Elapsed.TotalSeconds
            ) -ForegroundColor Green

            return $true
        }

        Write-Host (
            "Git transport: FAILED (exit code {0})" -f
            $result.ExitCode
        ) -ForegroundColor Red

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
    param(
        [System.Collections.Generic.List[double]]$Values
    )

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return [PSCustomObject]@{
            Success = $false
            Count   = 0
            Average = 0
            Median  = 0
            Minimum = 0
            Maximum = 0
        }
    }

    $sorted = @($Values | Sort-Object)
    $average = ($Values | Measure-Object -Average).Average
    $minimum = $sorted[0]
    $maximum = $sorted[$sorted.Count - 1]

    if (($sorted.Count % 2) -eq 1) {
        $median = $sorted[[math]::Floor($sorted.Count / 2)]
    }
    else {
        $mid = [int]($sorted.Count / 2)
        $median = ($sorted[$mid - 1] + $sorted[$mid]) / 2
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
        [Parameter(Mandatory = $true)]
        [string]$Ref
    )

    Write-Section "Testing GitHub Bulk Download Speed"

    Write-Host "Testing the actual ComfyUI repository archive."
    Write-Host "Each test measures a complete transfer."
    Write-Host "No curl dependency is used."
    Write-Host ""

    # Testing by exact target commit avoids branch-name escaping issues and
    # makes the network check relevant to the object we are about to update to.
    $baseUrl = "https://codeload.github.com/$GitHubOwner/$GitHubRepo/zip/$Ref"

    $results = New-Object System.Collections.Generic.List[double]

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($SpeedTestTimeoutSeconds)

    try {

        for ($i = 1; $i -le $SpeedTestCount; $i++) {

            Write-Host (
                "  Test {0}/{1}..." -f
                $i,
                $SpeedTestCount
            )

            $request = $null
            $response = $null
            $stream = $null

            try {
                $cacheBust = [guid]::NewGuid().ToString()
                $url = "$baseUrl`?speedtest=$cacheBust"

                $request = New-Object System.Net.Http.HttpRequestMessage(
                    [System.Net.Http.HttpMethod]::Get,
                    $url
                )

                $request.Headers.UserAgent.ParseAdd(
                    "ComfyUI-Safe-Update-Manager/10"
                )

                # Do not let transparent compression alter the byte/s metric.
                $request.Headers.TryAddWithoutValidation(
                    "Accept-Encoding",
                    "identity"
                ) | Out-Null

                $sw = [System.Diagnostics.Stopwatch]::StartNew()

                $response = $client.SendAsync(
                    $request,
                    [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                ).GetAwaiter().GetResult()

                $response.EnsureSuccessStatusCode()

                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $buffer = New-Object byte[] (1024 * 1024)
                [long]$totalBytes = 0

                while ($true) {
                    $read = $stream.Read($buffer, 0, $buffer.Length)

                    if ($read -le 0) {
                        break
                    }

                    $totalBytes += $read
                }

                $sw.Stop()

                if ($totalBytes -le 0 -or $sw.Elapsed.TotalSeconds -le 0) {
                    Write-Host "       Invalid transfer result." -ForegroundColor Yellow
                    continue
                }

                $mbps = ($totalBytes / 1MB) / $sw.Elapsed.TotalSeconds
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

    return (Get-SpeedStatistics -Values $results)
}

function Handle-NetworkValidation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetRef
    )

    $gitOK = Test-GitConnectivity

    Write-Host ""

    $result = Test-GitHubBulkDownload -Ref $TargetRef

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

        $choice = Read-HostChoice "Select option" -NonInteractiveDefault "2"

        if ($choice -ne "1") {
            exit
        }

        return
    }

    Write-Host ("Successful Tests: {0}" -f $result.Count)
    Write-Host ("Average         : {0} MB/s" -f $result.Average)
    Write-Host ("Median          : {0} MB/s" -f $result.Median)
    Write-Host ("Minimum         : {0} MB/s" -f $result.Minimum)
    Write-Host ("Maximum         : {0} MB/s" -f $result.Maximum)
    Write-Host ""

    # Intentionally no min/max variance test.
    # Normal Internet throughput variation is not the same thing as instability.

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

        $choice = Read-HostChoice "Select option" -NonInteractiveDefault "2"

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
        Write-Banner "GITHUB DOWNLOAD OK - GIT TRANSPORT PROBLEM" "Yellow"
        Write-Host ("Bulk download median: {0} MB/s" -f $result.Median)
        Write-Host ""
        Write-Host "HTTP download works, but git ls-remote failed."
        Write-Host "The updater itself uses Git."
        Write-Host ""
        Write-Host "1 - Proceed anyway"
        Write-Host "2 - Exit"
        Write-Host ""

        $choice = Read-HostChoice "Select option" -NonInteractiveDefault "2"

        if ($choice -ne "1") {
            exit
        }
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

    $confirm = Read-HostChoice "Select option" -NonInteractiveDefault "2"

    if ($confirm -ne "1") {
        exit
    }

    Write-Section "Cleaning Working Tree"

    Invoke-Git -ArgumentList @(
        "reset",
        "--hard"
    ) -ThrowOnError | Out-Null

    $cleanArguments = @(
        "clean",
        "-fd"
    )

    foreach ($path in $GitProtectedPaths) {
        $cleanArguments += @(
            "-e",
            $path
        )
    }

    Invoke-Git -ArgumentList $cleanArguments -ThrowOnError | Out-Null
}

# ----------------------------------------------------------------------------
# PROTECTED FOLDERS
# ----------------------------------------------------------------------------

function Test-IsReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $item = Get-Item -LiteralPath $Path -Force

        return (
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        )
    }
    catch {
        return $false
    }
}

function Remove-ItemWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [int]$Attempts = 3,

        [int]$DelayMs = 500
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {

        try {
            if (Test-Path -LiteralPath $Path) {
                Remove-Item `
                    -LiteralPath $Path `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            }

            return
        }
        catch {
            if ($attempt -eq $Attempts) {
                throw
            }

            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Test-NoStaleProtectedBackups {

    $stale = New-Object System.Collections.Generic.List[string]

    foreach ($folder in $FoldersToProtect) {
        $backupPath = Join-Path $ComfyPath "${folder}_backup"

        if (Test-Path -LiteralPath $backupPath) {
            $stale.Add($backupPath)
        }
    }

    if ($stale.Count -eq 0) {
        return
    }

    Write-Banner "PREVIOUS PROTECTED-FOLDER BACKUP DETECTED" "Red"

    Write-Host "The previous updater run left one or more protected-folder backups."
    Write-Host "For safety, the script will NOT overwrite or merge them automatically."
    Write-Host ""

    foreach ($path in $stale) {
        Write-Host " - $path" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Investigate/restore these backups manually before running the updater again."

    throw "Stale protected-folder backups detected. Update aborted."
}

function Backup-ProtectedFolders {

    Write-Section "Protecting Protected Folders"

    $protected = New-Object System.Collections.Generic.List[object]

    foreach ($folder in $FoldersToProtect) {

        $path = Join-Path $ComfyPath $folder

        if (-not (Test-Path -LiteralPath $path)) {
            Write-Host ("Not present: {0}" -f $folder)
            continue
        }

        $backupName = "${folder}_backup"
        $backupPath = Join-Path $ComfyPath $backupName

        if (Test-Path -LiteralPath $backupPath) {
            throw "Backup path already exists: $backupPath"
        }

        $typeText = if (Test-IsReparsePoint -Path $path) {
            "symlink/junction"
        }
        else {
            "folder"
        }

        Write-Host (
            "Protecting {0} ({1}) -> {2}" -f
            $folder,
            $typeText,
            $backupName
        ) -ForegroundColor Yellow

        Rename-Item `
            -LiteralPath $path `
            -NewName $backupName `
            -ErrorAction Stop

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

    Write-Section "Removing Updater-Created Protected Folder Copies"

    foreach ($folder in $FoldersToProtect) {

        $path = Join-Path $ComfyPath $folder

        if (Test-Path -LiteralPath $path) {

            Write-Host (
                "Removing updater-created: {0}" -f
                $folder
            )

            Remove-ItemWithRetry -Path $path
        }
    }
}

function Restore-ProtectedFolders {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ProtectedFolders
    )

    Write-Section "Restoring Protected Folders"

    foreach ($entry in $ProtectedFolders) {

        $backupPath = $entry.BackupPath
        $targetPath = Join-Path $ComfyPath $entry.Folder

        if (-not (Test-Path -LiteralPath $backupPath)) {
            throw "Backup missing for protected folder: $($entry.Folder)"
        }

        if (Test-Path -LiteralPath $targetPath) {

            Write-Host (
                "Removing updater-created {0}" -f
                $entry.Folder
            )

            Remove-ItemWithRetry -Path $targetPath
        }

        Write-Host (
            "Restoring {0} -> {1}" -f
            $entry.BackupName,
            $entry.Folder
        ) -ForegroundColor Green

        Rename-Item `
            -LiteralPath $backupPath `
            -NewName $entry.Folder `
            -ErrorAction Stop

        if (-not (Test-Path -LiteralPath $targetPath)) {
            throw "Restoration verification failed for: $($entry.Folder)"
        }
    }
}

function Show-BackupLocations {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ProtectedFolders
    )

    Write-Host ""
    Write-Host "The original protected folders were left as backups:" -ForegroundColor Yellow
    Write-Host ""

    foreach ($entry in $ProtectedFolders) {
        Write-Host (" - {0}" -f $entry.BackupPath) -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Do NOT delete these backups until the failed update has been investigated."
}

# ----------------------------------------------------------------------------
# UPDATER PROCESS EXECUTION / TIMEOUT
# ----------------------------------------------------------------------------

function Stop-ProcessTree {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    Write-WarningText "Terminating updater process tree (PID $ProcessId)..."

    & taskkill.exe /PID $ProcessId /T /F 2>&1 | ForEach-Object {
        Write-Host $_
    }

    $taskKillExit = $LASTEXITCODE

    if ($taskKillExit -ne 0) {
        Write-WarningText "taskkill returned exit code $taskKillExit."
    }

    return ($taskKillExit -eq 0)
}

function Run-ComfyUpdaterBat {

    $updaterBat = Join-Path $UpdateDir "update_comfyui.bat"

    if (-not (Test-Path -LiteralPath $updaterBat -PathType Leaf)) {
        throw "Updater script not found: $updaterBat"
    }

    Write-Section "Running ComfyUI Update"

    # Use System.Diagnostics.Process directly instead of Start-Process.
    # This avoids Windows PowerShell 5.1 argument-array conversion issues.
    # cmd.exe receives one explicit command-line string:
    #     /d /c "update_comfyui.bat"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.WorkingDirectory = $UpdateDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    $psi.Arguments = '/d /c "update_comfyui.bat"'

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        $started = $process.Start()

        if (-not $started) {
            throw "Could not start update_comfyui.bat."
        }

        $deadline = (Get-Date).AddSeconds($UpdaterTimeoutSeconds)

        while (-not $process.HasExited) {

            Start-Sleep -Seconds 1

            if ($process.HasExited) {
                break
            }

            if ((Get-Date) -lt $deadline) {
                continue
            }

            Write-Banner "UPDATE PROCESS TIMEOUT" "Red"

            $elapsed = $UpdaterTimeoutSeconds

            Write-Host (
                "update_comfyui.bat has been running for at least {0:N0} seconds." -f
                $elapsed
            )

            Write-Host ""
            Write-Host "The updater is still running. This does NOT automatically mean it is broken."
            Write-Host ""
            Write-Host "1 - Give it another $UpdaterTimeoutSeconds seconds"
            Write-Host "2 - Terminate updater process tree"
            Write-Host "3 - Exit updater manager without terminating it"
            Write-Host ""

            $choice = Read-HostChoice `
                "Select option" `
                -NonInteractiveDefault "2"

            if ($choice -eq "1" -and -not $NonInteractive) {
                $deadline = (Get-Date).AddSeconds($UpdaterTimeoutSeconds)
                continue
            }

            if ($choice -eq "3" -and -not $NonInteractive) {

                Write-WarningText `
                    "Leaving updater process running. The manager will not modify protected folders."

                return [PSCustomObject]@{
                    Completed = $false
                    TimedOut  = $true
                    Detached  = $true
                    ExitCode  = $null
                }
            }

            # Default and non-interactive behavior: terminate.
            Stop-ProcessTree -ProcessId $process.Id | Out-Null

            Start-Sleep -Milliseconds 500

            if (-not $process.HasExited) {
                Write-WarningText "Updater process is still present after taskkill."
            }

            return [PSCustomObject]@{
                Completed = $false
                TimedOut  = $true
                Detached  = $false
                ExitCode  = $null
            }
        }

        $exitCode = $process.ExitCode

        return [PSCustomObject]@{
            Completed = $true
            TimedOut  = $false
            Detached  = $false
            ExitCode  = $exitCode
        }
    }
    finally {
        $process.Dispose()
        $psi = $null
    }
}

function Test-UpdateSucceeded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedBranch,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCommit,

        [Parameter(Mandatory = $true)]
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

    $actualBranch = Get-CurrentBranch
    $actualCommit = Get-CurrentCommit

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
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedBranch,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCommit
    )

    $protectedFolders = @()
    $preUpdateCommit = Get-CurrentCommit

    try {

        # Verify BAT exists BEFORE touching protected folders.
        $updaterBat = Join-Path $UpdateDir "update_comfyui.bat"

        if (-not (Test-Path -LiteralPath $updaterBat -PathType Leaf)) {
            throw "Updater script not found: $updaterBat"
        }

        $protectedFolders = @(Backup-ProtectedFolders)

        $runResult = Run-ComfyUpdaterBat

        if ($runResult.Detached) {
            Write-Banner "UPDATE MANAGER EXITED - UPDATER STILL RUNNING" "Yellow"
            Write-Host "The batch process was intentionally left running."
            Write-Host "No protected folders were restored or deleted by this manager."
            Write-Host ""
            Show-BackupLocations -ProtectedFolders $protectedFolders

            return [PSCustomObject]@{
                Success          = $false
                Detached         = $true
                PreUpdateCommit  = $preUpdateCommit
                PostUpdateCommit = Get-CurrentCommit
                Branch           = Get-CurrentBranch
                ProtectedFolders = $protectedFolders
            }
        }

        if (-not $runResult.Completed) {
            Write-Banner "UPDATE FAILED - PROTECTED FOLDERS LEFT SAFE" "Red"
            Write-Host "The updater process did not complete successfully."
            Show-BackupLocations -ProtectedFolders $protectedFolders

            return [PSCustomObject]@{
                Success          = $false
                Detached         = $false
                PreUpdateCommit  = $preUpdateCommit
                PostUpdateCommit = Get-CurrentCommit
                Branch           = Get-CurrentBranch
                ProtectedFolders = $protectedFolders
            }
        }

        Write-Host ""
        Write-Host (
            "update_comfyui.bat exit code: {0}" -f
            $runResult.ExitCode
        )

        # IMPORTANT: verify branch + exact HEAD BEFORE restoration.
        $success = Test-UpdateSucceeded `
            -ExpectedBranch $ExpectedBranch `
            -ExpectedCommit $ExpectedCommit `
            -UpdaterExitCode $runResult.ExitCode

        if (-not $success) {

            Write-Banner "UPDATE FAILED - PROTECTED FOLDERS LEFT SAFE" "Red"

            Write-Host "The resulting Git state could not be verified."
            Write-Host ""
            Write-Host "The original protected folders have NOT been"
            Write-Host "automatically reattached to the changed tree."

            Show-BackupLocations -ProtectedFolders $protectedFolders

            return [PSCustomObject]@{
                Success          = $false
                Detached         = $false
                PreUpdateCommit  = $preUpdateCommit
                PostUpdateCommit = Get-CurrentCommit
                Branch           = Get-CurrentBranch
                ProtectedFolders = $protectedFolders
            }
        }

        # VERIFIED SUCCESS.
        Cleanup-UpdaterFolders
        Restore-ProtectedFolders -ProtectedFolders $protectedFolders

        return [PSCustomObject]@{
            Success          = $true
            Detached         = $false
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

        if ($protectedFolders.Count -gt 0) {
            Show-BackupLocations -ProtectedFolders $protectedFolders
        }

        return [PSCustomObject]@{
            Success          = $false
            Detached         = $false
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
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [string]$Branch,

        [Parameter(Mandatory = $true)]
        [string]$PreUpdateCommit,

        [Parameter(Mandatory = $true)]
        [string]$PostUpdateCommit,

        [Parameter(Mandatory = $true)]
        [bool]$UpdatePerformed
    )

    $changes = @(Get-CommitHistoryBetween `
        -FromCommit $PreUpdateCommit `
        -ToCommit $PostUpdateCommit)

    if ($changes.Count -gt 0) {
        $changes = @(Resolve-CommitPRs -State $State -Commits $changes)
    }

    $entry = [PSCustomObject]@{
        Timestamp       = (Get-Date).ToString("o")
        Branch          = $Branch
        UpdatePerformed = $UpdatePerformed
        Commit          = $PostUpdateCommit
        CommitShort     = Get-ShortCommit $PostUpdateCommit
        PreviousCommit  = $PreUpdateCommit
        PreviousShort   = Get-ShortCommit $PreUpdateCommit
        Changes         = @($changes)
    }

    Add-HistoryEntry -State $State -Entry $entry

    $State.LastSuccessfulRun = $entry

    Save-UpdaterState -State $State
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------

try {

    Clear-Host

    Write-Banner "ComfyUI Safe Update Manager v10.1" "Cyan"

    Test-GitVersion

    if (-not (Test-Path -LiteralPath $ComfyPath -PathType Container)) {
        throw "ComfyUI folder not found: $ComfyPath"
    }

    if (-not (Test-Path -LiteralPath $UpdateDir -PathType Container)) {
        throw "Update folder not found: $UpdateDir"
    }

    Test-NoStaleProtectedBackups

    $state = Load-UpdaterState

    Push-Location $ComfyPath

    try {

        # --------------------------------------------------------------------
        # Fetch remote information.
        # A failed fetch MUST abort before making update decisions.
        # --------------------------------------------------------------------

        Write-Section "Fetching Remote Information"

        $fetch = Invoke-Git -ArgumentList @(
            "fetch",
            "origin"
        ) -ThrowOnError

        $currentBranch = Get-CurrentBranch

        if ([string]::IsNullOrWhiteSpace($currentBranch) -or
            $currentBranch -eq "HEAD") {

            throw "ComfyUI is in a detached HEAD state. Please checkout a branch first."
        }

        $currentCommit = Get-CurrentCommit
        $stableBranch = Get-StableBranch

        $isStable = (
            $currentBranch -eq "master" -or
            $currentBranch -eq "main"
        )

        # ====================================================================
        # STABLE BRANCH
        # ====================================================================

        if ($isStable) {

            $remoteCommit = Try-GetRemoteCommit -Branch $stableBranch

            if (-not $remoteCommit) {
                throw "Could not determine origin/$stableBranch commit."
            }

            Show-UpdatesSinceLastRun `
                -State $state `
                -CurrentBranch $stableBranch `
                -RemoteCommit $remoteCommit | Out-Null

            $latestMsg = Get-LatestCommitMessage -Branch $stableBranch

            Write-Banner "BRANCH: $($stableBranch.ToUpper())" "Green"

            Write-Host (
                "Current Commit : {0}" -f
                (Get-ShortCommit $currentCommit)
            ) -ForegroundColor Green

            Write-Host (
                "Updating To    : {0}" -f
                (Get-ShortCommit $remoteCommit)
            ) -ForegroundColor Green

            if (-not [string]::IsNullOrWhiteSpace($latestMsg)) {
                Write-Host (
                    "Latest Change  : {0}" -f
                    $latestMsg
                ) -ForegroundColor Green
            }

            if ($currentCommit -eq $remoteCommit) {

                Write-Host ""
                Write-Host "ComfyUI is already up to date." -ForegroundColor Green

                Save-SuccessfulRun `
                    -State $state `
                    -Branch $currentBranch `
                    -PreUpdateCommit $currentCommit `
                    -PostUpdateCommit $currentCommit `
                    -UpdatePerformed $false

                Wait-ForExitPrompt
                exit
            }

            Handle-NetworkValidation -TargetRef $remoteCommit

            $updateResult = Run-Update `
                -ExpectedBranch $stableBranch `
                -ExpectedCommit $remoteCommit

            if (-not $updateResult.Success) {

                Write-Host ""
                Write-Host "Updater state was NOT advanced." -ForegroundColor Yellow
                Write-Host "The next run will still use the last successful commit as its history baseline."

                Wait-ForExitPrompt
                exit 1
            }

            Save-SuccessfulRun `
                -State $state `
                -Branch $updateResult.Branch `
                -PreUpdateCommit $updateResult.PreUpdateCommit `
                -PostUpdateCommit $updateResult.PostUpdateCommit `
                -UpdatePerformed $true
        }
        # ====================================================================
        # PR / EXPERIMENTAL BRANCH
        # ====================================================================
        else {

            $remoteCommit = Try-GetRemoteCommit -Branch $currentBranch

            if (-not $remoteCommit) {
                $remoteCommit = "NO REMOTE TRACKING"
            }

            if ($remoteCommit -ne "NO REMOTE TRACKING") {
                Show-UpdatesSinceLastRun `
                    -State $state `
                    -CurrentBranch $currentBranch `
                    -RemoteCommit $remoteCommit | Out-Null
            }

            Write-Banner "WARNING: PR / EXPERIMENTAL BRANCH DETECTED" "Red"

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

            $choice = Read-HostChoice "Select option" -NonInteractiveDefault "4"

            switch ($choice) {

                # ------------------------------------------------------------
                # UPDATE CURRENT PR / BRANCH
                # ------------------------------------------------------------

                "1" {

                    if ($remoteCommit -eq "NO REMOTE TRACKING") {
                        Write-Banner "CANNOT VERIFY PR UPDATE TARGET" "Red"
                        Write-Host "This branch has no origin tracking branch."
                        Wait-ForExitPrompt
                        exit 1
                    }

                    Create-BackupBranch | Out-Null

                    Handle-NetworkValidation -TargetRef $remoteCommit

                    $updateResult = Run-Update `
                        -ExpectedBranch $currentBranch `
                        -ExpectedCommit $remoteCommit

                    if (-not $updateResult.Success) {
                        Write-Host ""
                        Write-Host "Updater state was NOT advanced." -ForegroundColor Yellow
                        Wait-ForExitPrompt
                        exit 1
                    }

                    Save-SuccessfulRun `
                        -State $state `
                        -Branch $updateResult.Branch `
                        -PreUpdateCommit $updateResult.PreUpdateCommit `
                        -PostUpdateCommit $updateResult.PostUpdateCommit `
                        -UpdatePerformed $true
                }

                # ------------------------------------------------------------
                # RETURN TO STABLE
                # ------------------------------------------------------------

                "2" {

                    Create-BackupBranch | Out-Null

                    if ($dirty) {
                        Force-CleanupWorkingTree
                    }

                    Write-Section "Returning To Stable Branch"

                    Invoke-Git -ArgumentList @(
                        "checkout",
                        $stableBranch
                    ) -ThrowOnError | Out-Null

                    Invoke-Git -ArgumentList @(
                        "reset",
                        "--hard",
                        "origin/$stableBranch"
                    ) -ThrowOnError | Out-Null

                    $stableRemoteCommit = Try-GetRemoteCommit -Branch $stableBranch

                    if (-not $stableRemoteCommit) {
                        throw "Could not determine stable remote commit."
                    }

                    Handle-NetworkValidation -TargetRef $stableRemoteCommit

                    $updateResult = Run-Update `
                        -ExpectedBranch $stableBranch `
                        -ExpectedCommit $stableRemoteCommit

                    if (-not $updateResult.Success) {
                        Write-Host ""
                        Write-Host "Updater state was NOT advanced." -ForegroundColor Yellow
                        Wait-ForExitPrompt
                        exit 1
                    }

                    Save-SuccessfulRun `
                        -State $state `
                        -Branch $updateResult.Branch `
                        -PreUpdateCommit $updateResult.PreUpdateCommit `
                        -PostUpdateCommit $updateResult.PostUpdateCommit `
                        -UpdatePerformed $true
                }

                # ------------------------------------------------------------
                # SHOW MODIFIED FILES
                # ------------------------------------------------------------

                "3" {
                    Show-ModifiedFiles
                    Wait-ForExitPrompt
                    exit
                }

                default {
                    exit
                }
            }
        }

        # ====================================================================
        # SUCCESS
        # ====================================================================

        Write-Banner "UPDATE COMPLETED SUCCESSFULLY" "Green"

        Write-Host (
            "Final Commit: {0}" -f
            (Get-ShortCommit (Get-CurrentCommit))
        ) -ForegroundColor Green

        Write-Host ""
        Write-Host "Protected folders/symlinks were restored automatically." -ForegroundColor Green
        Write-Host ""
        Write-Host "Update history saved to:"
        Write-Host $StateFile -ForegroundColor Cyan
    }
    finally {
        Pop-Location
    }
}
catch {
    Write-Banner "UPDATER ERROR" "Red"
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Wait-ForExitPrompt
    exit 1
}
finally {
    if ($null -ne $TranscriptPath) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {}

        Write-Host ""
        Write-Host "Transcript written to: $TranscriptPath" -ForegroundColor Cyan
    }
}

Wait-ForExitPrompt
