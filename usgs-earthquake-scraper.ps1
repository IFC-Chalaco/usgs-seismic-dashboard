[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$MapUrl = "https://earthquake.usgs.gov/earthquakes/map/?extent=14.64737,-144.22852&extent=56.31654,-45.79102&range=week&magnitude=all",

    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath "usgs-earthquakes.csv"),

    [ValidateSet("Csv", "Json")]
    [string]$OutputFormat,

    [ValidateRange(1, 20000)]
    [int]$PageSize = 5000,

    [string]$CountryBoundaryPath,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($CountryBoundaryPath)) {
    $scriptDirectory = if ($PSCommandPath) { Split-Path -Path $PSCommandPath -Parent } else { (Get-Location).Path }
    $CountryBoundaryPath = Join-Path -Path $scriptDirectory -ChildPath "data\ne_110m_admin_0_countries.geojson"
}

$CatalogApiBase = "https://earthquake.usgs.gov/fdsnws/event/1"
$CountryBoundarySourceUrl = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson"
$MaxQueryWindowCount = 20000
$MaxOffshoreCountryDistanceKm = 100
$EasternTimeZone = $null
$CountryLookupCache = @{}
$CountryBoundaries = @()

foreach ($timeZoneId in @("Eastern Standard Time", "America/New_York")) {
    try {
        $EasternTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($timeZoneId)
        break
    }
    catch {
    }
}

if (-not $EasternTimeZone) {
    throw "Unable to resolve the Eastern time zone on this system."
}

function Copy-Map {
    param([System.Collections.IDictionary]$InputMap)

    $copy = [ordered]@{}
    foreach ($key in $InputMap.Keys) {
        $copy[$key] = $InputMap[$key]
    }

    return $copy
}

function Get-QueryMap {
    param([string]$QueryString)

    $queryMap = @{}
    $trimmed = $QueryString.TrimStart("?")

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $queryMap
    }

    foreach ($pair in $trimmed -split "&") {
        if ([string]::IsNullOrWhiteSpace($pair)) {
            continue
        }

        $parts = $pair -split "=", 2
        $key = [System.Net.WebUtility]::UrlDecode($parts[0])
        $value = if ($parts.Count -gt 1) {
            [System.Net.WebUtility]::UrlDecode($parts[1])
        }
        else {
            ""
        }

        if (-not $queryMap.ContainsKey($key)) {
            $queryMap[$key] = New-Object System.Collections.Generic.List[string]
        }

        $queryMap[$key].Add($value)
    }

    return $queryMap
}

function Get-FirstQueryValue {
    param(
        [hashtable]$QueryMap,
        [string]$Name
    )

    if (-not $QueryMap.ContainsKey($Name) -or $QueryMap[$Name].Count -eq 0) {
        return $null
    }

    return $QueryMap[$Name][0]
}

function ConvertTo-IsoUtcString {
    param([datetimeoffset]$Value)

    return $Value.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function ConvertTo-EasternTimeString {
    param([Nullable[int64]]$UnixTimeMilliseconds)

    if ($null -eq $UnixTimeMilliseconds) {
        return $null
    }

    $utcTime = [datetimeoffset]::FromUnixTimeMilliseconds($UnixTimeMilliseconds)
    $easternTime = [System.TimeZoneInfo]::ConvertTime($utcTime, $EasternTimeZone)
    return $easternTime.ToString("yyyy-MM-ddTHH:mm:sszzz")
}

function Get-TitleMagnitude {
    param([string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return $null
    }

    $match = [System.Text.RegularExpressions.Regex]::Match($Title, '^\s*M\s+(-?\d+(?:\.\d+)?)\b')
    if (-not $match.Success) {
        return $null
    }

    return [double]::Parse($match.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-OneDecimalString {
    param([Nullable[double]]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $normalizedValue = [Math]::Round([double]$Value, 4, [MidpointRounding]::AwayFromZero)
    $roundedValue = [Math]::Round($normalizedValue, 1, [MidpointRounding]::AwayFromZero)
    return $roundedValue.ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-CleanMagnitudeString {
    param(
        [Nullable[double]]$Magnitude,
        [string]$Title
    )

    if ($null -eq $Magnitude) {
        return $null
    }

    $normalizedMagnitude = [Math]::Round([double]$Magnitude, 2, [MidpointRounding]::AwayFromZero)

    if ($normalizedMagnitude -gt 0 -and $normalizedMagnitude -lt 1) {
        return "1.0"
    }

    $titleMagnitude = Get-TitleMagnitude -Title $Title
    if ($null -ne $titleMagnitude) {
        return ConvertTo-OneDecimalString -Value $titleMagnitude
    }

    return ConvertTo-OneDecimalString -Value $normalizedMagnitude
}

function ConvertTo-CleanDepthString {
    param([Nullable[double]]$DepthKm)

    return ConvertTo-OneDecimalString -Value $DepthKm
}

function Initialize-CountryBoundaries {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        $directory = Split-Path -Path $Path -Parent
        if ($directory) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }

        Write-Host ("Downloading country boundaries to {0}..." -f $Path)
        Invoke-WebRequest -Uri $CountryBoundarySourceUrl -Method Get -UseBasicParsing -OutFile $Path
    }

    $geoJson = Get-Content -Path $Path -Raw | ConvertFrom-Json
    $countries = foreach ($feature in @($geoJson.features)) {
        if (-not $feature.geometry -or -not $feature.bbox -or $feature.bbox.Count -lt 4) {
            continue
        }

        [pscustomobject]@{
            Name = if ($feature.properties.ADMIN) { [string]$feature.properties.ADMIN } else { [string]$feature.properties.NAME_LONG }
            MinLongitude = [double]$feature.bbox[0]
            MinLatitude = [double]$feature.bbox[1]
            MaxLongitude = [double]$feature.bbox[2]
            MaxLatitude = [double]$feature.bbox[3]
            GeometryType = [string]$feature.geometry.type
            Coordinates = $feature.geometry.coordinates
        }
    }

    return @($countries)
}

function Test-PointOnSegment {
    param(
        [double]$X,
        [double]$Y,
        [double]$X1,
        [double]$Y1,
        [double]$X2,
        [double]$Y2
    )

    $epsilon = 1e-9
    $crossProduct = (($Y - $Y1) * ($X2 - $X1)) - (($X - $X1) * ($Y2 - $Y1))
    if ([Math]::Abs($crossProduct) -gt $epsilon) {
        return $false
    }

    $minX = [Math]::Min($X1, $X2) - $epsilon
    $maxX = [Math]::Max($X1, $X2) + $epsilon
    $minY = [Math]::Min($Y1, $Y2) - $epsilon
    $maxY = [Math]::Max($Y1, $Y2) + $epsilon

    return $X -ge $minX -and $X -le $maxX -and $Y -ge $minY -and $Y -le $maxY
}

function Test-PointInRing {
    param(
        [object[]]$Ring,
        [double]$Longitude,
        [double]$Latitude
    )

    if (-not $Ring -or $Ring.Count -lt 3) {
        return $false
    }

    $inside = $false
    $previousIndex = $Ring.Count - 1

    for ($index = 0; $index -lt $Ring.Count; $index++) {
        $currentPoint = @($Ring[$index])
        $previousPoint = @($Ring[$previousIndex])

        $x1 = [double]$currentPoint[0]
        $y1 = [double]$currentPoint[1]
        $x2 = [double]$previousPoint[0]
        $y2 = [double]$previousPoint[1]

        if (Test-PointOnSegment -X $Longitude -Y $Latitude -X1 $x1 -Y1 $y1 -X2 $x2 -Y2 $y2) {
            return $true
        }

        $intersects = (($y1 -gt $Latitude) -ne ($y2 -gt $Latitude)) -and
            ($Longitude -lt (($x2 - $x1) * ($Latitude - $y1) / ($y2 - $y1) + $x1))

        if ($intersects) {
            $inside = -not $inside
        }

        $previousIndex = $index
    }

    return $inside
}

function Test-PointInPolygon {
    param(
        [object[]]$PolygonCoordinates,
        [double]$Longitude,
        [double]$Latitude
    )

    if (-not $PolygonCoordinates -or $PolygonCoordinates.Count -eq 0) {
        return $false
    }

    $outerRing = @($PolygonCoordinates[0])
    if (-not (Test-PointInRing -Ring $outerRing -Longitude $Longitude -Latitude $Latitude)) {
        return $false
    }

    for ($ringIndex = 1; $ringIndex -lt $PolygonCoordinates.Count; $ringIndex++) {
        $holeRing = @($PolygonCoordinates[$ringIndex])
        if (Test-PointInRing -Ring $holeRing -Longitude $Longitude -Latitude $Latitude) {
            return $false
        }
    }

    return $true
}

function Get-DistanceBetweenCoordinatesKm {
    param(
        [double]$Latitude1,
        [double]$Longitude1,
        [double]$Latitude2,
        [double]$Longitude2
    )

    $earthRadiusKm = 6371.0088
    $lat1Rad = $Latitude1 * [Math]::PI / 180
    $lat2Rad = $Latitude2 * [Math]::PI / 180
    $deltaLatRad = ($Latitude2 - $Latitude1) * [Math]::PI / 180
    $deltaLonRad = ($Longitude2 - $Longitude1) * [Math]::PI / 180

    $a = [Math]::Sin($deltaLatRad / 2) * [Math]::Sin($deltaLatRad / 2) +
        [Math]::Cos($lat1Rad) * [Math]::Cos($lat2Rad) *
        [Math]::Sin($deltaLonRad / 2) * [Math]::Sin($deltaLonRad / 2)

    $c = 2 * [Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1 - $a))
    return $earthRadiusKm * $c
}

function Get-DistanceToSegmentKm {
    param(
        [double]$Longitude,
        [double]$Latitude,
        [double]$Longitude1,
        [double]$Latitude1,
        [double]$Longitude2,
        [double]$Latitude2
    )

    $referenceLatitudeRad = $Latitude * [Math]::PI / 180
    $xScale = 111.320 * [Math]::Cos($referenceLatitudeRad)
    $yScale = 110.574

    $pointX = 0.0
    $pointY = 0.0
    $startX = ($Longitude1 - $Longitude) * $xScale
    $startY = ($Latitude1 - $Latitude) * $yScale
    $endX = ($Longitude2 - $Longitude) * $xScale
    $endY = ($Latitude2 - $Latitude) * $yScale

    $deltaX = $endX - $startX
    $deltaY = $endY - $startY
    $segmentLengthSquared = ($deltaX * $deltaX) + ($deltaY * $deltaY)

    if ($segmentLengthSquared -le 0) {
        return [Math]::Sqrt(($startX * $startX) + ($startY * $startY))
    }

    $projection = ((($pointX - $startX) * $deltaX) + (($pointY - $startY) * $deltaY)) / $segmentLengthSquared
    $projection = [Math]::Max(0, [Math]::Min(1, $projection))

    $closestX = $startX + ($projection * $deltaX)
    $closestY = $startY + ($projection * $deltaY)
    return [Math]::Sqrt(($closestX * $closestX) + ($closestY * $closestY))
}

function Get-MinimumRingDistanceKm {
    param(
        [object[]]$Ring,
        [double]$Longitude,
        [double]$Latitude
    )

    if (-not $Ring -or $Ring.Count -lt 2) {
        return [double]::PositiveInfinity
    }

    $minimumDistance = [double]::PositiveInfinity
    $previousIndex = $Ring.Count - 1

    for ($index = 0; $index -lt $Ring.Count; $index++) {
        $currentPoint = @($Ring[$index])
        $previousPoint = @($Ring[$previousIndex])
        $distance = Get-DistanceToSegmentKm `
            -Longitude $Longitude `
            -Latitude $Latitude `
            -Longitude1 ([double]$previousPoint[0]) `
            -Latitude1 ([double]$previousPoint[1]) `
            -Longitude2 ([double]$currentPoint[0]) `
            -Latitude2 ([double]$currentPoint[1])

        if ($distance -lt $minimumDistance) {
            $minimumDistance = $distance
        }

        $previousIndex = $index
    }

    return $minimumDistance
}

function Get-MinimumPolygonDistanceKm {
    param(
        [object[]]$PolygonCoordinates,
        [double]$Longitude,
        [double]$Latitude
    )

    if (Test-PointInPolygon -PolygonCoordinates $PolygonCoordinates -Longitude $Longitude -Latitude $Latitude) {
        return 0
    }

    $minimumDistance = [double]::PositiveInfinity
    foreach ($ring in @($PolygonCoordinates)) {
        $distance = Get-MinimumRingDistanceKm -Ring @($ring) -Longitude $Longitude -Latitude $Latitude
        if ($distance -lt $minimumDistance) {
            $minimumDistance = $distance
        }
    }

    return $minimumDistance
}

function Resolve-CountryFromPlace {
    param([string]$Place)

    if ([string]::IsNullOrWhiteSpace($Place)) {
        return $null
    }

    $normalizedPlace = $Place.Trim()

    $explicitMappings = [ordered]@{
        "Anguilla" = "Anguilla"
        "U.S. Virgin Islands" = "U.S. Virgin Islands"
        "US Virgin Islands" = "U.S. Virgin Islands"
        "British Virgin Islands" = "British Virgin Islands"
        "Puerto Rico" = "Puerto Rico"
        "Dominican Republic" = "Dominican Republic"
        "Mexico" = "Mexico"
        "Canada" = "Canada"
        "Guatemala" = "Guatemala"
    }

    foreach ($key in $explicitMappings.Keys) {
        if ($normalizedPlace -match [Regex]::Escape($key)) {
            return $explicitMappings[$key]
        }
    }

    $suffix = if ($normalizedPlace.Contains(",")) {
        ($normalizedPlace.Split(",")[-1]).Trim()
    }
    else {
        $normalizedPlace
    }

    $usStateTokens = @(
        "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA","HI","ID","IL","IN","IA","KS","KY","LA","ME","MD","MA",
        "MI","MN","MS","MO","MT","NE","NV","NH","NJ","NM","NY","NC","ND","OH","OK","OR","PA","RI","SC","SD","TN",
        "TX","UT","VT","VA","WA","WV","WI","WY","DC",
        "Alabama","Alaska","Arizona","Arkansas","California","Colorado","Connecticut","Delaware","Florida","Georgia",
        "Hawaii","Idaho","Illinois","Indiana","Iowa","Kansas","Kentucky","Louisiana","Maine","Maryland","Massachusetts",
        "Michigan","Minnesota","Mississippi","Missouri","Montana","Nebraska","Nevada","New Hampshire","New Jersey",
        "New Mexico","New York","North Carolina","North Dakota","Ohio","Oklahoma","Oregon","Pennsylvania","Rhode Island",
        "South Carolina","South Dakota","Tennessee","Texas","Utah","Vermont","Virginia","Washington","West Virginia",
        "Wisconsin","Wyoming"
    )

    if ($usStateTokens -contains $suffix) {
        return "United States of America"
    }

    $canadaProvinceTokens = @(
        "AB","BC","MB","NB","NL","NS","NT","NU","ON","PE","QC","SK","YT",
        "Alberta","British Columbia","Manitoba","New Brunswick","Newfoundland and Labrador","Nova Scotia",
        "Northwest Territories","Nunavut","Ontario","Prince Edward Island","Quebec","Saskatchewan","Yukon"
    )

    if ($canadaProvinceTokens -contains $suffix) {
        return "Canada"
    }

    return $null
}

function Resolve-NonCountryFallback {
    param([string]$Place)

    if ([string]::IsNullOrWhiteSpace($Place)) {
        return "Unknown"
    }

    $internationalWaterTokens = @(
        "Ridge",
        "Ocean",
        "Sea",
        "Trench",
        "Trough",
        "Basin",
        "Rise",
        "Fracture Zone",
        "Abyssal"
    )

    foreach ($token in $internationalWaterTokens) {
        if ($Place -match ("(?i)\b{0}\b" -f [Regex]::Escape($token))) {
            return "International Waters"
        }
    }

    return "Unknown"
}

function Resolve-CountryName {
    param(
        [Nullable[double]]$Latitude,
        [Nullable[double]]$Longitude,
        [string]$Place
    )

    if ($null -eq $Latitude -or $null -eq $Longitude) {
        $placeCountry = Resolve-CountryFromPlace -Place $Place
        if ($placeCountry) {
            return $placeCountry
        }

        return Resolve-NonCountryFallback -Place $Place
    }

    $latitudeValue = [double]$Latitude
    $longitudeValue = [double]$Longitude

    $cacheKey = "{0}|{1}|{2}" -f $latitudeValue.ToString("G17"), $longitudeValue.ToString("G17"), $Place
    if ($CountryLookupCache.ContainsKey($cacheKey)) {
        return $CountryLookupCache[$cacheKey]
    }

    $matchedCountry = $null
    $placeCountry = Resolve-CountryFromPlace -Place $Place

    foreach ($country in $CountryBoundaries) {
        $isInside = $false

        switch ($country.GeometryType) {
            "Polygon" {
                if ($longitudeValue -ge $country.MinLongitude -and
                    $longitudeValue -le $country.MaxLongitude -and
                    $latitudeValue -ge $country.MinLatitude -and
                    $latitudeValue -le $country.MaxLatitude) {
                    $isInside = Test-PointInPolygon -PolygonCoordinates @($country.Coordinates) -Longitude $longitudeValue -Latitude $latitudeValue
                }
            }
            "MultiPolygon" {
                foreach ($polygon in @($country.Coordinates)) {
                    $polygonCoordinates = @($polygon)
                    $polygonLongitudes = foreach ($ring in $polygonCoordinates) {
                        foreach ($point in @($ring)) {
                            [double]$point[0]
                        }
                    }
                    $polygonLatitudes = foreach ($ring in $polygonCoordinates) {
                        foreach ($point in @($ring)) {
                            [double]$point[1]
                        }
                    }

                    if ($polygonLongitudes.Count -gt 0 -and $polygonLatitudes.Count -gt 0 -and
                        $longitudeValue -ge (($polygonLongitudes | Measure-Object -Minimum).Minimum) -and
                        $longitudeValue -le (($polygonLongitudes | Measure-Object -Maximum).Maximum) -and
                        $latitudeValue -ge (($polygonLatitudes | Measure-Object -Minimum).Minimum) -and
                        $latitudeValue -le (($polygonLatitudes | Measure-Object -Maximum).Maximum) -and
                        (Test-PointInPolygon -PolygonCoordinates $polygonCoordinates -Longitude $longitudeValue -Latitude $latitudeValue)) {
                        $isInside = $true
                        break
                    }
                }
            }
        }

        if ($isInside) {
            $matchedCountry = $country.Name
            break
        }
    }

    if ($matchedCountry) {
        $CountryLookupCache[$cacheKey] = $matchedCountry
        return $matchedCountry
    }

    if ($placeCountry) {
        $CountryLookupCache[$cacheKey] = $placeCountry
        return $placeCountry
    }

    $closestCountry = $null
    $closestDistanceKm = [double]::PositiveInfinity
    $latitudeThresholdDegrees = $MaxOffshoreCountryDistanceKm / 110.574
    $longitudeScale = 111.320 * [Math]::Cos($latitudeValue * [Math]::PI / 180)
    if ([Math]::Abs($longitudeScale) -lt 0.01) {
        $longitudeScale = 0.01
    }

    $longitudeThresholdDegrees = $MaxOffshoreCountryDistanceKm / [Math]::Abs($longitudeScale)

    foreach ($country in $CountryBoundaries) {
        if ($longitudeValue -lt ($country.MinLongitude - $longitudeThresholdDegrees) -or
            $longitudeValue -gt ($country.MaxLongitude + $longitudeThresholdDegrees) -or
            $latitudeValue -lt ($country.MinLatitude - $latitudeThresholdDegrees) -or
            $latitudeValue -gt ($country.MaxLatitude + $latitudeThresholdDegrees)) {
            continue
        }

        $minimumDistanceKm = [double]::PositiveInfinity
        switch ($country.GeometryType) {
            "Polygon" {
                $minimumDistanceKm = Get-MinimumPolygonDistanceKm -PolygonCoordinates @($country.Coordinates) -Longitude $longitudeValue -Latitude $latitudeValue
            }
            "MultiPolygon" {
                foreach ($polygon in @($country.Coordinates)) {
                    $polygonDistanceKm = Get-MinimumPolygonDistanceKm -PolygonCoordinates @($polygon) -Longitude $longitudeValue -Latitude $latitudeValue
                    if ($polygonDistanceKm -lt $minimumDistanceKm) {
                        $minimumDistanceKm = $polygonDistanceKm
                    }
                }
            }
        }

        if ($minimumDistanceKm -lt $closestDistanceKm) {
            $closestDistanceKm = $minimumDistanceKm
            $closestCountry = $country.Name
        }
    }

    if ($closestCountry -and $closestDistanceKm -le $MaxOffshoreCountryDistanceKm) {
        $matchedCountry = $closestCountry
    }

    if (-not $matchedCountry) {
        $matchedCountry = Resolve-NonCountryFallback -Place $Place
    }

    $CountryLookupCache[$cacheKey] = $matchedCountry
    return $matchedCountry
}

function Resolve-RelativeRange {
    param(
        [string]$Range,
        [datetimeoffset]$NowUtc
    )

    switch ($Range.ToLowerInvariant()) {
        "hour" { return $NowUtc.AddHours(-1) }
        "day" { return $NowUtc.AddDays(-1) }
        "week" { return $NowUtc.AddDays(-7) }
        "month" { return $NowUtc.AddDays(-30) }
        "year" { return $NowUtc.AddYears(-1) }
        default {
            throw "Unsupported range '$Range'. Provide a map URL with explicit search dates or one of: hour, day, week, month, year."
        }
    }
}

function ConvertTo-ApiQueryString {
    param([System.Collections.IDictionary]$Parameters)

    return ($Parameters.Keys | ForEach-Object {
            $key = [System.Uri]::EscapeDataString([string]$_)
            $value = [System.Uri]::EscapeDataString([string]$Parameters[$_])
            "$key=$value"
        }) -join "&"
}

function New-UsgsUri {
    param(
        [string]$Method,
        [System.Collections.IDictionary]$Parameters
    )

    $query = ConvertTo-ApiQueryString -Parameters $Parameters
    return "$CatalogApiBase/$Method`?$query"
}

function Get-UsgsCount {
    param([System.Collections.IDictionary]$Parameters)

    $countParams = Copy-Map -InputMap $Parameters
    $null = $countParams.Remove("format")
    $null = $countParams.Remove("limit")
    $null = $countParams.Remove("offset")

    $countUri = New-UsgsUri -Method "count" -Parameters $countParams
    $response = Invoke-WebRequest -Uri $countUri -Method Get -UseBasicParsing
    return [int]$response.Content.Trim()
}

function Invoke-UsgsQuery {
    param([System.Collections.IDictionary]$Parameters)

    $queryUri = New-UsgsUri -Method "query" -Parameters $Parameters
    return Invoke-RestMethod -Uri $queryUri -Method Get
}

function ConvertFrom-MapUrl {
    param([string]$InputUrl)

    $uri = [System.Uri]$InputUrl
    $queryMap = Get-QueryMap -QueryString $uri.Query
    $nowUtc = [datetimeoffset]::UtcNow
    $apiParams = [ordered]@{
        format = "geojson"
        orderby = "time"
    }

    if ($queryMap.ContainsKey("search")) {
        $searchPayload = $queryMap["search"][0] | ConvertFrom-Json
        $supportedKeys = @(
            "alertlevel",
            "catalog",
            "contributor",
            "endtime",
            "eventtype",
            "latitude",
            "longitude",
            "maxcdi",
            "maxdepth",
            "maxgap",
            "maxlatitude",
            "maxlongitude",
            "maxmagnitude",
            "maxmmi",
            "maxradius",
            "maxradiuskm",
            "maxsig",
            "minalertlevel",
            "mincdi",
            "mindepth",
            "minfelt",
            "mingap",
            "minlatitude",
            "minlongitude",
            "minmagnitude",
            "minsig",
            "nodata",
            "orderby",
            "producttype",
            "reviewstatus",
            "starttime",
            "updatedafter"
        )

        foreach ($key in $supportedKeys) {
            if ($searchPayload.PSObject.Properties.Name -contains $key) {
                $value = $searchPayload.$key
                if ($null -ne $value -and "$value" -ne "") {
                    $apiParams[$key] = [string]$value
                }
            }
        }
    }

    $extentValues = if ($queryMap.ContainsKey("extent")) { $queryMap["extent"] } else { @() }
    if ($extentValues.Count -ge 2) {
        $southWest = $extentValues[0].Split(",")
        $northEast = $extentValues[1].Split(",")

        if ($southWest.Count -eq 2 -and $northEast.Count -eq 2) {
            $apiParams["minlatitude"] = $southWest[0]
            $apiParams["minlongitude"] = $southWest[1]
            $apiParams["maxlatitude"] = $northEast[0]
            $apiParams["maxlongitude"] = $northEast[1]
        }
    }

    $explicitPassThroughKeys = @(
        "alertlevel",
        "catalog",
        "contributor",
        "endtime",
        "eventtype",
        "latitude",
        "longitude",
        "maxcdi",
        "maxdepth",
        "maxgap",
        "maxlatitude",
        "maxlongitude",
        "maxmagnitude",
        "maxmmi",
        "maxradius",
        "maxradiuskm",
        "maxsig",
        "minalertlevel",
        "mincdi",
        "mindepth",
        "minfelt",
        "mingap",
        "minlatitude",
        "minlongitude",
        "minmagnitude",
        "minsig",
        "orderby",
        "producttype",
        "reviewstatus",
        "starttime",
        "updatedafter"
    )

    foreach ($key in $explicitPassThroughKeys) {
        $value = Get-FirstQueryValue -QueryMap $queryMap -Name $key
        if ($null -ne $value -and $value -ne "") {
            $apiParams[$key] = $value
        }
    }

    $rangeValue = Get-FirstQueryValue -QueryMap $queryMap -Name "range"
    if ($rangeValue -and -not $apiParams.Contains("starttime")) {
        $apiParams["starttime"] = ConvertTo-IsoUtcString -Value (Resolve-RelativeRange -Range $rangeValue -NowUtc $nowUtc)
        if (-not $apiParams.Contains("endtime")) {
            $apiParams["endtime"] = ConvertTo-IsoUtcString -Value $nowUtc
        }
    }

    $magnitudeValue = Get-FirstQueryValue -QueryMap $queryMap -Name "magnitude"
    if ($magnitudeValue -and $magnitudeValue -ne "all" -and -not $apiParams.Contains("minmagnitude")) {
        if ($magnitudeValue -match "^-?\d+(\.\d+)?$") {
            $apiParams["minmagnitude"] = $magnitudeValue
        }
        else {
            Write-Warning "Skipping unsupported magnitude filter '$magnitudeValue'. Add an explicit minmagnitude to the map URL if needed."
        }
    }

    $sortValue = Get-FirstQueryValue -QueryMap $queryMap -Name "sort"
    if ($sortValue) {
        $sortMap = @{
            newest = "time"
            oldest = "time-asc"
            largest = "magnitude"
            smallest = "magnitude-asc"
        }

        if ($sortMap.ContainsKey($sortValue)) {
            $apiParams["orderby"] = $sortMap[$sortValue]
        }
    }

    if (-not $apiParams.Contains("starttime")) {
        $apiParams["starttime"] = ConvertTo-IsoUtcString -Value (Resolve-RelativeRange -Range "month" -NowUtc $nowUtc)
    }

    if (-not $apiParams.Contains("endtime")) {
        $apiParams["endtime"] = ConvertTo-IsoUtcString -Value $nowUtc
    }

    return $apiParams
}

function Get-WindowParts {
    param(
        [System.Collections.IDictionary]$BaseParameters,
        [datetimeoffset]$StartTime,
        [datetimeoffset]$EndTime
    )

    if ($EndTime -lt $StartTime) {
        throw "End time must be greater than or equal to start time."
    }

    $windowParams = Copy-Map -InputMap $BaseParameters
    $windowParams["starttime"] = ConvertTo-IsoUtcString -Value $StartTime
    $windowParams["endtime"] = ConvertTo-IsoUtcString -Value $EndTime

    $count = Get-UsgsCount -Parameters $windowParams
    if ($count -le $MaxQueryWindowCount) {
        return @([pscustomobject]@{
                StartTime = $StartTime
                EndTime = $EndTime
                Count = $count
            })
    }

    $duration = $EndTime - $StartTime
    if ($duration.TotalSeconds -lt 2) {
        throw "USGS returned more than $MaxQueryWindowCount events inside a window shorter than 2 seconds. Narrow the filters and try again."
    }

    # Split oversized windows so the API never needs to return more than 20,000 events in a single query.
    $midpoint = $StartTime.AddTicks([long]($duration.Ticks / 2))
    $rightStart = $midpoint.AddMilliseconds(1)

    $left = Get-WindowParts -BaseParameters $BaseParameters -StartTime $StartTime -EndTime $midpoint
    $right = Get-WindowParts -BaseParameters $BaseParameters -StartTime $rightStart -EndTime $EndTime

    return @($left + $right)
}

function Convert-UsgsFeatureToRecord {
    param($Feature)

    $properties = $Feature.properties
    $coordinates = @()
    if ($Feature.geometry -and $Feature.geometry.coordinates) {
        $coordinates = @($Feature.geometry.coordinates)
    }

    $longitude = if ($coordinates.Count -gt 0) { $coordinates[0] } else { $null }
    $latitude = if ($coordinates.Count -gt 1) { $coordinates[1] } else { $null }
    $depth = if ($coordinates.Count -gt 2) { $coordinates[2] } else { $null }

    [pscustomobject][ordered]@{
        id = $Feature.id
        time_utc = if ($null -ne $properties.time) { [datetimeoffset]::FromUnixTimeMilliseconds([int64]$properties.time).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { $null }
        time_et = ConvertTo-EasternTimeString -UnixTimeMilliseconds $properties.time
        updated_utc = if ($null -ne $properties.updated) { [datetimeoffset]::FromUnixTimeMilliseconds([int64]$properties.updated).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { $null }
        magnitude = ConvertTo-CleanMagnitudeString -Magnitude $properties.mag -Title $properties.title
        magnitude_raw = if ($null -ne $properties.mag) { [Math]::Round([double]$properties.mag, 2, [MidpointRounding]::AwayFromZero) } else { $null }
        place = $properties.place
        latitude = $latitude
        longitude = $longitude
        country = Resolve-CountryName -Latitude $latitude -Longitude $longitude -Place $properties.place
        depth_km = ConvertTo-CleanDepthString -DepthKm $depth
        depth_km_raw = if ($null -ne $depth) { [Math]::Round([double]$depth, 4, [MidpointRounding]::AwayFromZero) } else { $null }
        felt_reports = $properties.felt
        cdi = $properties.cdi
        mmi = $properties.mmi
        alert = $properties.alert
        status = $properties.status
        tsunami = $properties.tsunami
        significance = $properties.sig
        event_type = $properties.type
        title = $properties.title
        detail_url = $properties.url
        detail_api = $properties.detail
    }
}

if (-not $OutputFormat) {
    $OutputFormat = switch ([System.IO.Path]::GetExtension($OutputPath).ToLowerInvariant()) {
        ".json" { "Json" }
        default { "Csv" }
    }
}

$CountryBoundaries = Initialize-CountryBoundaries -Path $CountryBoundaryPath
$apiParameters = ConvertFrom-MapUrl -InputUrl $MapUrl
$baseParameters = Copy-Map -InputMap $apiParameters
$startTime = [datetimeoffset]$baseParameters["starttime"]
$endTime = [datetimeoffset]$baseParameters["endtime"]
$windowParts = Get-WindowParts -BaseParameters $baseParameters -StartTime $startTime -EndTime $endTime

$featureById = @{}
$totalExpected = ($windowParts | Measure-Object -Property Count -Sum).Sum
$fetched = 0

foreach ($window in $windowParts) {
    if ($window.Count -eq 0) {
        continue
    }

    for ($offset = 1; $offset -le $window.Count; $offset += $PageSize) {
        $pageLimit = [Math]::Min($PageSize, $window.Count - $offset + 1)
        $pageParams = Copy-Map -InputMap $baseParameters
        $pageParams["starttime"] = ConvertTo-IsoUtcString -Value $window.StartTime
        $pageParams["endtime"] = ConvertTo-IsoUtcString -Value $window.EndTime
        $pageParams["limit"] = [string]$pageLimit
        $pageParams["offset"] = [string]$offset

        $response = Invoke-UsgsQuery -Parameters $pageParams
        foreach ($feature in $response.features) {
            $featureById[$feature.id] = $feature
        }

        $fetched += @($response.features).Count
        Write-Host ("Fetched {0}/{1} events..." -f $fetched, $totalExpected)
    }
}

$records = $featureById.Values |
    Sort-Object { [datetimeoffset]::FromUnixTimeMilliseconds([int64]$_.properties.time) } -Descending |
    ForEach-Object { Convert-UsgsFeatureToRecord -Feature $_ }

if ($OutputFormat -eq "Json") {
    $payload = [ordered]@{
        source_map_url = $MapUrl
        fetched_at_utc = ConvertTo-IsoUtcString -Value ([datetimeoffset]::UtcNow)
        total_events = @($records).Count
        api_query = New-UsgsUri -Method "query" -Parameters $baseParameters
        events = @($records)
    }

    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding UTF8
}
else {
    @($records) | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
}

Write-Host ("Saved {0} events to {1}" -f @($records).Count, $OutputPath)

if ($PassThru) {
    $records
}
