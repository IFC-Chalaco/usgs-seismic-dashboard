[CmdletBinding()]
param(
    [string]$MapUrl = "https://earthquake.usgs.gov/earthquakes/map/?extent=14.64737,-144.22852&extent=56.31654,-45.79102&range=week&magnitude=all",

    [string]$OutputDirectory,

    [string]$CountryBoundaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDirectory = if ($PSCommandPath) { Split-Path -Path $PSCommandPath -Parent } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path -Path $scriptDirectory -ChildPath "exports"
}

$repositoryRoot = Split-Path -Path $scriptDirectory -Parent
$scraperPath = Join-Path -Path $repositoryRoot -ChildPath "usgs-earthquake-scraper.ps1"

if (-not (Test-Path -Path $scraperPath)) {
    throw "Unable to find the scraper at $scraperPath."
}

if ([string]::IsNullOrWhiteSpace($CountryBoundaryPath)) {
    $CountryBoundaryPath = Join-Path -Path $repositoryRoot -ChildPath "data\ne_110m_admin_0_countries.geojson"
}

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force

$curatedCsvPath = Join-Path -Path $OutputDirectory -ChildPath "earthquakes_live_curated.csv"
$curatedJsonPath = Join-Path -Path $OutputDirectory -ChildPath "earthquakes_live_curated.json"
$geoJsonPath = Join-Path -Path $OutputDirectory -ChildPath "earthquakes_live.geojson"
$metadataPath = Join-Path -Path $OutputDirectory -ChildPath "pipeline_meta.json"

$records = @(
    & $scraperPath `
        -MapUrl $MapUrl `
        -OutputPath $curatedCsvPath `
        -OutputFormat Csv `
        -CountryBoundaryPath $CountryBoundaryPath `
        -PassThru
)

$generatedAtUtc = [datetimeoffset]::UtcNow
$curatedPayload = [ordered]@{
    generated_at_utc = $generatedAtUtc.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
    source_map_url = $MapUrl
    total_events = @($records).Count
    events = @($records)
}

$curatedPayload | ConvertTo-Json -Depth 8 | Set-Content -Path $curatedJsonPath -Encoding UTF8

$geoJsonFeatures = foreach ($record in @($records)) {
    $properties = [ordered]@{}
    foreach ($property in $record.PSObject.Properties) {
        if ($property.Name -in @("latitude", "longitude")) {
            continue
        }

        $properties[$property.Name] = $property.Value
    }

    $longitude = if ($null -ne $record.longitude -and "$($record.longitude)" -ne "") { [double]$record.longitude } else { $null }
    $latitude = if ($null -ne $record.latitude -and "$($record.latitude)" -ne "") { [double]$record.latitude } else { $null }
    $depth = if ($null -ne $record.depth_km_raw -and "$($record.depth_km_raw)" -ne "") { [double]$record.depth_km_raw } else { $null }

    [ordered]@{
        type = "Feature"
        id = $record.id
        geometry = [ordered]@{
            type = "Point"
            coordinates = @($longitude, $latitude, $depth)
        }
        properties = $properties
    }
}

$geoJsonPayload = [ordered]@{
    type = "FeatureCollection"
    generated_at_utc = $generatedAtUtc.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
    source_map_url = $MapUrl
    features = @($geoJsonFeatures)
}

$geoJsonPayload | ConvertTo-Json -Depth 10 | Set-Content -Path $geoJsonPath -Encoding UTF8

$timeValuesUtc = @($records | Where-Object { $_.time_utc } | Select-Object -ExpandProperty time_utc)
$timeValuesEt = @($records | Where-Object { $_.time_et } | Select-Object -ExpandProperty time_et)

$metadata = [ordered]@{
    generated_at_utc = $generatedAtUtc.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
    total_events = @($records).Count
    source_map_url = $MapUrl
    stale_after_minutes = 30
    earliest_event_time_utc = if ($timeValuesUtc.Count -gt 0) { ($timeValuesUtc | Sort-Object | Select-Object -First 1) } else { $null }
    latest_event_time_utc = if ($timeValuesUtc.Count -gt 0) { ($timeValuesUtc | Sort-Object | Select-Object -Last 1) } else { $null }
    earliest_event_time_et = if ($timeValuesEt.Count -gt 0) { ($timeValuesEt | Sort-Object | Select-Object -First 1) } else { $null }
    latest_event_time_et = if ($timeValuesEt.Count -gt 0) { ($timeValuesEt | Sort-Object | Select-Object -Last 1) } else { $null }
    output_files = [ordered]@{
        curated_csv = "usgs_seismic_stream/exports/earthquakes_live_curated.csv"
        curated_json = "usgs_seismic_stream/exports/earthquakes_live_curated.json"
        geojson = "usgs_seismic_stream/exports/earthquakes_live.geojson"
        metadata = "usgs_seismic_stream/exports/pipeline_meta.json"
    }
}

$metadata | ConvertTo-Json -Depth 6 | Set-Content -Path $metadataPath -Encoding UTF8

Write-Host ("Published {0} curated USGS earthquake records to {1}" -f @($records).Count, $OutputDirectory)
