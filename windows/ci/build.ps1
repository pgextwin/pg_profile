[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifest = Get-Content (Join-Path $PSScriptRoot '../../config/extension.json') -Raw | ConvertFrom-Json
$actualCommit = (& git -C $UpstreamDir rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -cne $manifest.upstream.commit) {
    throw "Upstream commit '$actualCommit' differs from manifest '$($manifest.upstream.commit)'."
}

# GNU sed reads upstream scripts and assets with their original LF line endings.
& git -C $UpstreamDir -c core.autocrlf=false checkout-index --force --all
if ($LASTEXITCODE -ne 0) { throw 'Could not restore upstream Makefile inputs.' }

$bash = 'C:\msys64\usr\bin\bash.exe'
$generate = @'
set -euo pipefail
export PATH="/usr/bin:$PATH"
if ! command -v make >/dev/null; then
    pacman --sync --refresh --needed --noconfirm --noprogressbar make
fi

# The migration rule appends to its output, so recreate it on every build.
rm -f pg_profile--4.15--4.16.sql
# These generation targets need no PostgreSQL build rules or compiler.
make USE_PGXS=1 PGXS=/dev/null PG_CONFIG=true pg_profile.control pg_profile--4.16.sql pg_profile--4.15--4.16.sql
# GNU sed doubles backslashes in the psql guards. Match the upstream release guards.
sed -i '1s/\\\\/\\/g' pg_profile--4.16.sql pg_profile--4.15--4.16.sql
'@

Push-Location $UpstreamDir
try {
    & $bash --noprofile --norc -c $generate
    if ($LASTEXITCODE -ne 0) { throw 'Upstream pg_profile Makefile generation failed.' }
}
finally {
    Pop-Location
}

Write-Host "Generated pg_profile control, install SQL, and migration SQL for $PgRoot"
