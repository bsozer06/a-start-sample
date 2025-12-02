Param(
  [string]$NetworkName = "pgrouter-demo",
  [string]$ContainerName = "my-custom-db",
  [string]$DbName = "postgres",
  [string]$PostgresPassword = "mysecretpassword",
  [int]$HostPort = 5435,
  [string]$PostgisImage = "postgis/postgis:15-4.1",
  [string]$Osm2pgsqlImage = "iboates/osm2pgsql:latest",
  [string]$Workdir = (Get-Location).Path,
  [string]$PbfFile = "turkey-latest.osm.pbf",
  [string]$BBox, # format: minlon,minlat,maxlon,maxlat
  [switch]$SkipImport = $false,
  [switch]$SkipRoads = $false
)

$ErrorActionPreference = "Stop"

function Fail($msg) { Write-Error $msg; exit 1 }

# Verify Docker CLI
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Fail "Docker CLI not found. Please install/launch Docker Desktop and retry."
}

Write-Host "Ensuring Docker network '$NetworkName' exists ..."
$netExists = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $NetworkName }
if (-not $netExists) {
  docker network create $NetworkName | Out-Null
}

Write-Host "Starting PostGIS container '$ContainerName' on network '$NetworkName' ..."
$exists = docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq $ContainerName }
if ($exists) {
  $running = docker ps --format "{{.Names}}" | Where-Object { $_ -eq $ContainerName }
  if (-not $running) { docker start $ContainerName | Out-Null }
  # Ensure correct network connection only if not already attached
  $netJson = docker inspect -f "{{json .NetworkSettings.Networks}}" $ContainerName 2>$null
  try { $netObj = $netJson | ConvertFrom-Json } catch { $netObj = $null }
  $attached = $false
  if ($netObj -ne $null) {
    $attached = $netObj.PSObject.Properties.Name -contains $NetworkName
  }
  if (-not $attached) {
    docker network connect $NetworkName $ContainerName | Out-Null
  }
} else {
  docker run -d --name $ContainerName --network $NetworkName `
    -e POSTGRES_PASSWORD=$PostgresPassword -e POSTGRES_DB=$DbName `
    -p $HostPort:5432 $PostgisImage | Out-Null
}

Write-Host "Waiting for PostgreSQL readiness ..."
$maxAttempts = 60
for ($i=0; $i -lt $maxAttempts; $i++) {
  $ready = docker exec $ContainerName pg_isready -U postgres 2>&1
  if ($LASTEXITCODE -eq 0) { break }
  Start-Sleep -Seconds 2
}
if ($i -ge $maxAttempts) { Fail "PostgreSQL did not become ready in time." }

Write-Host "Enabling extensions (postgis, hstore, pgrouting) ..."
$oldErrPref = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$extOut1 = docker exec $ContainerName psql -U postgres -d $DbName -c "CREATE EXTENSION IF NOT EXISTS postgis;"
if ($LASTEXITCODE -ne 0) { Fail "Failed to enable postgis: $extOut1" }
$extOut2 = docker exec $ContainerName psql -U postgres -d $DbName -c "CREATE EXTENSION IF NOT EXISTS hstore;"
if ($LASTEXITCODE -ne 0) { Fail "Failed to enable hstore: $extOut2" }
$extOut3 = docker exec $ContainerName psql -U postgres -d $DbName -c "CREATE EXTENSION IF NOT EXISTS pgrouting;"
if ($LASTEXITCODE -ne 0) { Fail "Failed to enable pgrouting: $extOut3" }
$ErrorActionPreference = $oldErrPref

# Set default bbox for Ankara if not provided
if (-not $BBox) {
  $BBox = "32.52,39.77,33.04,40.07" # Ankara bounding box (minlon,minlat,maxlon,maxlat)
  Write-Host "No BBox provided. Using default Ankara bbox: $BBox"
}

if (-not $SkipImport) {
  if ([System.IO.Path]::IsPathRooted($PbfFile)) {
    $pbfPath = $PbfFile
    $pbfName = [System.IO.Path]::GetFileName($PbfFile)
  } else {
    $pbfPath = Join-Path $Workdir $PbfFile
    $pbfName = $PbfFile
  }
  if (-not (Test-Path $pbfPath)) {
    Fail "PBF file not found at '$pbfPath'. Download it first or pass -PbfFile path."
  }
  Write-Host "Importing OSM data from '$pbfPath' ..."
  $volume = "$($Workdir):/data"
  $dockerArgs = @('run','--rm','--network', $NetworkName,'-v', "$volume",'-e',"PGPASSWORD=$PostgresPassword", $Osm2pgsqlImage,
    'osm2pgsql','-d', $DbName,'-U','postgres','--host', $ContainerName,'--port','5432','--create','--slim','--hstore','--latlong')
  if ($BBox) {
    Write-Host "Using bounding box: $BBox"
    $dockerArgs += @('--bbox', $BBox)
  }
  $dockerArgs += @("/data/$pbfName")
  if ($pbfPath -ne "$($Workdir)\$pbfName") {
    # If the file is outside the workdir, copy it in
    Copy-Item $pbfPath "$($Workdir)\$pbfName" -Force
  }
  $oldErrPref = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $imp = & docker @dockerArgs 2>&1
  $ErrorActionPreference = $oldErrPref
  if ($LASTEXITCODE -ne 0) { Fail "osm2pgsql import failed: $imp" }
}

if (-not $SkipRoads) {
  Write-Host "Creating roads table ..."
  # Check if /data exists in the container
  $dataExists = docker exec $ContainerName sh -c "[ -d /data ] && echo exists || echo missing" 2>$null
  if ($dataExists -eq "missing") {
    Write-Host "/data directory missing in container, attempting to create ..."
    $mkdirOut = docker exec $ContainerName sh -c "mkdir -p /data" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "Warning: Could not create /data directory: $mkdirOut" }
  }
  $roadsLocal = Join-Path $Workdir "scripts\roads.sql"
  if (-not (Test-Path $roadsLocal)) { Fail "roads.sql not found at '$roadsLocal'" }
  docker cp $roadsLocal "$($ContainerName):/data/roads.sql"
  $roadsOut = docker exec $ContainerName psql -U postgres -d $DbName -f /data/roads.sql 2>&1
  if ($LASTEXITCODE -ne 0) { Fail "Applying roads.sql failed: $roadsOut" }
}

Write-Host "Verifying roads count ..."
$cntOut = docker exec $ContainerName psql -U postgres -d $DbName -c "SELECT COUNT(*) FROM roads;" 2>&1
Write-Host $cntOut

Write-Host "Done. Update your .env if needed:"
Write-Host "PGHOST=localhost"; Write-Host "PGPORT=$HostPort"; Write-Host "PGUSER=postgres"; Write-Host "PGPASSWORD=$PostgresPassword"; Write-Host "PGDATABASE=$DbName";
