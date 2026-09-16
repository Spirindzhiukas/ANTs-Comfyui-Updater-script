# ============================================================================
# ComfyUI Protected Paths Diagnostics
# ============================================================================
# One-shot, READ-ONLY diagnostic for the "symlinked models/output/input"
# problem in ComfyUI portable installations.
#
# WHAT IT DOES
# ------------
# It answers, with machine-verifiable Git evidence, the question that decides
# the v11 design of the Safe Update Manager:
#
#     Are models / output / input TRACKED by the ComfyUI Git repository?
#
# - A. TRACKED by Git          -> checkout / checkout_tree MUST reconcile the
#                                 path with the Git tree. A symlink/junction
#                                 there gets replaced by a real directory.
#                                 Hands-off is NOT safe; keep the protection.
# - B. Untracked + Git-ignored -> git/pygit2 checkout never touches it.
#                                 Hands-off is SAFE (only `git clean` could
#                                 delete it; update.py never runs clean).
# - C. Untracked + not ignored -> checkout leaves it alone, but it pollutes
#                                 git status and will conflict the day a
#                                 commit tracks that path.
# - D. Missing                 -> nothing to protect right now.
#
# It also captures everything the v11 design otherwise needs:
# - filesystem type of each path (directory / symbolic link / junction)
#   and the link target
# - Git state (branch, HEAD, remote, ahead/behind, dirty status, stashes,
#   backup branches, core.symlinks, sparse-checkout)
# - the complete updater chain: update\update_comfyui.bat, update\update.py,
#   and the copies shipped inside the repository (.ci\update_windows\...)
# - behavior flags of the stock updater (pause trap, master-only logic,
#   stash-on-update, checkout_tree, self-update, self-update-pending)
# - the exact raw output of the base diagnostic commands
#
# OUTPUT
# ------
# A Markdown report is written NEXT TO THIS SCRIPT:
#     ComfyUI_ProtectedPaths_Diagnostics_<date_time>.md
# Send that file back - it is the whole input for the next version.
#
# USAGE
# -----
#     powershell -NoProfile -ExecutionPolicy Bypass -File .\ComfyUI_ProtectedPaths_Diagnostics.ps1
#
# Optional:
#     -ComfyPath "C:\path\to\ComfyUI"   explicit repo path
#     -UpdateDir "C:\path\to\update"    explicit update folder
#     -OutFile "C:\path\report.md"      explicit report path
#     -Fetch                            run `git fetch origin --prune` first
#                                       (default: NO network access at all)
#
# SAFETY
# ------
# - Read-only. It does not modify the repository, the working tree, the
#   protected folders, the updater scripts, or the state file.
# - No network access unless you explicitly pass -Fetch.
# - Target environment: Windows PowerShell 5.1+ / PowerShell 7+
# ============================================================================

[CmdletBinding()]
param(
    [string]$ComfyPath,
    [string]$UpdateDir,
    [string]$OutFile,
    [switch]$Fetch
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$protectedFolders = @("models", "output", "input")

# ============================================================================
# REPORT BUILDER (in-memory, flushed once at the end)
# ============================================================================

$md = New-Object System.Collections.Generic.List[string]

function Add-Md {
    param([string]$Line = "")
    $md.Add($Line)
}

function Add-Fenced {
    param(
        [string]$Text,
        [string]$Lang = ""
    )

    Add-Md ('```' + $Lang)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        Add-Md "(no output)"
    }
    else {
        Add-Md $Text
    }
    Add-Md '```'
}

function Cap-Lines {
    param(
        [string]$Text,
        [int]$Max = 200
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "(no output)"
    }

    $lines = $Text -split "`r?`n"
    if ($lines.Count -le $Max) {
        return $Text
    }

    $kept = ($lines[0..($Max - 1)]) -join "`n"
    return ($kept + "`n... (truncated: " + ($lines.Count - $Max) + " more lines)")
}

function Get-FileContentCapped {
    param(
        [string]$Path,
        [int]$MaxLines = 400
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $text = [System.IO.File]::ReadAllText($Path)
    return (Cap-Lines -Text $text -Max $MaxLines)
}

# ============================================================================
# GIT HELPER
# ============================================================================

function Run-Git {
    param(
        [string[]]$Arguments
    )

    $output = ""
    $commandFailed = $false

    try {
        $output = (& git @Arguments 2>&1 | Out-String)
    }
    catch {
        $output = "ERROR: " + $_.Exception.Message
        $commandFailed = $true
    }

    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    if ($commandFailed) { $code = -1 }

    return [PSCustomObject]@{
        Output   = $output.Trim()
        ExitCode = [int]$code
    }
}

# ============================================================================
# PATH INSPECTION
# ============================================================================

function Get-PathInfo {
    param(
        [string]$Path
    )

    $info = [PSCustomObject]@{
        Exists        = $false
        Type          = "missing"
        LinkTarget    = ""
        ReparseTag    = ""
        TopLevelCount = $null
    }

    if (-not (Test-Path -LiteralPath $Path -Force)) {
        return $info
    }

    $info.Exists = $true

    try {

        $item  = Get-Item -LiteralPath $Path -Force
        $isDir = $item.PSIsContainer

        $isReparse =
            (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

        if ($isReparse) {

            if ($isDir) { $info.Type = "directory link" }
            else        { $info.Type = "file link" }

            # Link target via .NET (works for symlinks and junctions,
            # .NET 4.6+ / .NET Core - both covered on PS 5.1 / PS 7).
            try {
                $target = [System.IO.File]::GetSymbolicLinkTarget($Path)
                if ($target) {
                    $info.LinkTarget = $target
                }
            }
            catch {
                $info.LinkTarget = "(could not read link target)"
            }

            # Reparse tag via fsutil (Windows only, best effort).
            try {
                $fsOutput = (& fsutil.exe reparsepoint query $Path 2>&1 | Out-String)
                $tagMatch = [regex]::Match(
                    $fsOutput,
                    "Tag:\s*(0x[0-9A-Fa-f]+)\s*\(([^)]*)\)"
                )

                if ($tagMatch.Success) {
                    $info.ReparseTag =
                        $tagMatch.Groups[1].Value +
                        " (" + $tagMatch.Groups[2].Value + ")"
                }
                else {
                    $firstLine =
                        ($fsOutput.Trim() -split "`r?`n" |
                            Select-Object -First 1)
                    $info.ReparseTag = $firstLine
                }
            }
            catch {
                $info.ReparseTag = "(fsutil not available)"
            }

            # Refine the type using the reparse tag when we got one.
            if (
                $info.ReparseTag -like "*Mount Point*" -or
                $info.ReparseTag -like "*0xA0000004*"
            ) {
                $info.Type = "junction (mount point)"
            }
            elseif (
                $info.ReparseTag -like "*Symbolic Link*" -or
                $info.ReparseTag -like "*0xA0000003*"
            ) {
                $info.Type = "symbolic link"
            }
        }
        elseif ($isDir) {
            $info.Type = "directory"
        }
        else {
            $info.Type = "file"
        }
    }
    catch {
        $info.Type = "unreadable: " + $_.Exception.Message
    }

    # Count top-level entries (follows the link, non-recursive, capped).
    if ($info.Type -like "directory*" -or $info.Type -eq "junction (mount point)") {
        try {
            $info.TopLevelCount =
                @(
                    Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop |
                        Select-Object -First 5000
                ).Count
        }
        catch {
            $info.TopLevelCount = $null
        }
    }

    return $info
}

# ============================================================================
# VERDICT LOGIC
# ============================================================================

function Get-PathVerdict {
    param(
        [bool]$Exists,
        [bool]$TrackedAtHead,
        [bool]$TrackedAtRemote,
        [bool]$IsIgnored
    )

    if (-not $Exists) {
        return [PSCustomObject]@{
            Code             = "D"
            Label            = "MISSING"
            SafeHandsOff     = $false
            Recommendation   = "Nothing exists to protect at this moment. The next run will classify the path again."
        }
    }

    if ($TrackedAtHead -or $TrackedAtRemote) {
        return [PSCustomObject]@{
            Code             = "A"
            Label            = "TRACKED BY GIT"
            SafeHandsOff     = $false
            Recommendation   = "Hands-off is NOT safe. The Git tree contains this path, so any checkout / checkout_tree must reconcile the filesystem with the tree. A symlink/junction sitting here is replaced by a real directory - that is the operation that destroys the links. Keep the proven rename-away / restore protection, or design a v11 strategy that explicitly excludes these paths from checkout."
        }
    }

    if ($IsIgnored) {
        return [PSCustomObject]@{
            Code             = "B"
            Label            = "UNTRACKED + IGNORED"
            SafeHandsOff     = $true
            Recommendation   = 'Hands-off is SAFE for checkout operations: git and pygit2 never touch ignored, untracked paths during a checkout. Only `git clean` could delete it, and the ComfyUI updater (update.py) never runs clean.'
        }
    }

    return [PSCustomObject]@{
        Code             = "C"
        Label            = "UNTRACKED + NOT IGNORED"
        SafeHandsOff     = $true
        Recommendation   = 'Checkout will leave it alone, but it pollutes `git status`, and the day a ComfyUI commit tracks this path it will conflict with the link. Recommended fix: add the path to `.git/info/exclude` (keeps the shared .gitignore clean) so the path becomes case B.'
    }
}

# ============================================================================
# PATH RESOLUTION
# ============================================================================

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($ComfyPath)) {

    $candidates = @(
        (Join-Path $scriptRoot "ComfyUI")
    )

    # If this script was dropped directly inside the ComfyUI repo, use that.
    $isRepoHere = Run-Git -Arguments @("rev-parse", "--is-inside-work-tree")
    if ($isRepoHere.ExitCode -eq 0 -and $isRepoHere.Output -eq "true") {
        $candidates += $scriptRoot
    }

    foreach ($candidate in $candidates) {
        if (
            (Test-Path -LiteralPath $candidate -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $candidate ".git") -Force)
        ) {
            $ComfyPath = $candidate
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($ComfyPath)) {
        Write-Host "ERROR: Could not locate the ComfyUI repository." -ForegroundColor Red
        Write-Host "Expected: " + (Join-Path $scriptRoot "ComfyUI") -ForegroundColor Red
        Write-Host "Use -ComfyPath to specify it explicitly." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " ComfyUI Protected Paths Diagnostics" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("Repository : " + $ComfyPath) -ForegroundColor White
Write-Host ("Script root: " + $scriptRoot) -ForegroundColor White

# ----------------------------------------------------------------------------
# UPDATE DIR
# ----------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($UpdateDir)) {

    $updateCandidates = @(
        (Join-Path $scriptRoot "update")
        (Join-Path $ComfyPath ".ci\update_windows")
    )

    foreach ($candidate in $updateCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $UpdateDir = $candidate
            break
        }
    }
}

Write-Host ("Update dir : " + $(
    if ([string]::IsNullOrWhiteSpace($UpdateDir)) { "NOT FOUND" } else { $UpdateDir }
)) -ForegroundColor White
Write-Host ""

# ----------------------------------------------------------------------------
# SANITY: is it a Git repo?
# ----------------------------------------------------------------------------

Push-Location $ComfyPath

try {

    $insideWorkTree = Run-Git -Arguments @("rev-parse", "--is-inside-work-tree")

    if ($insideWorkTree.ExitCode -ne 0 -or $insideWorkTree.Output -ne "true") {
        Write-Host ("ERROR: {0} is not a Git work tree." -f $ComfyPath) -ForegroundColor Red
        Write-Host ("Git output: " + $insideWorkTree.Output) -ForegroundColor Red
        exit 1
    }

    # ----------------------------------------------------------------------------
    # OPTIONAL FETCH
    # ----------------------------------------------------------------------------

    $fetched = $false

    if ($Fetch) {
        Write-Host "Running: git fetch origin --prune" -ForegroundColor Yellow
        $fetchResult = Run-Git -Arguments @("fetch", "origin", "--prune")
        if ($fetchResult.ExitCode -eq 0) {
            $fetched = $true
            Write-Host "Fetch OK." -ForegroundColor Green
        }
        else {
            Write-Host ("Fetch FAILED (exit " + $fetchResult.ExitCode + "):") -ForegroundColor Red
            Write-Host $fetchResult.Output -ForegroundColor Red
            Write-Host "Continuing with the last locally-known remote state." -ForegroundColor Yellow
        }
    }

    # ==========================================================================
    # COLLECT: ENVIRONMENT
    # ==========================================================================

    Write-Host "Collecting environment..." -ForegroundColor DarkGray

    $envInfo = [PSCustomObject]@{
        Date         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
        HostName     = $env:COMPUTERNAME
        PSVersion    = $PSVersionTable.PSVersion.ToString()
        PSEdition    = $(if ($PSVersionTable.PSVersion.Major -ge 6) { "Core" } else { "Desktop" })
        OSVersion    = [System.Environment]::OSVersion.Version.ToString()
        GitVersion   = ""
        GitPath      = ""
        CoreSymlinks = "(not detected)"
    }

    $gitVer = Run-Git -Arguments @("--version")
    if ($gitVer.ExitCode -eq 0) {
        $envInfo.GitVersion = $gitVer.Output
    }
    else {
        $envInfo.GitVersion = "NOT AVAILABLE"
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $envInfo.GitPath = $gitCmd.Source
    }

    $coreSymlinks = Run-Git -Arguments @("config", "core.symlinks")
    if ($coreSymlinks.ExitCode -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($coreSymlinks.Output)) {
        $envInfo.CoreSymlinks = $coreSymlinks.Output
    }
    else {
        $envInfo.CoreSymlinks = "(unset - git default)"
    }

    # ==========================================================================
    # COLLECT: GIT REPOSITORY STATE
    # ==========================================================================

    Write-Host "Collecting Git repository state..." -ForegroundColor DarkGray

    $branchResult = Run-Git -Arguments @("rev-parse", "--abbrev-ref", "HEAD")
    $branch =
        if ($branchResult.ExitCode -eq 0) {
            $branchResult.Output
        }
        else {
            "(unknown)"
        }

    $isDetached = ($branch -eq "HEAD")

    $headResult = Run-Git -Arguments @("rev-parse", "HEAD")
    $headCommit =
        if ($headResult.ExitCode -eq 0) {
            $headResult.Output
        }
        else {
            "(unknown)"
        }

    $remoteUrlResult = Run-Git -Arguments @("remote", "get-url", "origin")
    $remoteUrl =
        if ($remoteUrlResult.ExitCode -eq 0) {
            $remoteUrlResult.Output
        }
        else {
            "(no origin remote)"
        }

    $originHeadResult =
        Run-Git -Arguments @("symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    $originHead =
        if ($originHeadResult.ExitCode -eq 0) {
            $originHeadResult.Output
        }
        else {
            "(not set)"
        }

    # Candidate stable refs (master / main / origin-HEAD target).
    $stableRefCandidates = @()
    foreach ($name in @("origin/master", "origin/main")) {
        $verify = Run-Git -Arguments @("rev-parse", "--verify", "--quiet", $name)
        if ($verify.ExitCode -eq 0) {
            $stableRefCandidates += $name
        }
    }
    if (
        $originHead -ne "(not set)" -and
        $originHead -like "origin/*"
    ) {
        $remoteName = $originHead.Substring("origin/".Length)
        $verify = Run-Git -Arguments @("rev-parse", "--verify", "--quiet", "origin/$remoteName")
        if ($verify.ExitCode -eq 0) {
            if ($stableRefCandidates -notcontains "origin/$remoteName") {
                $stableRefCandidates += "origin/$remoteName"
            }
        }
    }

    $aheadBehind = "(no stable remote ref found)"
    if ($stableRefCandidates.Count -gt 0) {
        $countResult = Run-Git -Arguments @(
            "rev-list", "--left-right", "--count",
            ("HEAD..." + $stableRefCandidates[0])
        )
        if ($countResult.ExitCode -eq 0) {
            $parts = $countResult.Output -split "`t"
            $aheadBehind =
                "$($parts[0]) commit(s) ahead / $($parts[1]) commit(s) behind " +
                $stableRefCandidates[0]
        }
    }

    $statusShort = Run-Git -Arguments @(
        "status", "--short", "--untracked-files=all"
    )

    $statusLines = @()
    if (-not [string]::IsNullOrWhiteSpace($statusShort.Output)) {
        $statusLines = @($statusShort.Output -split "`r?`n")
    }

    $dirtyCount = $statusLines.Count
    $deletedCount = 0
    foreach ($sl in $statusLines) {
        if ($sl.StartsWith(" D") -or $sl.StartsWith("D")) {
            $deletedCount++
        }
    }

    $stashList = Run-Git -Arguments @("stash", "list")

    $branchList = Run-Git -Arguments @(
        "for-each-ref", "refs/heads",
        "--format=%(creatordate:short) %(refname:short)"
    )

    $recentLog = Run-Git -Arguments @(
        "log", "--oneline", "-5", "--decorate"
    )

    $localConfig = Run-Git -Arguments @("config", "--list", "--local")

    $sparseEnabled = Run-Git -Arguments @("config", "core.sparseCheckout")
    $sparseList    = Run-Git -Arguments @("sparse-checkout", "list")

    $coreExcludesFile = Run-Git -Arguments @("config", "core.excludesFile")

    # ==========================================================================
    # COLLECT: PROTECTED PATH ANALYSIS
    # ==========================================================================

    Write-Host "Analyzing protected paths..." -ForegroundColor DarkGray

    $pathReports = New-Object System.Collections.Generic.List[object]

    foreach ($folder in $protectedFolders) {

        $fullPath = Join-Path $ComfyPath $folder

        $pinfo = Get-PathInfo -Path $fullPath

        # Tracked at HEAD?
        $lsTreeHead = Run-Git -Arguments @("ls-tree", "-r", "HEAD", "--", $folder)
        $headEntries = @()
        if (
            $lsTreeHead.ExitCode -eq 0 -and
            -not [string]::IsNullOrWhiteSpace($lsTreeHead.Output)
        ) {
            $headEntries = @($lsTreeHead.Output -split "`r?`n")
        }

        # Tracked at any known stable remote ref?
        $remoteEntryCounts = @{}
        foreach ($ref in $stableRefCandidates) {
            $lsTreeRemote = Run-Git -Arguments @("ls-tree", "-r", $ref, "--", $folder)
            $remoteEntries = @()
            if (
                $lsTreeRemote.ExitCode -eq 0 -and
                -not [string]::IsNullOrWhiteSpace($lsTreeRemote.Output)
            ) {
                $remoteEntries = @($lsTreeRemote.Output -split "`r?`n")
            }
            $remoteEntryCounts[$ref] = $remoteEntries.Count
        }

        $trackedAtHead   = ($headEntries.Count -gt 0)
        $trackedAtRemote = ($remoteEntryCounts.Values | Where-Object { $_ -gt 0 }).Count -gt 0

        # Ignored?
        $ignoreResult = Run-Git -Arguments @("check-ignore", "-v", "--", $folder)
        $isIgnored    = ($ignoreResult.ExitCode -eq 0)

        # Index flags (H = normal, S = skip-worktree, h = assume-unchanged).
        $lsFilesFlags = Run-Git -Arguments @("ls-files", "-v", "--", $folder)

        # ls-files --error-unmatch: exit 0 = tracked, 1 = not tracked.
        $lsFilesMatch = Run-Git -Arguments @("ls-files", "--error-unmatch", "--", $folder)

        # Per-path status (for the raw evidence section).
        $pathStatus = Run-Git -Arguments @(
            "status", "--short", "--untracked-files=all", "--", $folder
        )

        $verdict = Get-PathVerdict `
            -Exists            $pinfo.Exists `
            -TrackedAtHead     $trackedAtHead `
            -TrackedAtRemote   $trackedAtRemote `
            -IsIgnored         $isIgnored

        $pathReports.Add(
            [PSCustomObject]@{
                Folder            = $folder
                FullPath          = $fullPath
                Info              = $pinfo
                HeadEntries       = $headEntries
                RemoteEntryCounts = $remoteEntryCounts
                TrackedAtHead     = $trackedAtHead
                TrackedAtRemote   = $trackedAtRemote
                Ignored           = $isIgnored
                IgnoreOutput      = $ignoreResult.Output
                IgnoreExitCode    = $ignoreResult.ExitCode
                FlagsOutput       = $lsFilesFlags.Output
                MatchExitCode     = $lsFilesMatch.ExitCode
                PathStatusOutput  = $pathStatus.Output
                LsTreeHeadOutput  = $lsTreeHead.Output
                LsTreeHeadExit    = $lsTreeHead.ExitCode
                Verdict           = $verdict
            }
        )
    }

    # Base raw commands exactly as requested in the investigation chat
    # (run once for all three paths - this is the verbatim evidence).
    $rawLsTreeModels   = Run-Git -Arguments @("ls-tree", "-r", "HEAD", "--", "models")
    $rawLsTreeOutput   = Run-Git -Arguments @("ls-tree", "-r", "HEAD", "--", "output")
    $rawLsTreeInput    = Run-Git -Arguments @("ls-tree", "-r", "HEAD", "--", "input")
    $rawStatus         = Run-Git -Arguments @(
        "status", "--short", "--untracked-files=all", "--",
        "models", "output", "input"
    )
    $rawCheckIgnore    = Run-Git -Arguments @(
        "check-ignore", "-v", "models", "output", "input"
    )

    # ==========================================================================
    # COLLECT: UPDATER CHAIN
    # ==========================================================================

    Write-Host "Collecting updater chain..." -ForegroundColor DarkGray

    $updaterFiles = New-Object System.Collections.Generic.List[object]

    if (-not [string]::IsNullOrWhiteSpace($UpdateDir)) {

        $localUpdaterFiles = @(
            "update_comfyui.bat",
            "update.py",
            "update_comfyui_stable.bat",
            "update_comfyui_and_python_dependencies.bat",
            "current_requirements.txt"
        )

        foreach ($fileName in $localUpdaterFiles) {
            $fp = Join-Path $UpdateDir $fileName
            $updaterFiles.Add(
                [PSCustomObject]@{
                    Location = "local update folder"
                    Name     = $fileName
                    Path     = $fp
                    Content  = $(Get-FileContentCapped -Path $fp)
                }
            )
        }
    }

    # Copies shipped inside the repository (.ci\update_windows\...).
    $ciDir = Join-Path $ComfyPath ".ci\update_windows"
    if (Test-Path -LiteralPath $ciDir -PathType Container) {
        try {
            $ciItems = Get-ChildItem -LiteralPath $ciDir -File -Force -ErrorAction Stop
        }
        catch {
            $ciItems = @()
        }
        foreach ($ciItem in $ciItems) {
            if (
                $ciItem.Extension -in @(".bat", ".py", ".txt")
            ) {
                $updaterFiles.Add(
                    [PSCustomObject]@{
                        Location = "repo: .ci\update_windows"
                        Name     = $ciItem.Name
                        Path     = $ciItem.FullName
                        Content  = $(Get-FileContentCapped -Path $ciItem.FullName)
                    }
                )
            }
        }
    }

    # Self-update pending?
    # The stock updater copies .ci\update_windows\update.py over itself when
    # the two differ, then re-runs. Detect that state up front.
    $localUpdatePy   = $null
    $repoUpdatePy    = $null
    if (-not [string]::IsNullOrWhiteSpace($UpdateDir)) {
        $localUpdatePy = Join-Path $UpdateDir "update.py"
    }
    $repoUpdatePy = Join-Path $ciDir "update.py"

    $selfUpdatePending = "(could not compare)"
    if (
        (Test-Path -LiteralPath $localUpdatePy -PathType Leaf) -and
        (Test-Path -LiteralPath $repoUpdatePy -PathType Leaf)
    ) {
        $localHash = (Get-FileHash -LiteralPath $localUpdatePy).Hash
        $repoHash  = (Get-FileHash -LiteralPath $repoUpdatePy).Hash
        if ($localHash -eq $repoHash) {
            $selfUpdatePending = "NO - local update.py is identical to the repo copy"
        }
        else {
            $selfUpdatePending = "YES - the next update will first swap in the repo's update.py and re-run"
        }
    }

    # Behavior flags, scanned from the ACTUAL local updater files.
    $flagBat = $null
    $flagPy  = $null
    if (-not [string]::IsNullOrWhiteSpace($UpdateDir)) {
        $flagBat = Get-FileContentCapped -Path (Join-Path $UpdateDir "update_comfyui.bat")
        $flagPy  = Get-FileContentCapped -Path (Join-Path $UpdateDir "update.py")
    }

    $flags = New-Object System.Collections.Generic.List[object]

    function Test-TextPattern {
        param(
            [string]$Text,
            [string]$Pattern
        )
        if ($null -eq $Text) { return $false }
        return ($Text -match $Pattern)
    }

    $flags.Add(
        [PSCustomObject]@{
            Flag      = "PAUSE-TRAP"
            Detected  = $(Test-TextPattern $flagBat "if\s+`"%~1`"\s*==\s*`"`"\s+pause")
            Where     = "update_comfyui.bat"
            Meaning   = 'The BAT ends with `if "%~1"=="" pause`. Invoked WITHOUT any argument it waits for a key press - an external caller (e.g. the Safe Update Manager) will appear to hang until its timeout. Fix: always invoke it with a dummy argument, e.g. `update_comfyui.bat -np`.'
        }
    )

    $flags.Add(
        [PSCustomObject]@{
            Flag      = "MASTER-ONLY"
            Detected  = $(Test-TextPattern $flagPy "lookup_branch\('master'\)")
            Where     = "update.py"
            Meaning   = "The stock updater always checks out and updates 'master', regardless of the branch you are on. Running it from a PR/experimental branch silently abandons that branch. The manager's branch guard (only invoke the stock updater from the stable branch) stays mandatory."
        }
    )

    $flags.Add(
        [PSCustomObject]@{
            Flag      = "STASH-ON-UPDATE"
            Detected  = $(Test-TextPattern $flagPy "repo\.stash\(")
            Where     = "update.py"
            Meaning   = "Tracked working-tree changes are stashed before the update. On a symlinked setup this includes the 'deleted' placeholder files visible through the junctions. Stash entries are NOT popped afterwards - they accumulate (see stash list above)."
        }
    )

    $flags.Add(
        [PSCustomObject]@{
            Flag      = "CHECKOUT-TREE"
            Detected  = $(Test-TextPattern $flagPy "checkout_tree\(")
            Where     = "update.py"
            Meaning   = "pygit2 checkout_tree performs full working-tree reconciliation against the target Git tree. For every path that the Git tree tracks (models/input/output in the real ComfyUI repo) an existing symlink/junction is replaced by a real directory. This is the destructive operation the manager protects against."
        }
    )

    $flags.Add(
        [PSCustomObject]@{
            Flag      = "SELF-UPDATE"
            Detected  = $(Test-TextPattern $flagPy "update_new\.py")
            Where     = "update.py"
            Meaning   = "When the repo ships a newer update.py, the updater copies it to update_new.py and exits; the BAT then swaps it in and re-runs with --skip_self_update. A single BAT run can therefore consist of two updater phases - verification must be done on the FINAL Git state, not on the first exit."
        }
    )

    # Embedded Python + pygit2 probe (offline, best effort).
    $pythonExe = Join-Path $scriptRoot "python_embeded\python.exe"
    $pythonVersion = "(not found)"
    $pygit2Version = "(not found)"
    if (Test-Path -LiteralPath $pythonExe -PathType Leaf) {
        try {
            $pyVer =
                (& $pythonExe -c "import sys; print(sys.version.split()[0])" 2>&1 |
                    Out-String).Trim()
            if ($LASTEXITCODE -eq 0) {
                $pythonVersion = $pyVer
            }
            else {
                $pythonVersion = "failed: $pyVer"
            }
        }
        catch {
            $pythonVersion = "error: " + $_.Exception.Message
        }

        try {
            $pygit2Ver =
                (& $pythonExe -c "import pygit2; print(getattr(pygit2, 'version', getattr(pygit2, '__version__', 'unknown')))" 2>&1 |
                    Out-String).Trim()
            if ($LASTEXITCODE -eq 0) {
                $pygit2Version = $pygit2Ver
            }
            else {
                $pygit2Version = "NOT IMPORTABLE: $pygit2Ver"
            }
        }
        catch {
            $pygit2Version = "error: " + $_.Exception.Message
        }
    }

    # ==========================================================================
    # COLLECT: IGNORE CONFIGURATION
    # ==========================================================================

    Write-Host "Collecting ignore configuration..." -ForegroundColor DarkGray

    $gitignoreContent  = Get-FileContentCapped -Path (Join-Path $ComfyPath ".gitignore")
    $excludeFile       = Join-Path $ComfyPath (Join-Path ".git" (Join-Path "info" "exclude"))
    $excludeContent    = Get-FileContentCapped -Path $excludeFile

    # ==========================================================================
    # BUILD REPORT
    # ==========================================================================

    Write-Host "Writing report..." -ForegroundColor DarkGray

    Add-Md "# ComfyUI Protected Paths - Diagnostic Report"
    Add-Md ""
    Add-Md "Generated : $($envInfo.Date)"
    Add-Md "Generator : ComfyUI_ProtectedPaths_Diagnostics.ps1 (v1.0)"
    Add-Md ('Repository: "' + $ComfyPath + '"')
    Add-Md ""
    if ($fetched) {
        Add-Md 'Remote data was FRESH: `git fetch origin --prune` was run before collection.'
    }
    else {
        Add-Md '**Remote data is STALE-POSSIBLE:** no fetch was performed. All `origin/*` findings reflect the last fetch this machine made. Re-run with `-Fetch` for current data.'
    }
    Add-Md ""

    # ----------------------------------------------------------------------
    # 1. EXECUTIVE SUMMARY
    # ----------------------------------------------------------------------

    Add-Md "## 1. Executive Summary"
    Add-Md ""
    Add-Md "| Path | Exists | Filesystem type | Link target | Tracked @ HEAD | Tracked @ origin/* | Git-ignored | Verdict |"
    Add-Md "|------|--------|-----------------|-------------|----------------|--------------------|-------------|---------|"

    foreach ($pr in $pathReports) {

        $remoteSummary = "(no remote refs)"
        if ($pr.RemoteEntryCounts.Count -gt 0) {
            $parts = @()
            foreach ($ref in $pr.RemoteEntryCounts.Keys) {
                $parts += "$ref=$($pr.RemoteEntryCounts[$ref])"
            }
            $remoteSummary = $parts -join ", "
        }

        $trackedHeadText = "NO"
        if ($pr.TrackedAtHead) {
            $trackedHeadText = "YES ($($pr.HeadEntries.Count) entries)"
        }

        $trackedRemoteText = "NO"
        if ($pr.TrackedAtRemote) {
            $trackedRemoteText = "YES ($remoteSummary)"
        }

        $existsText = "no"
        if ($pr.Info.Exists) { $existsText = "yes" }

        $typeText = $pr.Info.Type
        $targetText = $pr.Info.LinkTarget
        if ([string]::IsNullOrWhiteSpace($targetText)) {
            $targetText = "-"
        }

        $ignoredText = "no"
        if ($pr.Ignored) { $ignoredText = "yes" }

        Add-Md (
            "| " + $pr.Folder +
            " | " + $existsText +
            " | " + $typeText +
            " | " + $targetText +
            " | " + $trackedHeadText +
            " | " + $trackedRemoteText +
            " | " + $ignoredText +
            " | **" + $pr.Verdict.Code + ". " + $pr.Verdict.Label + "** |"
        )
    }

    Add-Md ""
    Add-Md "Verdict legend: **A** = tracked by Git (hands-off NOT safe), **B** = untracked + ignored (hands-off safe), **C** = untracked + not ignored (hands-off safe but fragile), **D** = missing."
    Add-Md ""

    $anyTracked = @($pathReports | Where-Object { $_.Verdict.Code -eq "A" }).Count
    if ($anyTracked -gt 0) {
        Add-Md (
            "> **Bottom line:** " +
            $anyTracked +
            " of 3 protected path(s) are TRACKED by the ComfyUI repository. " +
            "Checkout/checkout_tree will replace a symlink/junction at such a path with a real directory. " +
            "The v11 design must keep an explicit protection for these paths - the rename-away/restore flow is the proven mechanism."
        )
        Add-Md ""
    }
    else {
        Add-Md (
            "> **Bottom line:** no protected path is tracked by the repository on this machine. " +
            "A hands-off v11 design (leave links untouched, verify after update) is supported by this data - see section 9."
        )
        Add-Md ""
    }

    # ----------------------------------------------------------------------
    # 2. ENVIRONMENT
    # ----------------------------------------------------------------------

    Add-Md "## 2. Environment"
    Add-Md ""
    Add-Md "| Property | Value |"
    Add-Md "|----------|-------|"
    Add-Md "| Date / time | " + $envInfo.Date + " |"
    Add-Md "| Host | " + $envInfo.HostName + " |"
    Add-Md "| PowerShell | " + $envInfo.PSVersion + " (" + $envInfo.PSEdition + ") |"
    Add-Md "| OS | " + $envInfo.OSVersion + " |"
    Add-Md "| Git | " + $envInfo.GitVersion + " |"
    Add-Md "| Git executable | " + $envInfo.GitPath + " |"
    Add-Md "| core.symlinks | " + $envInfo.CoreSymlinks + " |"
    Add-Md "| Embedded Python | " + $pythonVersion + " |"
    Add-Md "| pygit2 | " + $pygit2Version + " |"
    Add-Md ""
    if ($envInfo.CoreSymlinks -ne "(unset - git default)") {
        Add-Md ('Note: `core.symlinks` is explicitly set to "' + $envInfo.CoreSymlinks + '" in the local/global/system Git config. This controls how git materializes TRACKED symlink entries.')
        Add-Md ""
    }

    # ----------------------------------------------------------------------
    # 3. GIT REPOSITORY STATE
    # ----------------------------------------------------------------------

    Add-Md "## 3. Git Repository State"
    Add-Md ""
    Add-Md "| Property | Value |"
    Add-Md "|----------|-------|"
    Add-Md "| Branch | " + $branch + $(if ($isDetached) { " (**DETACHED HEAD**)" } else { "" }) + " |"
    Add-Md "| HEAD | `" + $headCommit + "`" |"
    Add-Md "| origin URL | " + $remoteUrl + " |"
    Add-Md "| origin/HEAD | " + $originHead + " |"
    Add-Md "| Stable remote refs found | " + $(if ($stableRefCandidates.Count -gt 0) { $stableRefCandidates -join ", " } else { "(none)" }) + " |"
    Add-Md "| vs. stable ref | " + $aheadBehind + " |"
    Add-Md "| Dirty entries (git status) | " + $dirtyCount + " total, " + $deletedCount + " deleted |"
    Add-Md ""

    Add-Md "### 3.1 Working tree status (full)"
    Add-Md ""
    Add-Fenced (Cap-Lines -Text $statusShort.Output -Max 300)
    Add-Md ""
    if ($deletedCount -gt 0) {
        Add-Md (
            '**Interpretation:** ' +
            $deletedCount +
            ' tracked file(s) are reported as **deleted**. In a symlinked setup this is the normal state for the placeholder files under models/input/output: Git looks through the junction, finds the placeholder files are absent in the link target, and reports them as deleted. The stock updater''s `repo.stash()` call absorbs exactly these deletions on every run.'
        )
        Add-Md ""
    }

    Add-Md "### 3.2 Stash list"
    Add-Md ""
    Add-Fenced (Cap-Lines -Text $stashList.Output -Max 50)
    Add-Md ""
    if (-not [string]::IsNullOrWhiteSpace($stashList.Output)) {
        Add-Md "These stash entries accumulate because update.py stashes before each update but never pops afterwards."
        Add-Md ""
    }

    Add-Md "### 3.3 Local branches (newest first)"
    Add-Md ""
    Add-Fenced (Cap-Lines -Text $branchList.Output -Max 40)
    Add-Md ""
    Add-Md 'Both `backup/pre_update_*` (created by the Safe Update Manager) and `backup_branch_*` (created by update.py itself) are rollback points.'
    Add-Md ""

    Add-Md "### 3.4 Recent commits"
    Add-Md ""
    Add-Fenced $recentLog.Output
    Add-Md ""

    Add-Md "### 3.5 Local Git config"
    Add-Md ""
    Add-Fenced (Cap-Lines -Text $localConfig.Output -Max 100)
    Add-Md ""

    Add-Md "### 3.6 Sparse checkout"
    Add-Md ""
    $sparseStateText = "disabled"
    if (
        $sparseEnabled.ExitCode -eq 0 -and
        $sparseEnabled.Output -eq "true"
    ) {
        $sparseStateText = "ENABLED"
    }
    Add-Md "core.sparseCheckout = " + $(if ($sparseEnabled.ExitCode -eq 0) { $sparseEnabled.Output } else { "(unset) - " + $sparseStateText })
    if ($sparseStateText -eq "ENABLED") {
        Add-Md ""
        Add-Md "Sparse-checkout patterns:"
        Add-Md ""
        Add-Fenced (Cap-Lines -Text $sparseList.Output -Max 100)
        Add-Md ""
        Add-Md "With sparse-checkout enabled, the verdicts in section 4 must be read with care: paths outside the sparse cone behave differently during checkout."
    }
    Add-Md ""

    # ----------------------------------------------------------------------
    # 4. PROTECTED PATH ANALYSIS
    # ----------------------------------------------------------------------

    Add-Md "## 4. Protected Path Analysis"
    Add-Md ""
    Add-Md "This section is the core evidence. Per path: what the filesystem holds, and exactly what Git thinks about that path."
    Add-Md ""

    foreach ($pr in $pathReports) {

        Add-Md ('### 4.' + ($pathReports.IndexOf($pr) + 1) + ' `' + $pr.Folder + '`')
        Add-Md ""
        Add-Md "| Property | Value |"
        Add-Md "|----------|-------|"
        Add-Md "| Full path | `" + $pr.FullPath + "`" |"
        Add-Md "| Exists | " + $(if ($pr.Info.Exists) { "yes" } else { "no" }) + " |"
        Add-Md "| Filesystem type | " + $pr.Info.Type + " |"
        if ($pr.Info.Type -like "*link*" -or $pr.Info.Type -eq "junction (mount point)") {
            Add-Md "| Link target | `" + $(if ([string]::IsNullOrWhiteSpace($pr.Info.LinkTarget)) { "?" } else { $pr.Info.LinkTarget }) + "`" |"
            if (-not [string]::IsNullOrWhiteSpace($pr.Info.ReparseTag) -and $pr.Info.ReparseTag -ne "(fsutil not available)") {
                Add-Md "| Reparse tag | " + $pr.Info.ReparseTag + " |"
            }
        }
        if ($pr.Info.TopLevelCount -ne $null) {
            Add-Md "| Top-level entries in target | " + $pr.Info.TopLevelCount + " |"
        }
        Add-Md "| Tracked at HEAD | " + $(if ($pr.TrackedAtHead) { "YES - " + $pr.HeadEntries.Count + " file(s)" } else { "no" }) + " |"
        $remoteText = "no"
        if ($pr.TrackedAtRemote) {
            $remoteText =
                (
                    $pr.RemoteEntryCounts.Keys |
                        ForEach-Object {
                            $_ + " (" + $pr.RemoteEntryCounts[$_] + " file(s))"
                        }
                ) -join " + "
        }
        Add-Md "| Tracked at remote ref(s) | " + $remoteText + " |"
        Add-Md "| Git-ignored | " + $(if ($pr.Ignored) { "yes" } else { "no (check-ignore exit " + $pr.IgnoreExitCode + ")" }) + " |"
        Add-Md "| Index match | " + $(if ($pr.MatchExitCode -eq 0) { "yes (ls-files --error-unmatch exit 0)" } else { "no (exit " + $pr.MatchExitCode + ")" }) + " |"
        Add-Md "| **Verdict** | **" + $pr.Verdict.Code + ". " + $pr.Verdict.Label + "** |"
        Add-Md ""
        Add-Md "**Recommendation:** " + $pr.Verdict.Recommendation
        Add-Md ""

        Add-Md "Raw Git evidence:"
        Add-Md ""
        Add-Md "`$ git ls-tree -r HEAD -- " + $pr.Folder
        Add-Md ""
        Add-Fenced (Cap-Lines -Text $pr.LsTreeHeadOutput -Max 100)
        Add-Md ""

        foreach ($ref in $pr.RemoteEntryCounts.Keys) {
            $lsTreeRemote = Run-Git -Arguments @("ls-tree", "-r", $ref, "--", $pr.Folder)
            Add-Md "`$ git ls-tree -r " + $ref + " -- " + $pr.Folder
            Add-Md ""
            Add-Fenced (Cap-Lines -Text $lsTreeRemote.Output -Max 100)
            Add-Md ""
        }

        Add-Md "`$ git check-ignore -v -- " + $pr.Folder
        Add-Md ""
        Add-Fenced $pr.IgnoreOutput
        Add-Md ("(exit code " + $pr.IgnoreExitCode + " - 0 means ignored, 1 means not ignored)")
        Add-Md ""

        Add-Md "`$ git ls-files -v -- " + $pr.Folder
        Add-Md ""
        Add-Fenced $pr.FlagsOutput
        Add-Md ("(leading flag: H = normal cached entry, S = skip-worktree, h = assume-unchanged)")
        Add-Md ""

        Add-Md "`$ git status --short --untracked-files=all -- " + $pr.Folder
        Add-Md ""
        Add-Fenced $pr.PathStatusOutput
        Add-Md ""
    }

    # ----------------------------------------------------------------------
    # 5. UPDATER CHAIN
    # ----------------------------------------------------------------------

    Add-Md "## 5. Updater Chain"
    Add-Md ""
    Add-Md 'The actual update is performed by `update\update_comfyui.bat` -> `update.py` (pygit2), NOT by the Safe Update Manager. The manager only prepares, invokes, and verifies.'
    Add-Md ""

    Add-Md "| Item | Value |"
    Add-Md "|------|-------|"
    Add-Md "| Local update folder | `" + $(if ([string]::IsNullOrWhiteSpace($UpdateDir)) { "NOT FOUND" } else { $UpdateDir }) + "`" |"
    Add-Md "| Repo-shipped updater dir | `" + $ciDir + "`" |"
    Add-Md "| Self-update pending | " + $selfUpdatePending + " |"
    Add-Md ""

    foreach ($uf in $updaterFiles) {
        Add-Md ('### File: `' + $uf.Path + '`')
        Add-Md ""
        Add-Md "Source: " + $uf.Location
        Add-Md ""
        Add-Fenced $(if ($null -ne $uf.Content) { $uf.Content } else { "(file not present)" })
        Add-Md ""
    }

    # ----------------------------------------------------------------------
    # 6. BEHAVIOR FLAGS
    # ----------------------------------------------------------------------

    Add-Md "## 6. Stock Updater Behavior Flags"
    Add-Md ""
    Add-Md "Scanned from the ACTUAL local updater files on this machine:"
    Add-Md ""
    Add-Md "| Flag | Detected | Where | Meaning |"
    Add-Md "|------|----------|-------|---------|"
    foreach ($f in $flags) {
        $detectedText = "no"
        if ($f.Detected) { $detectedText = "**YES**" }
        Add-Md ("| " + $f.Flag + " | " + $detectedText + " | " + $f.Where + " | " + $f.Meaning + " |")
    }
    Add-Md ""

    # ----------------------------------------------------------------------
    # 7. IGNORE CONFIGURATION
    # ----------------------------------------------------------------------

    Add-Md "## 7. Ignore Configuration"
    Add-Md ""
    Add-Md '### 7.1 `.gitignore` (repository)'
    Add-Md ""
    Add-Fenced $(if ($null -ne $gitignoreContent) { $gitignoreContent } else { "(not found)" })
    Add-Md ""

    Add-Md '### 7.2 `.git/info/exclude` (local, unshared)'
    Add-Md ""
    Add-Fenced $(if ($null -ne $excludeContent) { $excludeContent } else { "(not found - this is the recommended place to ignore models/output/input locally, without touching the shared .gitignore)" })
    Add-Md ""

    $coreExclText = "(unset)"
    if ($coreExcludesFile.ExitCode -eq 0) {
        $coreExclText = $coreExcludesFile.Output
    }
    Add-Md "core.excludesFile = " + $coreExclText
    Add-Md ""

    # ----------------------------------------------------------------------
    # 8. RAW BASE COMMANDS
    # ----------------------------------------------------------------------

    Add-Md "## 8. Raw Base Commands (verbatim)"
    Add-Md ""
    Add-Md "The exact commands requested in the investigation, with raw output and exit codes. These are the minimal evidence set:"
    Add-Md ""

    Add-Md "`$ git ls-tree -r HEAD -- models"
    Add-Md ""
    Add-Fenced (Cap-Lines -Text $rawLsTreeModels.Output -Max 150)
    Add-Md ("(exit code " + $rawLsTreeModels.ExitCode + ")")
    Add-Md ""

    Add-Md "`$ git ls-tree -r HEAD -- output"
    Add-Md ""
    Add-Fenced (Cap-Lines -Text $rawLsTreeOutput.Output -Max 150)
    Add-Md ("(exit code " + $rawLsTreeOutput.ExitCode + ")")
    Add-Md ""

    Add-Md "`$ git ls-tree -r HEAD -- input"
    Add-Md ""
    Add-Fenced (Cap-Lines -Text $rawLsTreeInput.Output -Max 150)
    Add-Md ("(exit code " + $rawLsTreeInput.ExitCode + ")")
    Add-Md ""

    Add-Md "`$ git status --short --untracked-files=all -- models output input"
    Add-Md ""
    Add-Fenced $rawStatus.Output
    Add-Md ("(exit code " + $rawStatus.ExitCode + ")")
    Add-Md ""

    Add-Md "`$ git check-ignore -v models output input"
    Add-Md ""
    Add-Fenced $rawCheckIgnore.Output
    Add-Md ("(exit code " + $rawCheckIgnore.ExitCode + " - 0 = at least one path ignored, 1 = none ignored)")
    Add-Md ""

    # ----------------------------------------------------------------------
    # 9. CONCLUSIONS / v11 INPUTS
    # ----------------------------------------------------------------------

    Add-Md "## 9. Conclusions and Inputs for the v11 Design"
    Add-Md ""
    Add-Md "### 9.1 Per-path protection decision"
    Add-Md ""
    foreach ($pr in $pathReports) {
        Add-Md (
            '- **`' + $pr.Folder + '`** - ' +
            $pr.Verdict.Code + '. ' + $pr.Verdict.Label +
            ' -> ' + $(if ($pr.Verdict.SafeHandsOff) { 'hands-off OK' } else { 'EXPLICIT PROTECTION REQUIRED' })
        )
    }
    Add-Md ""

    Add-Md "### 9.2 What the updater does that can destroy the links"
    Add-Md ""
    Add-Md 'Confirmed mechanism (reproduced with `git checkout` in a sandbox, and present in the stock update.py via pygit2 `checkout_tree`):'
    Add-Md ""
    Add-Md '```text'
    Add-Md "before:  ComfyUI\input  ->  D:\...\input_store   (junction/symlink)"
    Add-Md "         git tree tracks: input/example.png"
    Add-Md "checkout: Git must materialize input/ as a real directory"
    Add-Md "after:   ComfyUI\input  =  real directory with example.png"
    Add-Md "         (the junction is gone; the link TARGET data is untouched)"
    Add-Md '```'
    Add-Md ""
    Add-Md (
        "So on this machine the protection requirement is: " +
        $(if ($anyTracked -gt 0) {
            "paths tracked in section 4 MUST be moved aside (or otherwise excluded from checkout) for the duration of the update. The v10.1 rename-away / verify / restore flow is the correct behavior and should be kept, with its preflight now ASSERTING the case-A state instead of assuming it."
        } else {
            "no tracked paths detected - a hands-off flow is viable; still verify the links exist and are untouched after every update, and re-run this diagnostic if the ComfyUI repository layout ever changes."
        })
    )
    Add-Md ""

    Add-Md "### 9.3 Other v11-relevant findings"
    Add-Md ""
    foreach ($f in $flags) {
        if ($f.Detected) {
            Add-Md ("- **" + $f.Flag + "**: " + $f.Meaning)
        }
    }
    if ($isDetached) {
        Add-Md "- **DETACHED HEAD**: the repository is not on a branch. The manager must refuse to update (or force a checkout first) - branch verification would be meaningless."
    }
    if ($pygit2Version -like "NOT IMPORTABLE*") {
        Add-Md "- **pygit2 NOT IMPORTABLE** by the embedded Python: the stock updater cannot run at all in this state. The report's updater flags are based on file content, but the live behavior would differ."
    }
    Add-Md ""

    Add-Md "### 9.4 Data quality"
    Add-Md ""
    if (-not $fetched) {
        Add-Md '- Remote refs (`origin/*`) were NOT refreshed; re-run with `-Fetch` if absolute currency is required.'
    }
    else {
        Add-Md '- Remote refs were refreshed via `git fetch origin --prune` before collection.'
    }
    Add-Md '- `git ls-tree`/`check-ignore` reflect the local repository state; on a fresh machine right after a manual clone+link setup, some entries (e.g. `origin/HEAD`) may be missing.'
    Add-Md ""

    Add-Md "### 9.5 Suggested v11 preflight (machine-verifiable)"
    Add-Md ""
    Add-Md '```text'
    Add-Md "For each of models, output, input:"
    Add-Md "    1. classify: exists? type? (this script's verdict A/B/C/D)"
    Add-Md "    2. if A (tracked)     -> enable rename-away protection for this path"
    Add-Md "    3. if B (ignored)     -> hands-off allowed"
    Add-Md "    4. if C (untracked)   -> hands-off allowed, but warn + suggest .git/info/exclude"
    Add-Md "    5. always: after update, re-check that the path still exists with the same type/target"
    Add-Md '```'
    Add-Md ""

    Add-Md "---"
    Add-Md ""
    Add-Md "*End of report. Send this file back for the v11 design step.*"

    # ----------------------------------------------------------------------
    # WRITE REPORT
    # ----------------------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($OutFile)) {
        $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
        $OutFile = Join-Path $scriptRoot "ComfyUI_ProtectedPaths_Diagnostics_$stamp.md"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        $OutFile,
        ($md -join "`r`n"),
        $utf8NoBom
    )
}
finally {
    Pop-Location
}

# ============================================================================
# CONSOLE SUMMARY
# ============================================================================

Write-Host ""
Write-Host "====================== SUMMARY ======================" -ForegroundColor Cyan
Write-Host ""
foreach ($pr in $pathReports) {
    $statusColor = "Green"
    if ($pr.Verdict.Code -eq "A") { $statusColor = "Red" }
    elseif ($pr.Verdict.Code -eq "C") { $statusColor = "Yellow" }
    elseif ($pr.Verdict.Code -eq "D") { $statusColor = "DarkGray" }

    Write-Host (
        ("{0,-8} : {1,-22} {2}.{3}" -f
            $pr.Folder,
            $pr.Info.Type,
            $pr.Verdict.Code,
            $pr.Verdict.Label)
    ) -ForegroundColor $statusColor
}
Write-Host ""
Write-Host ("Report written to: " + $OutFile) -ForegroundColor Cyan
Write-Host ""
Write-Host "Attach that .md file to the next conversation turn." -ForegroundColor DarkGray

$isWindowsPlatform = $true
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $isWindowsPlatform = ($IsWindows -eq $true)
}
if ($isWindowsPlatform) {
    pause
}
