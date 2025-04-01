# Get the path to the GPX file from the user
$gpxFilePath = Read-Host "Please enter the path to the GPX file"

# Get the coordinate type (lat or lon) from the user
$coordinateType = Read-Host "Filter by longitude (lon) or latitude (lat)?"

# Get the filter value from the user
$coordinateValue = Read-Host "Please enter the filter value"

# Check if the file exists
if (-not (Test-Path $gpxFilePath)) {
    Write-Error "GPX file not found: $gpxFilePath"
    return
}

try {
    # Load the XML file
    [xml]$gpx = Get-Content $gpxFilePath

    # Create a namespace manager (if namespaces are used)
    $ns = New-Object System.Xml.XmlNamespaceManager($gpx.NameTable)
    $ns.AddNamespace("gpx", "http://www.topografix.com/GPX/1/1") # Adjust namespace if necessary

    # Select points to remove (coordinates start with the filter value)
    $pointsToRemove = $gpx.SelectNodes("//gpx:wpt[starts-with(@" + $coordinateType + ", '" + $coordinateValue + "')] | //gpx:trkpt[starts-with(@" + $coordinateType + ", '" + $coordinateValue + "')]", $ns)

    # Debugging: Display the number of found points
    Write-Host "Number of found points: $($pointsToRemove.Count)"

    # Remove points
    if ($pointsToRemove.Count -gt 0) {
        foreach ($point in $pointsToRemove) {
            $point.ParentNode.RemoveChild($point)
        }

        # Save the modified XML file
        $gpx.Save($gpxFilePath)

        Write-Host "$($pointsToRemove.Count) points with $coordinateType coordinates starting with '$coordinateValue' were removed and the file was saved."
    } else {
        Write-Host "No points with $coordinateType coordinates starting with '$coordinateValue' were found."
    }
} catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
}
