param(
    [string]$LogoPath,
    [string]$LogoSha256,
    [switch]$NoSync
)
$ErrorActionPreference = 'Stop'
$commandRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $commandRoot
try {
    if (-not $LogoPath -and -not $LogoSha256) {
        $brandManifest = Get-Content -LiteralPath assets/brand/manifest.json -Raw | ConvertFrom-Json
        $brandAsset = $brandManifest.variants.($brandManifest.default)
        $LogoPath = Join-Path $commandRoot ('assets/brand/' + $brandAsset.file)
        $LogoSha256 = $brandAsset.sha256
    }
    if (-not $NoSync) {
        python -m command.cli cycle --limit 1
        if ($LASTEXITCODE -ne 0) { throw 'Falha no ciclo; conferir notificações locais.' }
        return
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
