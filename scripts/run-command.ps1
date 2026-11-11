param(
    [Parameter(Mandatory=$true)][string]$LogoPath,
    [Parameter(Mandatory=$true)][string]$LogoSha256,
    [switch]$NoSync
)
$ErrorActionPreference = 'Stop'
$commandRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $commandRoot
try {
    if (-not $NoSync) {
        python -m command.cli sync
        if ($LASTEXITCODE -ne 0) { throw 'Falha na leitura; conferir notificações locais.' }
    }
    # Limited local preparation only. Never calls a publisher or exports approved SQL.
    for ($iteration = 0; $iteration -lt 20; $iteration++) {
        python -m command.cli run --logo $LogoPath --logo-sha256 $LogoSha256
        if ($LASTEXITCODE -ne 0) { throw 'Falha na preparação; conferir notificações locais.' }
    }
    python -m command.cli status
} finally {
    Pop-Location
}
