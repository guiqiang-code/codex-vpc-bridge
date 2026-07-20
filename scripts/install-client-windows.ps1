[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Jump,

    [Parameter(Mandatory = $true)]
    [string]$Target,

    [string]$IdentityFile = (Join-Path $HOME ".ssh\id_rsa")
)

$ErrorActionPreference = "Stop"

function Parse-SshDestination {
    param(
        [string]$Label,
        [string]$Value
    )

    if ($Value -notmatch '^([^@\s]+)@([^@\s]+)$') {
        throw "$Label must use the form user@host: $Value"
    }

    [PSCustomObject]@{
        User = $Matches[1]
        Host = $Matches[2]
    }
}

function Remove-ManagedBlock {
    param(
        [string]$Path,
        [string]$StartMarker,
        [string]$EndMarker
    )

    $lines = if (Test-Path -LiteralPath $Path) {
        @(Get-Content -LiteralPath $Path)
    } else {
        @()
    }

    $result = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $lines) {
        if ($line -eq $StartMarker) {
            $inside = $true
            continue
        }
        if ($line -eq $EndMarker) {
            $inside = $false
            continue
        }
        if (-not $inside) {
            $result.Add($line)
        }
    }

    return @($result)
}

function Write-ManagedBlock {
    param(
        [string]$Path,
        [string]$StartMarker,
        [string]$EndMarker,
        [string]$Block,
        [switch]$Prepend
    )

    $clean = @(Remove-ManagedBlock -Path $Path -StartMarker $StartMarker -EndMarker $EndMarker)
    $blockLines = @($Block -split "`r?`n")
    $combined = New-Object System.Collections.Generic.List[string]

    if ($Prepend) {
        foreach ($line in $blockLines) { $combined.Add($line) }
        if ($clean.Count -gt 0) { $combined.Add("") }
        foreach ($line in $clean) { $combined.Add($line) }
    } else {
        foreach ($line in $clean) { $combined.Add($line) }
        if ($clean.Count -gt 0) { $combined.Add("") }
        foreach ($line in $blockLines) { $combined.Add($line) }
    }

    $text = (($combined -join [Environment]::NewLine).TrimEnd()) + [Environment]::NewLine
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $text, $utf8NoBom)
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    throw "OpenSSH Client is required. Install the Windows OpenSSH Client feature first."
}

$jumpDestination = Parse-SshDestination -Label "Jump" -Value $Jump
$targetDestination = Parse-SshDestination -Label "Target" -Value $Target

if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) {
    throw "Private key not found: $IdentityFile"
}
$identityPath = (Resolve-Path -LiteralPath $IdentityFile).Path.Replace('\', '/')

$sshDirectory = Join-Path $HOME ".ssh"
$sshConfig = Join-Path $sshDirectory "config"
$profilePath = $PROFILE.CurrentUserAllHosts
if ([string]::IsNullOrWhiteSpace($profilePath)) {
    $profilePath = $PROFILE
}

New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
if (-not (Test-Path -LiteralPath $sshConfig)) {
    New-Item -ItemType File -Path $sshConfig -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

$sshStart = "# >>> codex-vpc-bridge client ssh >>>"
$sshEnd = "# <<< codex-vpc-bridge client ssh <<<"
$profileStart = "# >>> codex-vpc-bridge tmux shortcuts >>>"
$profileEnd = "# <<< codex-vpc-bridge tmux shortcuts <<<"

$sshBlock = @"
$sshStart
Host jump
    HostName $($jumpDestination.Host)
    User $($jumpDestination.User)
    IdentityFile "$identityPath"
    IdentitiesOnly yes
    ForwardAgent yes

Host target
    HostName $($targetDestination.Host)
    User $($targetDestination.User)
    IdentityFile "$identityPath"
    IdentitiesOnly yes
    ProxyJump jump
$sshEnd
"@

$profileBlock = @'
# >>> codex-vpc-bridge tmux shortcuts >>>
Remove-Item Alias:l, Alias:a, Alias:k, Alias:n -Force -ErrorAction SilentlyContinue

function global:Get-CodexVpcBridgeTmuxSessionName {
    param([string]$Number)

    if ($Number -notmatch '^[1-9][0-9]*$') {
        throw 'Session number must be a positive integer.'
    }

    $sessions = @(& ssh target 'tmux list-sessions -F "#{session_name}"')
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to list remote tmux sessions.'
    }
    $sessions = @($sessions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $index = [int]$Number - 1
    if ($index -ge $sessions.Count) {
        throw "Session number $Number does not exist. Run l to see available sessions."
    }

    $session = [string]$sessions[$index]
    if ($session -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Unsupported tmux session name: $session"
    }
    return $session
}

function global:l {
    $sessions = @(& ssh target 'tmux list-sessions')
    if ($LASTEXITCODE -ne 0) {
        return
    }

    for ($index = 0; $index -lt $sessions.Count; $index++) {
        "{0}. {1}" -f ($index + 1), $sessions[$index]
    }
}

function global:a {
    param([string]$Number)

    try {
        $session = Get-CodexVpcBridgeTmuxSessionName -Number $Number
    } catch {
        Write-Error $_.Exception.Message
        return
    }

    $previousTerm = $env:TERM
    try {
        $env:TERM = 'xterm-256color'
        & ssh -t target "tmux attach-session -t $session"
    } finally {
        $env:TERM = $previousTerm
    }
}

function global:k {
    param([string]$Number)

    try {
        $session = Get-CodexVpcBridgeTmuxSessionName -Number $Number
    } catch {
        Write-Error $_.Exception.Message
        return
    }

    & ssh target "tmux kill-session -t $session"
    if ($LASTEXITCODE -eq 0) {
        l
    }
}

function global:n {
    param([string]$Name)

    if ($Name -notmatch '^[A-Za-z0-9_-]+$') {
        Write-Error 'Usage: n <session-name>; use letters, numbers, underscores, or hyphens.'
        return
    }

    $previousTerm = $env:TERM
    try {
        $env:TERM = 'xterm-256color'
        & ssh -t target "tmux new-session -s $Name"
    } finally {
        $env:TERM = $previousTerm
    }
}
# <<< codex-vpc-bridge tmux shortcuts <<<
'@

Write-ManagedBlock -Path $sshConfig -StartMarker $sshStart -EndMarker $sshEnd -Block $sshBlock -Prepend
Write-ManagedBlock -Path $profilePath -StartMarker $profileStart -EndMarker $profileEnd -Block $profileBlock

Write-Host "Installed client SSH hosts in $sshConfig"
Write-Host "Installed remote tmux shortcuts in $profilePath"
Write-Host "Open a new PowerShell window, or run: . `"$profilePath`""
