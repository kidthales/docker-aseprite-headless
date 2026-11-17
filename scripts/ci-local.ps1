<#
.SYNOPSIS
    Runs the local continuous integration verification suite for docker-aseprite-headless.
.DESCRIPTION
    Executes static analysis, hygiene, and unit verification gates locally and in CI:
    0. Gate 0: Agent & scratch file leak audit (tracked and untracked)
    1. Gate 1: PowerShell AST parse validation (*.ps1)
    2. Gate 2: Task static analysis suite (task lint: bake, hadolint, shellcheck, actionlint, editorconfig)
    3. Gate 3: Unit test suite (task test:unit and task test:pwsh)
.PARAMETER CI
    Enforces strict fail-closed CI mode (auto-enabled when $env:GITHUB_ACTIONS is set):
    verifies required tools upfront and emits GitHub Actions log groups and error annotations.
.EXAMPLE
    pwsh ./scripts/ci-local.ps1
    pwsh ./scripts/ci-local.ps1 -CI
#>
[CmdletBinding()]
param(
    [switch]$CI
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$IsCI = $CI.IsPresent -or (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS))
$script:InGroup = $false

$TotalTimer = [System.Diagnostics.Stopwatch]::StartNew()

function Enter-CiGate {
    param([int]$Gate, [int]$MaxGate, [string]$Title)
    $Header = "[Gate $Gate/$MaxGate] $Title"
    if ($IsCI) {
        Write-Host "::group::$Header"
        $script:InGroup = $true
    } else {
        Write-Host "`n$Header" -ForegroundColor Yellow
    }
}

function Exit-CiGate {
    if ($IsCI -and $script:InGroup) {
        Write-Host "::endgroup::"
        $script:InGroup = $false
    }
}

function Write-Pass {
    param([string]$Message, [System.Diagnostics.Stopwatch]$Timer)
    if ($Timer) {
        $elapsed = [math]::Round($Timer.Elapsed.TotalSeconds, 2)
        Write-Host "  -> [OK] $Message (${elapsed}s)" -ForegroundColor Green
    } else {
        Write-Host "  -> [OK] $Message" -ForegroundColor Green
    }
}

function Write-Fail {
    param([string]$Message)
    if ($IsCI) {
        Write-Host "::error::$Message"
    }
    Write-Host "  -> [FAIL] $Message" -ForegroundColor Red
}

function Write-CiGateSummary {
    param([System.Collections.IDictionary]$Results)
    Write-Host "`nGate Summary:" -ForegroundColor Cyan
    foreach ($k in $Results.Keys) {
        $v = "$($Results[$k])".ToUpperInvariant()
        Write-Host "  [${k}: $v]"
    }
}

function Get-WorkingTreeFingerprint {
    $statusLines = @(& git -c core.quotePath=false status --porcelain=v1)
    if ($LASTEXITCODE -ne 0) {
        throw "git status --porcelain=v1 exited with $LASTEXITCODE."
    }

    $stagedDiff = (& git diff --cached --no-ext-diff --binary | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --cached exited with $LASTEXITCODE."
    }

    $dirtyPaths = @(& git -c core.quotePath=false ls-files --modified --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files --modified --others exited with $LASTEXITCODE."
    }

    $MaxIgnoredDepth = 5
    $MaxIgnoredFiles = 200
    $MaxHashBytes = 10485760

    $rawIgnoredPaths = @(& git -c core.quotePath=false ls-files --others --ignored --exclude-standard)
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files --others --ignored exited with $LASTEXITCODE."
    }

    $ignoredPaths = @(
        $rawIgnoredPaths |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                $_ -notmatch '(^|/)\.ci-local/' -and
                ($_ -split '/').Count -le $MaxIgnoredDepth
            } |
            Select-Object -First $MaxIgnoredFiles
    )

    $allPaths = @($dirtyPaths + $ignoredPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $fileHashes = foreach ($relPath in $allPaths) {
        if (Test-Path -LiteralPath $relPath -PathType Leaf) {
            try {
                $item = Get-Item -LiteralPath $relPath -ErrorAction Stop
                if ($item.Length -gt $MaxHashBytes) {
                    "${relPath}:LARGE:$($item.Length):$($item.LastWriteTimeUtc.Ticks)"
                } else {
                    $hash = (Get-FileHash -LiteralPath $relPath -Algorithm SHA256 -ErrorAction Stop).Hash
                    "${relPath}:$hash"
                }
            } catch {
                "${relPath}:UNREADABLE"
            }
        } else {
            "${relPath}:MISSING"
        }
    }

    return (@(
        "STATUS:"
        ($statusLines -join "`n")
        "STAGED:"
        $stagedDiff
        "FILES:"
        ($fileHashes -join "`n")
    ) -join "`n")
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " docker-aseprite-headless Local CI Pipeline$(if ($IsCI) { ' [-CI Mode]' } else { '' })" -ForegroundColor Cyan
Write-Host " Root: $RootDir" -ForegroundColor Gray
Write-Host "====================================================" -ForegroundColor Cyan

$GateResults = [ordered]@{
    "gate0_agent_leaks" = "not-applicable"
    "gate1_pwsh_ast"    = "not-applicable"
    "gate2_task_lint"   = "not-applicable"
    "gate3_unit_tests"  = "not-applicable"
}

$MaxGate = 3

Push-Location $RootDir
try {
    $requiredTools = @(
        @{ Name = "git"; Hint = "Install Git and ensure 'git' is on PATH." },
        @{ Name = "task"; Hint = "Install go-task (Taskfile) and ensure 'task' is on PATH." },
        # Required by containerized 'task lint' and 'task test:unit' sub-tasks.
        @{ Name = "docker"; Hint = "Install Docker Desktop / Engine and ensure 'docker' is on PATH." },
        # Required by 'task test:pwsh' in Gate 3 (for example when invoked from Windows PowerShell 5.1).
        @{ Name = "pwsh"; Hint = "Install PowerShell 7+ and ensure 'pwsh' is on PATH." }
    )
    foreach ($tool in $requiredTools) {
        if (-not (Get-Command $tool.Name -ErrorAction SilentlyContinue)) {
            Write-Fail "Required tool '$($tool.Name)' was not found on PATH. $($tool.Hint)"
            throw "Prerequisite check failed: missing '$($tool.Name)'."
        }
    }

    # -------------------------------------------------------------
    # Gate 0: Agent & Scratch File Leak Audit
    # -------------------------------------------------------------
    Enter-CiGate 0 $MaxGate "Auditing repository for agent, CI receipt, and scratch leaks..."
    $GateResults["gate0_agent_leaks"] = "fail"
    try {
        $StepTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $TrackedLeakPattern = '(^|/)(\.agents?/|\.gemini/|\.ai/|\.cursor/|\.claude/|\.ci-local/|scratch/|docs/learnings/|(AGENTS|GEMINI|CLAUDE)\.md$)'
        $UntrackedLeakPattern = '(^|/)(\.agents?/|\.gemini/|\.ai/|\.cursor/|\.claude/|scratch/|docs/learnings/|(AGENTS|GEMINI|CLAUDE)\.md$)'

        $TrackedFiles = @(& git ls-files)
        if ($LASTEXITCODE -ne 0) {
            throw "Gate 0 Failed: git ls-files exited with $LASTEXITCODE."
        }
        $TrackedLeaks = @($TrackedFiles | Where-Object { $_ -match $TrackedLeakPattern })

        $UntrackedFiles = @(& git ls-files --others --exclude-standard)
        if ($LASTEXITCODE -ne 0) {
            throw "Gate 0 Failed: git ls-files --others exited with $LASTEXITCODE."
        }
        $UntrackedLeaks = @($UntrackedFiles | Where-Object { $_ -match $UntrackedLeakPattern })

        $HasLeak = $false
        if ($TrackedLeaks.Count -gt 0) {
            Write-Fail "Tracked agent, CI receipt, or scratch files detected in git:"
            foreach ($file in $TrackedLeaks) {
                Write-Host "     * $file" -ForegroundColor Red
            }
            $HasLeak = $true
        }

        if ($UntrackedLeaks.Count -gt 0) {
            Write-Fail "Untracked agent or scratch files detected in workspace:"
            foreach ($file in $UntrackedLeaks) {
                Write-Host "     * $file" -ForegroundColor Red
            }
            $HasLeak = $true
        }

        if ($HasLeak) {
            throw "Gate 0 Failed: Agent, CI receipt, or scratch files must not be tracked or left untracked in the repository."
        }

        $GateResults["gate0_agent_leaks"] = "pass"
        Write-Pass "Agent and scratch leak audit passed." $StepTimer
    } finally {
        Exit-CiGate
    }

    # -------------------------------------------------------------
    # Gate 1: PowerShell AST Parse Validation
    # -------------------------------------------------------------
    Enter-CiGate 1 $MaxGate "Running PowerShell AST parse validation (*.ps1)..."
    $GateResults["gate1_pwsh_ast"] = "fail"
    try {
        $StepTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $Ps1RelPaths = @(& git -c core.quotePath=false ls-files --cached --others --exclude-standard -- "*.ps1" | Sort-Object -Unique)
        if ($LASTEXITCODE -ne 0) {
            throw "Gate 1 Failed: git ls-files for *.ps1 exited with $LASTEXITCODE."
        }
        $Ps1Files = @(
            $Ps1RelPaths |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^\.ci-local/' } |
                ForEach-Object { Join-Path $RootDir $_ } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        )
        if ($Ps1Files.Count -eq 0) {
            throw "Gate 1 Failed: Expected at least one PowerShell script (*.ps1) under $RootDir."
        }

        $ParseErrors = 0
        foreach ($psPath in $Ps1Files) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($psPath, [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors.Count -gt 0) {
                Write-Fail "Parse error in ${psPath}: $($errors | Out-String)"
                $ParseErrors++
            }
        }
        if ($ParseErrors -gt 0) {
            throw "Gate 1 Failed: $ParseErrors PowerShell script(s) failed AST parse validation."
        }

        $GateResults["gate1_pwsh_ast"] = "pass"
        Write-Pass "PowerShell AST validation passed ($($Ps1Files.Count) script(s))." $StepTimer
    } finally {
        Exit-CiGate
    }

    # -------------------------------------------------------------
    # Gate 2: Task Static Analysis Suite (task lint)
    # -------------------------------------------------------------
    Enter-CiGate 2 $MaxGate "Running static analysis suite (task lint)..."
    $GateResults["gate2_task_lint"] = "fail"
    try {
        $StepTimer = [System.Diagnostics.Stopwatch]::StartNew()
        & task lint
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "task lint failed with exit code $LASTEXITCODE."
            throw "Gate 2 Failed: task lint reported static analysis errors."
        }

        $GateResults["gate2_task_lint"] = "pass"
        Write-Pass "task lint passed." $StepTimer
    } finally {
        Exit-CiGate
    }

    # -------------------------------------------------------------
    # Gate 3: Unit Test Suite (task test:unit & task test:pwsh)
    # -------------------------------------------------------------
    Enter-CiGate 3 $MaxGate "Running unit test suite (task test:unit & task test:pwsh)..."
    $GateResults["gate3_unit_tests"] = "fail"
    try {
        $StepTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $PreTestFingerprint = Get-WorkingTreeFingerprint

        & task test:unit
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "task test:unit failed with exit code $LASTEXITCODE."
            throw "Gate 3 Failed: task test:unit failed."
        }

        & task test:pwsh
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "task test:pwsh failed with exit code $LASTEXITCODE."
            throw "Gate 3 Failed: task test:pwsh failed."
        }

        $PostTestFingerprint = Get-WorkingTreeFingerprint
        if ($PostTestFingerprint -ne $PreTestFingerprint) {
            Write-Fail "Working tree was mutated by unit tests. Tests must remain side-effect-free."
            & git status --porcelain
            throw "Gate 3 Failed: Unit tests produced working tree side effects."
        }

        $GateResults["gate3_unit_tests"] = "pass"
        Write-Pass "Unit test suite passed with clean working tree." $StepTimer
    } finally {
        Exit-CiGate
    }

    # -------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------
    Write-CiGateSummary $GateResults

    $TotalElapsed = [math]::Round($TotalTimer.Elapsed.TotalSeconds, 2)
    Write-Host "`n====================================================" -ForegroundColor Green
    Write-Host " All Local CI Verification Checks PASSED (${TotalElapsed}s)" -ForegroundColor Green
    Write-Host "====================================================" -ForegroundColor Cyan
} catch {
    Exit-CiGate
    Write-Fail $_.Exception.Message
    Write-CiGateSummary $GateResults
    Write-Host "`n====================================================" -ForegroundColor Red
    Write-Host " Local CI Verification FAILED" -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    exit 1
} finally {
    Pop-Location
}
