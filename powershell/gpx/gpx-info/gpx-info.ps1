<#
.SYNOPSIS
    Parses a GPX file to extract waypoint and track point counts, and the first/last timestamps.

.DESCRIPTION
    This script reads a GPX (GPS Exchange Format) file specified by the user.
    It parses the XML content to count the total number of waypoints (<wpt> tags)
    and track points (<trkpt> tags). It also identifies the timestamp of the
    very first point (either waypoint or track point) and the very last point
    found in the file. The script outputs these counts and timestamps (both as
    formatted date/time strings and Unix timestamps). Finally, it generates a
    sample PostgreSQL query using the first and last timestamps.

.PARAMETER gpxFilePath
    The full path to the GPX file that needs to be processed. The script will
    prompt the user to enter this path if it's not provided when running the script.

.EXAMPLE
    .\YourScriptName.ps1 -gpxFilePath "C:\Users\You\Documents\MyHike.gpx"

    Runs the script using the specified GPX file.

.EXAMPLE
    .\YourScriptName.ps1

    Runs the script and prompts the user to enter the path to the GPX file interactively.

.OUTPUTS
    System.String
    Outputs information about the GPX file to the console, including:
    - Number of waypoints
    - Number of track points
    - Date, time, and Unix timestamp of the first point (if available)
    - Date, time, and Unix timestamp of the last point (if available)
    - A sample PostgreSQL query based on the timestamps (if available)

.NOTES
    Author: Your Name/AI Assistant
    Date: 2025-04-22
    Requires PowerShell 3.0 or later (due to [xml] type accelerator and -Raw parameter).
    The script assumes a standard GPX file structure. Malformed GPX files might cause errors.
    Timestamps are converted to Unix epoch format (seconds since 1970-01-01 00:00:00Z).
#>
param (
    [Parameter(Mandatory=$false, HelpMessage="Enter the path to the GPX file")]
    [string]$gpxFilePath = $(Read-Host "Enter the path to the GPX file")
)

# Validate if the file exists
if (-not (Test-Path -Path $gpxFilePath -PathType Leaf)) {
    Write-Error "Error: The file '$gpxFilePath' was not found or is not a file."
    exit 1 # Exit the script if file not found
}

# Load GPX file as XML
try {
    Write-Host "Loading GPX file: $gpxFilePath"
    [xml]$gpx = Get-Content -Path $gpxFilePath -Raw -ErrorAction Stop
} catch {
    Write-Error "Error loading or parsing the GPX file. Please ensure it's a valid XML/GPX file."
    Write-Error $_.Exception.Message
    exit 1 # Exit on error
}

# Define namespaces for robust XML parsing (GPX files often use namespaces)
$ns = @{ gpx = "http://www.topografix.com/GPX/1/1" } # Adjust namespace if needed (check your GPX file)

# Count the number of waypoints using XPath with namespace
$waypointNodes = $gpx.SelectNodes("//gpx:wpt", $ns)
$waypointCount = if ($waypointNodes) { $waypointNodes.Count } else { 0 }

# Count the number of track points using XPath with namespace
$trackpointNodes = $gpx.SelectNodes("//gpx:trkpt", $ns)
$trackpointCount = if ($trackpointNodes) { $trackpointNodes.Count } else { 0 }

# Find the first time (waypoint or track point)
$firstTime = $null
$firstWaypointTimeNode = $gpx.SelectSingleNode("//gpx:wpt/gpx:time", $ns)
$firstTrackpointTimeNode = $gpx.SelectSingleNode("//gpx:trkpt/gpx:time", $ns)

# Convert times safely
$firstWaypointTime = if ($firstWaypointTimeNode) { try { [datetime]$firstWaypointTimeNode.InnerText } catch { $null } } else { $null }
$firstTrackpointTime = if ($firstTrackpointTimeNode) { try { [datetime]$firstTrackpointTimeNode.InnerText } catch { $null } } else { $null }

# Determine the actual first time
if ($firstWaypointTime -and $firstTrackpointTime) {
    $firstTime = if ($firstWaypointTime -lt $firstTrackpointTime) { $firstWaypointTime } else { $firstTrackpointTime }
} elseif ($firstWaypointTime) {
    $firstTime = $firstWaypointTime
} elseif ($firstTrackpointTime) {
    $firstTime = $firstTrackpointTime
}

# Find the last time (waypoint or track point)
$lastTime = $null
$lastWaypointTimeNode = $null
$lastTrackpointTimeNode = $null

if ($waypointNodes) {
    $lastWaypointTimeNode = $waypointNodes[-1].SelectSingleNode("gpx:time", $ns)
}
if ($trackpointNodes) {
    $lastTrackpointTimeNode = $trackpointNodes[-1].SelectSingleNode("gpx:time", $ns)
}

# Convert times safely
$lastWaypointTime = if ($lastWaypointTimeNode) { try { [datetime]$lastWaypointTimeNode.InnerText } catch { $null } } else { $null }
$lastTrackpointTime = if ($lastTrackpointTimeNode) { try { [datetime]$lastTrackpointTimeNode.InnerText } catch { $null } } else { $null }

# Determine the actual last time
if ($lastWaypointTime -and $lastTrackpointTime) {
    $lastTime = if ($lastWaypointTime -gt $lastTrackpointTime) { $lastWaypointTime } else { $lastTrackpointTime }
} elseif ($lastWaypointTime) {
    $lastTime = $lastWaypointTime
} elseif ($lastTrackpointTime) {
    $lastTime = $lastTrackpointTime
}

# --- Display results ---
Write-Host "--- GPX File Summary ---"
Write-Host "Number of waypoints: $waypointCount"
Write-Host "Number of track points: $trackpointCount"
Write-Host "------------------------"

$firstTimestamp = $null
if ($firstTime) {
    $formattedFirstTime = $firstTime.ToString("dd.MM.yyyy HH:mm:ss 'UTC'zzz") # Show timezone info
    # Calculate Unix timestamp (seconds since 1970-01-01 00:00:00 UTC)
    $firstTimestamp = [int64]($firstTime.ToUniversalTime() - [datetime]'1970-01-01 00:00:00Z').TotalSeconds
    Write-Host "First point time: $formattedFirstTime"
    Write-Host "First point timestamp (Unix): $firstTimestamp"
} else {
    Write-Host "No time information found for the first point."
}

$lastTimestamp = $null
if ($lastTime) {
    $formattedLastTime = $lastTime.ToString("dd.MM.yyyy HH:mm:ss 'UTC'zzz") # Show timezone info
    # Calculate Unix timestamp
    $lastTimestamp = [int64]($lastTime.ToUniversalTime() - [datetime]'1970-01-01 00:00:00Z').TotalSeconds
    Write-Host "Last point time: $formattedLastTime"
    Write-Host "Last point timestamp (Unix): $lastTimestamp"
} else {
    Write-Host "No time information found for the last point."
}
Write-Host "------------------------"

# Create and display PostgreSQL query
if ($firstTimestamp -ne $null -and $lastTimestamp -ne $null) {
    Write-Host "Sample PostgreSQL Query:"
    # Using timestamp columns directly (assuming 'timestamp' column is of type TIMESTAMPTZ or similar)
    # Or use integer comparison if your column stores Unix timestamps
    Write-Host "SELECT * FROM your_table WHERE timestamp_column >= to_timestamp($firstTimestamp) AND timestamp_column <= to_timestamp($lastTimestamp);"
    # Example if your column stores Unix epoch integers:
    # Write-Host "SELECT * FROM your_table WHERE unix_timestamp_column BETWEEN $firstTimestamp AND $lastTimestamp;"
} else {
    Write-Host "Cannot generate PostgreSQL query as time information is incomplete."
}

Write-Host "--- Processing Complete ---"

