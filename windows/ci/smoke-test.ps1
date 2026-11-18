[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [int]$PgPort,

    [Parameter(Mandatory = $true)]
    [int]$PostgreSqlMajor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tempDir = Join-Path $env:RUNNER_TEMP "pg_profile-$PostgreSqlMajor-$([guid]::NewGuid())"
$data = Join-Path $tempDir 'data'
$log = Join-Path $tempDir 'postgres.log'
New-Item -ItemType Directory -Path $tempDir | Out-Null
$psqlArgs = @('-h', '127.0.0.1', '-p', $PgPort, '-U', 'postgres', '-X', '-v', 'ON_ERROR_STOP=1')
$smokeSql = @'
CREATE EXTENSION IF NOT EXISTS plpgsql;
CREATE EXTENSION dblink;
CREATE EXTENSION pg_profile;

DO $$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_profile') IS DISTINCT FROM '4.16' THEN
        RAISE EXCEPTION 'Expected pg_profile version 4.16';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.show_servers() WHERE server_name = 'local' AND enabled) THEN
        RAISE EXCEPTION 'pg_profile.show_servers() did not return the enabled local server';
    END IF;
END;
$$;
SELECT server_name, enabled FROM public.show_servers();
'@

try {
    & "$PgRoot/bin/initdb.exe" -D $data -U postgres -A trust --encoding=UTF8 --no-locale
    if ($LASTEXITCODE -ne 0) { throw 'initdb failed' }

    & "$PgRoot/bin/pg_ctl.exe" -D $data -l $log -o "-p $PgPort -c listen_addresses=127.0.0.1" -w start
    if ($LASTEXITCODE -ne 0) { throw 'Temporary PostgreSQL startup failed' }

    & "$PgRoot/bin/psql.exe" @psqlArgs -d postgres -c 'CREATE DATABASE pg_profile_smoke;'
    if ($LASTEXITCODE -ne 0) { throw 'Could not create disposable smoke database' }

    $smokeSql | & "$PgRoot/bin/psql.exe" @psqlArgs -d pg_profile_smoke -f -
    if ($LASTEXITCODE -ne 0) { throw 'pg_profile SQL smoke failed' }
    Write-Host "PASS: pg_profile PG$PostgreSqlMajor functional smoke test"
}
finally {
    if (Test-Path $log) { Get-Content $log -Tail 80 }
    if (Test-Path (Join-Path $data 'postmaster.pid')) {
        & "$PgRoot/bin/pg_ctl.exe" -D $data -m immediate -w stop
    }
    Remove-Item $tempDir -Recurse -Force
}
