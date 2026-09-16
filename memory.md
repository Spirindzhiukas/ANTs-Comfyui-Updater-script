# MEMORY.md — Agent Working Notes (ANTs ComfyUI Updater)

## 0. READ THIS FIRST — environment reminder

**This project targets WINDOWS. Not Linux. Not bash. Not macOS.**

- The deliverables are **Windows PowerShell 5.1 scripts** (+ cmd.exe BAT files) that run on
  Antanas' Windows machine: a ComfyUI *portable* installation at `C:\ComfyUI_PORTABLE\`
  with layout `ComfyUI\` (git repo) + `update\` (updater) + `python_embeded\`.
- This agent's sandbox is **Linux/bash**. Anything you test here is a PROXY:
  - Git *command semantics* (flags, exit codes, output formats) are portable — safe to
    verify against a local mock repo.
  - **PowerShell cannot be executed in this sandbox (no pwsh; GitHub release-asset hosts
    are network-blocked here).** PS correctness must come from: (a) the rules in §2,
    (b) strict static checks (§4 playbook), (c) patterns already proven in
    `previous_versions/ComfyUI_Safe_Update_Manager_v10_1.ps1`.
  - When you test something in bash/python, check the result for LINUX-ONLY assumptions
    before applying it to the Windows code: line endings (CRLF vs LF), path separators,
    case sensitivity, `fsutil`/`where.exe`/`pause` (Windows-only), ANSI codepage vs UTF-8.
- **File transfer to the user goes through a Markdown-aware UI.** Backticks are Markdown
  syntax and get EATEN by some viewers/transfers; indentation can shift. This has
  corrupted the delivered .ps1 TWICE (see §3, F8/F11). Rules:
  - Keep backtick usage in .ps1 minimal — prefer single-quoted strings for any text
    containing backticks, quotes, or `$`.
  - The diagnostics script now carries a **self-integrity check** (hash of the file
    content outside the SELF-INTEGRITY markers) that aborts with instructions if the
    delivered file is not the committed one. If you edit the script, recompute the core
    hash (§5) and commit both together.
  - In chat instructions to the user: never use backticks in the PowerShell commands you
    paste for them.
- Windows conventions in code: `Join-Path` (or explicit backslashes) for paths,
  `Test-Path` before touching anything, CRLF is the native line ending (LF-only .ps1
  files still parse fine in PowerShell, keep the repo file LF — the self-check is
  CRLF-agnostic).

## 1. Project state (as of 2026-09-17)

- `INVESTIGATIONS/GPT_and_friends_chat.md` — the full investigation log (v8 → v9 reviews →
  update.py discovery → the "hands-off" hypothesis).
- `previous_versions/` — Safe Update Manager v5, v8, **v10.1** (current manager), the
  original OreX/ANTs symlink BAT, and `update/` (update.py, update_comfyui.bat, ...).
- **`ComfyUI_ProtectedPaths_Diagnostics.ps1`** (repo root) — the deliverable from the
  chat's last open item. Antanas runs it on his machine and sends back the generated
  `ComfyUI_ProtectedPaths_Diagnostics_<ts>.md`.
- **Next step (v11 design) is BLOCKED on that report.** Verified ahead of it:
  - Real ComfyUI repo (master) TRACKS all three folders: `models/` (63 entries incl.
    `put_checkpoints_here` placeholders + real configs), `input/example.png`,
    `output/_output_images_will_be_put_here`. → case **A (TRACKED)** on Antanas' machine
    → the "leave untouched / hands-off" hypothesis is NOT safe as-is; the v10.1
    rename-away/verify/restore flow is the proven mechanism (v11 should ASSERT case A in
    preflight instead of assuming it).
  - Reproduced the destructive step: `git checkout -f master` replaced the symlinked
    `input` with a real directory (link-target data untouched).
  - `update_comfyui.bat` ends with `if "%~1"=="" pause` → **pause trap**: any caller that
    invokes it without an argument hangs. v11 must pass a dummy argument.
  - Stock `update.py`: stashes tracked changes, creates `backup_branch_*`, is
    **master-only** (`repo.lookup_branch('master')`), uses pygit2 `checkout_tree` (the
    destructive reconciliation), self-updates via `update_new.py` + bat re-run
    (`--skip_self_update`). Repo `requirements.txt` no longer pins pygit2 — the embedded
    python must provide it.

## 2. Windows PowerShell (5.1) syntax rules — learned the hard way

### 2.1 Backtick escaping in DOUBLE-quoted strings
Only `` ` `` + a recognized character is an escape: `n t r 0 a b e f v " ' $ ` > <` and
space. `` ` `` + anything else → the backtick is PRESERVED (fragile — avoid for text).

- FAIL: `Add-Md "```"` — backtick escapes backtick, third backtick escapes the closing
  quote → string never ends → cascade parse errors hundreds of lines later.
- WORK: `Add-Md '```'` — single quotes need no escapes at all.
- FAIL: `Add-Md "```text"` — `` `t `` is the **TAB** escape → outputs `` ` `` + TAB + `ext`.
- WORK: `Add-Md '```text'`.

### 2.2 Backtick before a letter that IS a recognized escape injects a control char
- FAIL: `"Both `backup/pre_update_*` ..."` — `` `b `` = BEL (0x07) control character.
- FAIL: "the updater's `repo.stash()` call" — `` `r `` = CR.
- WORK: single-quoted: `'Both `backup/pre_update_*` ...'`.

### 2.3 `""` does NOT escape a quote inside double-quoted strings
Inside `"..."` only `` `" `` produces a literal quote. `""` closes the string and opens a
new one → everything after is reparsed as code. (In single-quoted strings, `''` is the
only escape and `"` is literal.)
- FAIL (subtle, same-line): regex written as `"if\s+`"%~1`"\s*==\s*`"`"\s+pause"` with a
  MISSING backtick before the second quote → string closes early, `\s+pause` becomes code.
- WORK: put regexes with quotes in SINGLE quotes: `'if\s+"%~1"\s*==\s*""\s+pause'`.

### 2.4 Static text → single-quoted strings
Single quotes: everything literal except `''` → `'`. Use double quotes only for `$var`
or `$(expr)` interpolation. When a line needs BOTH markdown backticks/quotes AND a
variable: concatenate single-quoted fragments:
`Add-Md ('| HEAD | "' + $headCommit + '" |')`.
This pattern is also corruption-proof: if a backtick is lost in transit, the worst case
is cosmetic, never a parse break.

### 2.5 Line continuation
Trailing BACKTICK at end of line (NOT backslash — bash/macOS habit).

### 2.6 PS 7-only things that BREAK on Windows PowerShell 5.1 — do not use
- `Join-String` (use `-join`)
- ternary `? :`, null-coalescing `??`
- `$IsWindows`, `$PSVersionTable.PSEdition` (guard with `$PSVersionTable.PSVersion.Major -ge 6`)
- 3-argument `Join-Path` (nest it: `Join-Path $a (Join-Path "b" "c")`)
- `Start-Process -TimeoutSeconds` (use a deadline loop over `Process.WaitForExit`)
- `$PSNativeCommandUseErrorActionPreference` behavior (PS7.4+)

### 2.7 Native commands (git, cmd) in PS 5.1
- `$LASTEXITCODE` reflects the native command even through pipes:
  `$out = (& git @args 2>&1 | Out-String); $code = $LASTEXITCODE`.
- With `$ErrorActionPreference = "Stop"`, a non-zero native exit does **NOT** throw in
  5.1 — always check `$LASTEXITCODE` explicitly.
- `& git @Arguments` (splatting an array) — never `Invoke-Expression "git $args"`.
- BAT quirks: `if "%~1"=="" pause` = pause trap; `cmd /c x.bat` propagates exit code.

### 2.8 Encoding
PS 5.1 reads a BOM-less .ps1 as ANSI/Windows-1252. Keep .ps1 files **pure ASCII** (the
diagnostics script is) or write them with a UTF-8 BOM. Verify with a byte scan.

### 2.9 Self-hash gotchas
A file cannot embed its own whole-file hash (chicken-and-egg). Use a **core hash**: hash
all lines OUTSIDE a marked block that holds the expected hash. Search for the block
markers with **anchored, first-match** patterns (`^# >>> ... BEGIN`) — the search code
itself often contains the marker string and will otherwise latch onto the wrong line.
Join lines with LF after `ReadAllLines` (strips CRLF/LF) → check is CRLF-agnostic.

## 3. Failure case log (symptom → root cause → fix)

- **F1** `"```"` fences inside double quotes → unterminated string, cascade parse errors
  → single-quoted `'```'` (§2.1).
- **F2** `"```text"` → TAB escape mangled the fence → single quotes (§2.1).
- **F3** `` `b ``/`` `r `` in markdown spans ("backup", "repo.stash()") → control chars in
  report → single quotes (§2.2).
- **F4** `Join-String " + "` → PS7-only, breaks 5.1 → `-join " + "`.
- **F5** `$(if (...) {...} else {...))` — one extra `)` → parse chaos found by balance
  checker → the `)` that closes `if (` must not also close `$(` — count opens per line.
- **F6** `Add-Md "- **" + $f.Flag + "**: " + $f.Meaning)` — stray `)` (Add-Md not wrapped
  in parens) → wrap: `Add-Md ("- **" + ...)`.
- **F7** `Add-Md "| Branch | ... + $(if (...) {...} else { "" }) + " |"` pattern is valid
  ONLY while every `` `" `` escape is intact — user's transfer lost one backtick (F8) and
  the whole thing collapsed → the single-quote-fragment rewrite (§2.4).
- **F8** User run #1: "Expressions are only allowed as the first element of a pipeline"
  at a `|` inside a string, char offset +2 vs committed line → backticks eaten by a
  Markdown-aware transfer; broken string swallowed following lines → hardened the script
  (no more backtick-escaped quotes) + SHA-256 verification instructions.
- **F9** User run #2: "A parameter cannot be found that matches parameter name 'Force'"
  on an invocation with ZERO arguments → the executed file is simply not the committed
  file (param block has no -Force) → added the runtime self-integrity check (core hash,
  aborts with re-download instructions).
- **F10** Self-integrity v1: marker search matched the `-match` code line (contains the
  marker text) instead of the marker comment → anchored `^# >>> ...` + first-match +
  break (§2.9).
- **F11** Self-hash v1: whole-file hash embedded in the file → can never match → core
  hash excluding the block (§2.9).

## 4. Sandbox verification playbook (Linux stand-ins for Windows)

1. **Git semantics** — build a mock repo that mirrors Antanas' layout (tracked
   placeholders under models/input/output + symlinks over them + origin/master) and run
   the EXACT commands: `ls-tree -r`, `status --short --untrusted-files=all`...
   (`--untracked-files=all`), `check-ignore -v`, `ls-files -v`, `ls-files
   --error-unmatch`, `for-each-ref`, `rev-list --left-right --count`. Verified output
   formats: `check-ignore -v` → `file:line:rule<TAB>path`, exit 0/1; `ls-files -v` →
   `H|S|h path`; `ls-tree` exit 0 even when empty.
2. **PS static checks** (run after EVERY edit; a python tokenizer that models PS
   string/escape semantics):
   - brace/paren/bracket balance over code (strings & comments stripped),
   - NO line may end inside an unterminated double/single-quoted string,
   - audit every backtick in double-quoted strings: only `n t r 0 a b e f v " ' $ ` > <`
     and space are acceptable; anything else → rewrite as single-quoted,
   - grep for PS7-only cmdlets (`Join-String` etc.) and 3-arg `Join-Path`.
3. **Logic twin** — port the verdict/decision flow to a python script and run it against
   the mock repo; confirm A/B/C/D classification matches expectations.
4. **Runtime sim** — mirror the self-integrity algorithm in python: must PASS on the
   committed file, FAIL on a backtick-stripped copy, PASS on a CRLF copy.
5. **Encoding** — byte-scan the .ps1 for non-ASCII; keep it pure ASCII.
6. What CANNOT be verified here: actual PowerShell parse/execution. Be explicit about
   that in the delivery message and give the user a hash to check.

## 5. Maintaining the diagnostics script's self-integrity hash

After any edit of `ComfyUI_ProtectedPaths_Diagnostics.ps1`:

1. Find block: first line matching `^# >>> SELF-INTEGRITY CHECK BEGIN` and the first
   following line matching `^# >>> SELF-INTEGRITY CHECK END` (inclusive).
2. Core = all lines OUTSIDE that range; join with `\n` (splitlines semantics, CRLF/LF
   agnostic); SHA-256, uppercase hex, no separators.
3. Replace the `$SelfIntegrityCoreHash = "..."` value (it is inside the block, so the
   core is unaffected by the fill).
4. Re-run step 2 to confirm stability; compute the whole-file SHA-256 (CRLF/LF as
   committed — currently LF, no BOM, pure ASCII) to publish in chat for user
   verification via `(Get-FileHash <path>).Hash`.
5. Commit script (+ memory.md changes) and push to the session branch.

## 6. User communication notes

- Antanas is a practitioner, not a scripter: he runs what we hand him and pastes back
  the raw error output. Respond to errors by DIFFING the reported line/char offsets
  against the committed file — offsets that don't match prove transfer corruption.
- Keep chat PowerShell snippets free of backticks (they get eaten by the UI).
- He values: one-file deliverables, no surgery, and honest confidence levels.
- The next deliverable after the diagnostic report returns: **v11 of the Safe Update
  Manager** (see §1 next step).
