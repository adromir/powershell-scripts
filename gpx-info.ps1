# Parameter for the GPX file path
param (
    [string]$gpxFilePath = $(Read-Host "Enter the path to the GPX file")
)

# Load GPX file as XML
[xml]$gpx = Get-Content -Path $gpxFilePath -Raw

# Count the number of waypoints
$waypointCount = $gpx.gpx.wpt.Count

# Count the number of track points
$trackpointCount = ($gpx.gpx.trk.trkseg.trkpt).Count

# Find the first time (waypoint or track point)
if ($waypointCount -gt 0) {
    $firstTime = [datetime]$gpx.gpx.wpt[0].time
} elseif ($trackpointCount -gt 0) {
    $firstTime = [datetime]$gpx.gpx.trk.trkseg.trkpt[0].time
} else {
    $firstTime = $null
}

# Find the last time (waypoint or track point)
if ($waypointCount -gt 0) {
    $lastTime = [datetime]$gpx.gpx.wpt[-1].time
} elseif ($trackpointCount -gt 0) {
    $lastTime = [datetime]$gpx.gpx.trk.trkseg.trkpt[-1].time
} else {
    $lastTime = $null
}

# Display results
Write-Host "Number of waypoints: $waypointCount"
Write-Host "Number of track points: $trackpointCount"

if ($firstTime) {
    $formattedFirstTime = $firstTime.ToString("dd.MM.yyyy HH:mm:ss")
    $firstTimestamp = [int64]($firstTime.ToUniversalTime() - [datetime]'1970-01-01 00:00:00Z').TotalSeconds
    Write-Host "Date and time of the first point: $formattedFirstTime"
    Write-Host "Timestamp of the first point: $firstTimestamp"
} else {
    Write-Host "No time information found."
}

if ($lastTime) {
    $formattedLastTime = $lastTime.ToString("dd.MM.yyyy HH:mm:ss")
    $lastTimestamp = [int64]($lastTime.ToUniversalTime() - [datetime]'1970-01-01 00:00:00Z').TotalSeconds
    Write-Host "Date and time of the last point: $formattedLastTime"
    Write-Host "Timestamp of the last point: $lastTimestamp"
} else {
    Write-Host "No time information found."
}

# Create and display PostgreSQL query
if ($firstTimestamp -and $lastTimestamp) {
    Write-Host "PostgreSQL Query:"
    Write-Host "SELECT * FROM points WHERE timestamp BETWEEN $firstTimestamp AND $lastTimestamp;"
}
