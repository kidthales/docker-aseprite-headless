<#
.SYNOPSIS
    Unit and negative-path integration tests for scripts/ci-local.ps1.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$CiLocalScript = Join-Path $RepoRoot "scripts/ci-local.ps1"

if (-not (Test-Path -LiteralPath $CiLocalScript -PathType Leaf)) {
    throw "Missing target script: $CiLocalScript"
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

# -------------------------------------------------------------------------
# 1. Leak-pattern regex positive, boundary, and negative assertions
# -------------------------------------------------------------------------
$ScriptContent = Get-Content -LiteralPath $CiLocalScript -Raw
$TrackedMatch = [regex]::Match($ScriptContent, "\`$TrackedLeakPattern\s*=\s*'([^']+)'")
$UntrackedMatch = [regex]::Match($ScriptContent, "\`$UntrackedLeakPattern\s*=\s*'([^']+)'")
Assert-True $TrackedMatch.Success "Could not extract `$TrackedLeakPattern from scripts/ci-local.ps1"
Assert-True $UntrackedMatch.Success "Could not extract `$UntrackedLeakPattern from scripts/ci-local.ps1"

$TrackedLeakPattern = $TrackedMatch.Groups[1].Value
$UntrackedLeakPattern = $UntrackedMatch.Groups[1].Value

$MustMatchBoth = @(
    ".agents/rules/test.md",
    ".agent/scratch.md",
    "nested/.agents/foo.md",
    ".gemini/settings.json",
    ".ai/context.md",
    ".cursor/rules",
    ".claude/settings.json",
    "scratch/debug.log",
    "sub/scratch/tmp.txt",
    "docs/learnings/note.md",
    "AGENTS.md",
    "nested/AGENTS.md",
    "GEMINI.md",
    "CLAUDE.md"
)
foreach ($sample in $MustMatchBoth) {
    Assert-True ($sample -match $TrackedLeakPattern) "TrackedLeakPattern must match '$sample'"
    Assert-True ($sample -match $UntrackedLeakPattern) "UntrackedLeakPattern must match '$sample'"
}

$MustMatchTrackedOnly = @(
    ".ci-local/receipt.json",
    ".ci-local/audit-pr-71-a191b16.md",
    "nested/.ci-local/receipt.json"
)
foreach ($sample in $MustMatchTrackedOnly) {
    Assert-True ($sample -match $TrackedLeakPattern) "TrackedLeakPattern must match '$sample'"
    Assert-True ($sample -notmatch $UntrackedLeakPattern) "UntrackedLeakPattern must allow local '$sample'"
}

$MustMatchNeither = @(
    "scripts/ci-local.ps1",
    "tests/ci_local_test.ps1",
    "README.md",
    "myAGENTS.md",
    "foo.agents/bar.txt",
    "docs/learning/note.md",
    "ci-local/note.txt",
    "tests/AGENTS_helper.sh",
    ".github/workflows/lint.yml"
)
foreach ($sample in $MustMatchNeither) {
    Assert-True ($sample -notmatch $TrackedLeakPattern) "TrackedLeakPattern falsely matched '$sample'"
    Assert-True ($sample -notmatch $UntrackedLeakPattern) "UntrackedLeakPattern falsely matched '$sample'"
}

# -------------------------------------------------------------------------
# 2. Isolated end-to-end execution tests (positive & negative paths)
# -------------------------------------------------------------------------
$IsWin = ($env:OS -eq "Windows_NT")
$RealGit = (Get-Command git -ErrorAction Stop).Source
$RealPwsh = (Get-Command pwsh -ErrorAction Stop).Source
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ci-local-test-" + [System.Guid]::NewGuid().ToString("N"))

function New-MockToolchain {
    param(
        [string]$BinDir,
        [bool]$IncludeDocker = $true,
        [bool]$IncludePwsh = $true
    )
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null

    if ($IsWin) {
        Set-Content -LiteralPath (Join-Path $BinDir "git.cmd") -Value "@`"$RealGit`" %*" -Encoding Ascii
        if ($IncludeDocker) {
            Set-Content -LiteralPath (Join-Path $BinDir "docker.cmd") -Value "@echo off`r`nexit /b 0" -Encoding Ascii
        }
        if ($IncludePwsh) {
            Set-Content -LiteralPath (Join-Path $BinDir "pwsh.cmd") -Value "@echo off`r`nexit /b 0" -Encoding Ascii
        }
        $taskScript = @'
@echo off
if "%1"=="lint" goto do_lint
if "%1"=="test:unit" goto do_unit
if "%1"=="test:pwsh" goto do_pwsh
exit /b 0
:do_lint
if defined MOCK_FAIL_LINT exit /b %MOCK_FAIL_LINT%
exit /b 0
:do_unit
if defined MOCK_CREATE_FILE echo side-effect> "%MOCK_CREATE_FILE%"
if defined MOCK_APPEND_FILE echo extra-line>> "%MOCK_APPEND_FILE%"
if defined MOCK_FAIL_UNIT exit /b %MOCK_FAIL_UNIT%
exit /b 0
:do_pwsh
if defined MOCK_FAIL_PWSH exit /b %MOCK_FAIL_PWSH%
exit /b 0
'@ -replace "\r?\n", "`r`n"
        Set-Content -LiteralPath (Join-Path $BinDir "task.cmd") -Value $taskScript -NoNewline -Encoding Ascii
    } else {
        $gitSh = "#!/bin/sh`nexec '$RealGit' `"`$@`""
        $gitPath = Join-Path $BinDir "git"
        Set-Content -LiteralPath $gitPath -Value $gitSh -NoNewline
        & chmod +x $gitPath

        if ($IncludeDocker) {
            $dockerPath = Join-Path $BinDir "docker"
            Set-Content -LiteralPath $dockerPath -Value "#!/bin/sh`nexit 0`n" -NoNewline
            & chmod +x $dockerPath
        }

        if ($IncludePwsh) {
            $pwshPath = Join-Path $BinDir "pwsh"
            Set-Content -LiteralPath $pwshPath -Value "#!/bin/sh`nexit 0`n" -NoNewline
            & chmod +x $pwshPath
        }

        $taskSh = @'
#!/bin/sh
case "${1:-}" in
    lint)
        if [ -n "${MOCK_FAIL_LINT:-}" ]; then exit "$MOCK_FAIL_LINT"; fi
        exit 0
        ;;
    test:unit)
        if [ -n "${MOCK_CREATE_FILE:-}" ]; then printf 'side-effect\n' > "$MOCK_CREATE_FILE"; fi
        if [ -n "${MOCK_APPEND_FILE:-}" ]; then printf 'extra-line\n' >> "$MOCK_APPEND_FILE"; fi
        if [ -n "${MOCK_FAIL_UNIT:-}" ]; then exit "$MOCK_FAIL_UNIT"; fi
        exit 0
        ;;
    test:pwsh)
        if [ -n "${MOCK_FAIL_PWSH:-}" ]; then exit "$MOCK_FAIL_PWSH"; fi
        exit 0
        ;;
esac
exit 0
'@
        $taskPath = Join-Path $BinDir "task"
        Set-Content -LiteralPath $taskPath -Value $taskSh -NoNewline
        & chmod +x $taskPath
    }
}

function Invoke-CiLocalInSandbox {
    param(
        [string]$RepoDir,
        [string]$BinDir,
        [hashtable]$ExtraEnv = @{}
    )
    $origPath = $env:PATH
    $origGhActions = $env:GITHUB_ACTIONS
    $savedExtra = @{}
    foreach ($k in $ExtraEnv.Keys) {
        $savedExtra[$k] = [Environment]::GetEnvironmentVariable($k)
    }

    try {
        $sandboxPath = if ($IsWin) { "$BinDir;$env:SystemRoot\System32" } else { $BinDir }
        $env:PATH = $sandboxPath
        $env:GITHUB_ACTIONS = ""
        foreach ($k in $ExtraEnv.Keys) {
            [Environment]::SetEnvironmentVariable($k, $ExtraEnv[$k])
        }

        $runner = Join-Path $RepoDir "scripts/ci-local.ps1"
        $env:CI_SANDBOX_PATH = $sandboxPath
        $env:CI_SANDBOX_RUNNER = $runner
        $output = (& $RealPwsh -NoProfile -Command '$env:PATH = $env:CI_SANDBOX_PATH; & $env:CI_SANDBOX_RUNNER; exit $LASTEXITCODE' 2>&1 | Out-String)
        return @{
            ExitCode = $LASTEXITCODE
            Output   = $output
        }
    } finally {
        $env:PATH = $origPath
        $env:GITHUB_ACTIONS = $origGhActions
        $env:CI_SANDBOX_PATH = $null
        $env:CI_SANDBOX_RUNNER = $null
        foreach ($k in $ExtraEnv.Keys) {
            [Environment]::SetEnvironmentVariable($k, $savedExtra[$k])
        }
    }
}

try {
    $BinAll = Join-Path $TempRoot "bin-all"
    $BinNoDocker = Join-Path $TempRoot "bin-no-docker"
    $BinNoPwsh = Join-Path $TempRoot "bin-no-pwsh"
    New-MockToolchain -BinDir $BinAll -IncludeDocker $true -IncludePwsh $true
    New-MockToolchain -BinDir $BinNoDocker -IncludeDocker $false -IncludePwsh $true
    New-MockToolchain -BinDir $BinNoPwsh -IncludeDocker $true -IncludePwsh $false

    $SandboxRepo = Join-Path $TempRoot "repo"
    New-Item -ItemType Directory -Path (Join-Path $SandboxRepo "scripts") -Force | Out-Null
    Copy-Item -LiteralPath $CiLocalScript -Destination (Join-Path $SandboxRepo "scripts/ci-local.ps1")
    Set-Content -LiteralPath (Join-Path $SandboxRepo ".gitignore") -Value ".ci-local/`n"
    Set-Content -LiteralPath (Join-Path $SandboxRepo "tracked.txt") -Value "initial`n"

    & $RealGit -C $SandboxRepo init -q
    & $RealGit -C $SandboxRepo config user.email "test@example.com"
    & $RealGit -C $SandboxRepo config user.name "Test Runner"
    & $RealGit -C $SandboxRepo add .
    & $RealGit -C $SandboxRepo commit -q -m "init"

    # Case 1 (Positive): clean tree + valid scripts pass all gates
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinAll
    Assert-True ($res.ExitCode -eq 0) "Expected clean sandbox to pass, got exit $($res.ExitCode): $($res.Output)"
    Assert-True ($res.Output -match "\[gate0_agent_leaks: PASS\]") "Expected gate0 PASS"
    Assert-True ($res.Output -match "\[gate1_pwsh_ast: PASS\]") "Expected gate1 PASS"
    Assert-True ($res.Output -match "\[gate2_task_lint: PASS\]") "Expected gate2 PASS"
    Assert-True ($res.Output -match "\[gate3_unit_tests: PASS\]") "Expected gate3 PASS"

    # Case 2 (Boundary): untracked .ci-local/ receipt is permitted
    New-Item -ItemType Directory -Path (Join-Path $SandboxRepo ".ci-local") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $SandboxRepo ".ci-local/audit.md") -Value "ok"
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinAll
    Assert-True ($res.ExitCode -eq 0) "Expected untracked .ci-local/ to pass, got exit $($res.ExitCode): $($res.Output)"

    # Case 3 (Negative): untracked AGENTS.md fails Gate 0
    $leakAgent = Join-Path $SandboxRepo "AGENTS.md"
    Set-Content -LiteralPath $leakAgent -Value "leak"
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinAll
    Assert-True ($res.ExitCode -ne 0) "Expected untracked AGENTS.md to fail Gate 0"
    Assert-True ($res.Output -match "\[gate0_agent_leaks: FAIL\]") "Expected gate0 FAIL for untracked AGENTS.md"
    Remove-Item -LiteralPath $leakAgent

    # Case 4 (Negative): force-tracked .ci-local/receipt.json fails Gate 0
    $receipt = Join-Path $SandboxRepo ".ci-local/receipt.json"
    Set-Content -LiteralPath $receipt -Value "{}"
    & $RealGit -C $SandboxRepo add -f ".ci-local/receipt.json"
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinAll
    Assert-True ($res.ExitCode -ne 0) "Expected tracked .ci-local/receipt.json to fail Gate 0"
    Assert-True ($res.Output -match "\[gate0_agent_leaks: FAIL\]") "Expected gate0 FAIL for tracked receipt"
    & $RealGit -C $SandboxRepo rm -qf ".ci-local/receipt.json"
    Remove-Item -LiteralPath (Join-Path $SandboxRepo ".ci-local") -Recurse -Force

    # Case 5 (Negative): invalid PowerShell syntax in untracked .ps1 fails Gate 1
    $brokenPs1 = Join-Path $SandboxRepo "broken.ps1"
    Set-Content -LiteralPath $brokenPs1 -Value "function Broken {`n"
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinAll
    Assert-True ($res.ExitCode -ne 0) "Expected invalid PowerShell syntax to fail Gate 1"
    Assert-True ($res.Output -match "\[gate1_pwsh_ast: FAIL\]") "Expected gate1 FAIL for syntax error"
    Remove-Item -LiteralPath $brokenPs1

    # Case 6 (Negative): missing docker prerequisite fails upfront
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinNoDocker
    Assert-True ($res.ExitCode -ne 0) "Expected missing docker tool to fail"
    Assert-True ($res.Output -match "missing 'docker'") "Expected missing 'docker' error message"

    # Case 7 (Negative): missing pwsh prerequisite fails upfront
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinNoPwsh
    Assert-True ($res.ExitCode -ne 0) "Expected missing pwsh tool to fail"
    Assert-True ($res.Output -match "missing 'pwsh'") "Expected missing 'pwsh' error message"

    # Case 8 (Negative): task lint failure fails Gate 2
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinAll -ExtraEnv @{ MOCK_FAIL_LINT = "2" }
    Assert-True ($res.ExitCode -ne 0) "Expected task lint failure to fail Gate 2"
    Assert-True ($res.Output -match "\[gate2_task_lint: FAIL\]") "Expected gate2 FAIL"

    # Case 9 (Negative): task test:unit failure fails Gate 3
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinAll -ExtraEnv @{ MOCK_FAIL_UNIT = "3" }
    Assert-True ($res.ExitCode -ne 0) "Expected task test:unit failure to fail Gate 3"
    Assert-True ($res.Output -match "\[gate3_unit_tests: FAIL\]") "Expected gate3 FAIL"

    # Case 10 (Negative): task test:pwsh failure fails Gate 3
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinAll -ExtraEnv @{ MOCK_FAIL_PWSH = "4" }
    Assert-True ($res.ExitCode -ne 0) "Expected task test:pwsh failure to fail Gate 3"
    Assert-True ($res.Output -match "\[gate3_unit_tests: FAIL\]") "Expected gate3 FAIL on test:pwsh"

    # Case 11 (Negative): task test:unit creating an untracked file fails Gate 3
    $createdFile = Join-Path $SandboxRepo "created-by-test.txt"
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinAll -ExtraEnv @{ MOCK_CREATE_FILE = $createdFile }
    Assert-True ($res.ExitCode -ne 0) "Expected side-effect file creation to fail Gate 3"
    Assert-True ($res.Output -match "\[gate3_unit_tests: FAIL\]") "Expected gate3 FAIL on created file"
    Remove-Item -LiteralPath $createdFile -Force

    # Case 12 (Negative): task test:unit mutating an ALREADY-dirty file fails Gate 3
    $trackedFile = Join-Path $SandboxRepo "tracked.txt"
    Add-Content -LiteralPath $trackedFile -Value "pre-existing-dirty-edit"
    $res = Invoke-CiLocalInSandbox -RepoDir $SandboxRepo -BinDir $BinAll -ExtraEnv @{ MOCK_APPEND_FILE = $trackedFile }
    Assert-True ($res.ExitCode -ne 0) "Expected in-place mutation of already-dirty file to fail Gate 3"
    Assert-True ($res.Output -match "\[gate3_unit_tests: FAIL\]") "Expected gate3 FAIL on dirty file content mutation"
    & $RealGit -C $SandboxRepo checkout -- tracked.txt

    Write-Host "PASS: ci-local.ps1 regex, boundary, and negative-path tests passed (12/12 cases)"
} finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
