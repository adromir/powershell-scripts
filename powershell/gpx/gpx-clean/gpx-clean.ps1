<#
.SYNOPSIS
	Cleans and analyzes GPX files by filtering points based on coordinate prefixes and provides basic statistics and SQL queries.

.DESCRIPTION
	This PowerShell script provides a graphical user interface (GUI) to interact with GPX (GPS Exchange Format) files.
	Its main functions are:
	1.  File Selection: Prompts the user to select a GPX file using a standard Windows file dialog.
	2.  Filtering Criteria Input: Opens a custom form where the user can choose to filter by Latitude (lat) or Longitude (lon) and specify a prefix value. This allows removing unwanted waypoints (wpt) or trackpoints (trkpt). Leaving the filter value empty skips the cleaning step.
	3.  Timestamp Analysis (Original): Determines the first and last timestamps from the originally loaded GPX file.
	4.  GPX Cleaning (In Memory): Loads the GPX file into memory. If a filter value was provided, it removes points whose specified coordinate attribute starts with the filter value.
	5.  Timestamp Analysis (Cleaned): Determines the first and last timestamps from the potentially modified GPX data.
	6.  GPX Analysis: Counts remaining waypoints and trackpoints.
	7.  Output Generation: Collects analysis results (point counts, original & cleaned timestamps) and generates example PostgreSQL SELECT and DELETE queries. The DELETE query specifically targets points matching the filter criteria within the original time range.
	8.  Output Display: Displays all collected results and queries in a separate GUI window with a selectable, read-only text box. Console output focuses on progress and status messages.
	9.  Saving Changes: If points were removed, asks the user via a confirmation dialog whether to overwrite the original GPX file.

	Dependencies: Requires .NET Framework for the GUI elements (System.Windows.Forms, System.Drawing).

.NOTES
	Author: Adromir


.PARAMETER None
	The script prompts the user for all necessary inputs via GUI.

.EXAMPLE
	.\gpx-clean.ps1
	This will launch the script, showing GUI prompts and finally the results window.
#>

# --- Part 0: Load .NET Assemblies ---
# Required for the graphical elements
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Error "Error loading .NET assemblies for GUI. Ensure .NET Framework is installed."
    [System.Windows.Forms.MessageBox]::Show(
        "Error loading .NET assemblies for GUI. Ensure .NET Framework is installed.`n$($_.Exception.Message)",
        "Assembly Load Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
     )
    Exit
}

# --- Function for the Input Form (Lat/Lon + Filter) ---
function Get-FilterInput {
    # Create the form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Filter Settings'
    $form.Size = New-Object System.Drawing.Size(320, 200)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    # Label for coordinate type
    $labelCoordType = New-Object System.Windows.Forms.Label
    $labelCoordType.Location = New-Object System.Drawing.Point(10, 15)
    $labelCoordType.Size = New-Object System.Drawing.Size(280, 20)
    $labelCoordType.Text = 'Filter by which coordinate?'
    $form.Controls.Add($labelCoordType)

    # RadioButton for Latitude (lat)
    $radioLat = New-Object System.Windows.Forms.RadioButton
    $radioLat.Location = New-Object System.Drawing.Point(20, 40)
    $radioLat.Size = New-Object System.Drawing.Size(120, 20)
    $radioLat.Text = 'Latitude (lat)'
    $radioLat.Checked = $true # Default selection
    $form.Controls.Add($radioLat)

    # RadioButton for Longitude (lon)
    $radioLon = New-Object System.Windows.Forms.RadioButton
    $radioLon.Location = New-Object System.Drawing.Point(150, 40)
    $radioLon.Size = New-Object System.Drawing.Size(120, 20)
    $radioLon.Text = 'Longitude (lon)'
    $form.Controls.Add($radioLon)

    # Label for filter value
    $labelFilterValue = New-Object System.Windows.Forms.Label
    $labelFilterValue.Location = New-Object System.Drawing.Point(10, 75)
    $labelFilterValue.Size = New-Object System.Drawing.Size(280, 20)
    $labelFilterValue.Text = 'Filter value (e.g., 52. for start):'
    $form.Controls.Add($labelFilterValue)

    # TextBox for filter value
    $textBoxFilterValue = New-Object System.Windows.Forms.TextBox
    $textBoxFilterValue.Location = New-Object System.Drawing.Point(10, 100)
    $textBoxFilterValue.Size = New-Object System.Drawing.Size(280, 20)
    $form.Controls.Add($textBoxFilterValue)

    # OK Button
    $buttonOK = New-Object System.Windows.Forms.Button
    $buttonOK.Location = New-Object System.Drawing.Point(110, 135)
    $buttonOK.Size = New-Object System.Drawing.Size(90, 25)
    $buttonOK.Text = 'OK'
    $buttonOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $buttonOK
    $form.Controls.Add($buttonOK)

    # Cancel Button
    $buttonCancel = New-Object System.Windows.Forms.Button
    $buttonCancel.Location = New-Object System.Drawing.Point(210, 135)
    $buttonCancel.Size = New-Object System.Drawing.Size(90, 25)
    $buttonCancel.Text = 'Cancel'
    $buttonCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $buttonCancel
    $form.Controls.Add($buttonCancel)

    # Show the form modally
    $result = $form.ShowDialog()
    $form.Dispose() # Dispose the form resources

    # Return results
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $selectedCoordType = if ($radioLat.Checked) { 'lat' } else { 'lon' }
        $filterValue = $textBoxFilterValue.Text
        return [PSCustomObject]@{
            DialogResult    = $result
            CoordinateType  = $selectedCoordType
            CoordinateValue = $filterValue
        }
    } else {
         return [PSCustomObject]@{ DialogResult = $result } # Only return result on Cancel
    }
}

# --- Function to get Time Range from GPX data ---
function Get-GpxTimeRange {
    param(
        [System.Xml.XmlDocument]$GpxData,
        [System.Xml.XmlNamespaceManager]$NamespaceManager
    )

    $firstTime = $null
    $lastTime = $null
    $firstTimestamp = $null
    $lastTimestamp = $null

    # Select all time elements
    $allTimeNodes = $GpxData.SelectNodes("//gpx:wpt/gpx:time | //gpx:trkpt/gpx:time", $NamespaceManager)

    if ($allTimeNodes -and $allTimeNodes.Count -gt 0) {
        # Convert to DateTime objects and sort
        $allDateTimes = $allTimeNodes | ForEach-Object {
            try { [datetime]$_.InnerText } catch { Write-Warning "Could not parse time value: $($_.InnerText)" }
        } | Sort-Object

        if ($allDateTimes -and $allDateTimes.Count -gt 0) {
             $firstTime = $allDateTimes[0]
             $lastTime = $allDateTimes[-1]
             # Convert to Unix timestamp (UTC)
             $firstTimestamp = [int64]($firstTime.ToUniversalTime() - [datetime]'1970-01-01 00:00:00Z').TotalSeconds
             $lastTimestamp = [int64]($lastTime.ToUniversalTime() - [datetime]'1970-01-01 00:00:00Z').TotalSeconds
        }
    }

    # Return results as an object
    return [PSCustomObject]@{
        FirstTime       = $firstTime
        LastTime        = $lastTime
        FirstTimestamp  = $firstTimestamp
        LastTimestamp   = $lastTimestamp
    }
}

# --- Function to Display Output in a Selectable Text Box ---
function Show-OutputWindow {
    param(
        [string]$OutputText,
        [string]$WindowTitle = "Script Results"
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $WindowTitle
    $form.Size = New-Object System.Drawing.Size(600, 450) # Increased height slightly for DELETE query text
    $form.StartPosition = 'CenterScreen'

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ReadOnly = $true
    $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $textBox.Font = New-Object System.Drawing.Font("Consolas", 9.75)
    $textBox.Text = $OutputText
    $form.Controls.Add($textBox)

    $buttonClose = New-Object System.Windows.Forms.Button
    $buttonClose.Text = "Close"
    $buttonClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $buttonClose.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $form.Controls.Add($buttonClose)
    $form.CancelButton = $buttonClose

    # Show the form
    $form.ShowDialog() | Out-Null
    $form.Dispose() # Clean up resources
}


# --- Main Script Body ---

# --- Part 1: Select GPX File ---
$openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
$openFileDialog.Title = "Please select a GPX file"
$openFileDialog.Filter = "GPX Files (*.gpx)|*.gpx|All Files (*.*)|*.*"

$result = $openFileDialog.ShowDialog()
$openFileDialog.Dispose()

if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Warning "No file selected. Script will exit."
    [System.Windows.Forms.MessageBox]::Show("No file selected. Script will exit.", "Operation Canceled", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    Exit
}
$gpxFilePath = $openFileDialog.FileName
Write-Host "Selected file: $gpxFilePath"

# --- Part 2: Get Filter Settings via GUI ---
$filterInput = Get-FilterInput
if ($filterInput.DialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
     Write-Warning "Filter input canceled. Script will exit."
     [System.Windows.Forms.MessageBox]::Show("Filter input canceled. Script will exit.", "Operation Canceled", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
     Exit
}
$coordinateType = $filterInput.CoordinateType
$coordinateValue = $filterInput.CoordinateValue
# Basic check: Ensure coordinate value doesn't contain obvious SQL injection chars like ';'. A more robust check would be needed for production.
if ($coordinateValue -match "[;']" ) {
     Write-Error "Filter value contains potentially unsafe characters (;,'). Please use only valid coordinate prefixes."
     [System.Windows.Forms.MessageBox]::Show("Filter value contains potentially unsafe characters (;,'). Please use only valid coordinate prefixes.", "Invalid Filter Value", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
     Exit
}

if (-not [string]::IsNullOrWhiteSpace($coordinateValue)) {
    Write-Host "Filter settings: Type='$coordinateType', Value starts with='$coordinateValue'"
} else {
    Write-Host "No filter value provided. Skipping cleanup step."
}

# --- Part 3: Load GPX, Analyze Original Timestamps, Clean, Analyze Cleaned Timestamps ---
$outputLines = @()
$outputLines += "--- GPX File Processing ---"
$outputLines += "File: $gpxFilePath"
$outputLines += "Filter Type: $(if ([string]::IsNullOrWhiteSpace($coordinateValue)) {'None'} else {$coordinateType})"
$outputLines += "Filter Value (Starts With): $(if ([string]::IsNullOrWhiteSpace($coordinateValue)) {'N/A'} else {$coordinateValue})"
$outputLines += ""

try {
    # Load the GPX file
    Write-Host "Loading GPX file..."
    [xml]$gpx = Get-Content -Path $gpxFilePath

    # Create namespace manager
    $ns = New-Object System.Xml.XmlNamespaceManager($gpx.NameTable)
    $ns.AddNamespace("gpx", "http://www.topografix.com/GPX/1/1")

    # === Analyze ORIGINAL Time Range ===
    Write-Host "Analyzing original time range..."
    $originalTimeRange = Get-GpxTimeRange -GpxData $gpx -NamespaceManager $ns
    $outputLines += "--- Original Time Range (Before Cleaning) ---"
    if ($originalTimeRange.FirstTimestamp -ne $null) {
        $outputLines += "First Point (Original): $($originalTimeRange.FirstTime.ToString("yyyy-MM-dd HH:mm:ss")) (Timestamp UTC: $($originalTimeRange.FirstTimestamp))"
        $outputLines += "Last Point (Original):  $($originalTimeRange.LastTime.ToString("yyyy-MM-dd HH:mm:ss")) (Timestamp UTC: $($originalTimeRange.LastTimestamp))"
    } else {
        $outputLines += "No time information found in the original file."
    }
    $outputLines += ""

    # === Perform Cleaning ===
    $changesMade = $false
    $pointsRemovedCount = 0
    if (-not [string]::IsNullOrWhiteSpace($coordinateValue)) {
        Write-Host "Searching for points to remove..."
        $xpathQuery = "//gpx:wpt[starts-with(@$coordinateType, '$coordinateValue')] | //gpx:trkpt[starts-with(@$coordinateType, '$coordinateValue')]"
        $pointsToRemove = $gpx.SelectNodes($xpathQuery, $ns)
        $pointsRemovedCount = $pointsToRemove.Count
        Write-Host "Found $pointsRemovedCount points to remove."

        if ($pointsToRemove.Count -gt 0) {
            foreach ($point in $pointsToRemove) {
                $point.ParentNode.RemoveChild($point) | Out-Null
            }
            $changesMade = $true
            $outputLines += "--- Cleaning Result ---"
            $outputLines += "$pointsRemovedCount points whose '$coordinateType' coordinate starts with '$coordinateValue' were removed (in memory)."
            $outputLines += ""
        } else {
            $outputLines += "--- Cleaning Result ---"
            $outputLines += "No points found matching the filter criteria."
            $outputLines += ""
        }
    } else {
         $outputLines += "--- Cleaning Result ---"
         $outputLines += "Cleanup step skipped as no filter value was provided."
         $outputLines += ""
    }

    # === Analyze AFTER Cleaning ===
    Write-Host "Analyzing data after potential cleaning..."
    $cleanedTimeRange = Get-GpxTimeRange -GpxData $gpx -NamespaceManager $ns
    $waypointCount = $gpx.SelectNodes("//gpx:wpt", $ns).Count
    $trackpointCount = $gpx.SelectNodes("//gpx:trkpt", $ns).Count

    $outputLines += "--- Analysis Results (After Cleaning) ---"
    $outputLines += "Number of waypoints remaining: $waypointCount"
    $outputLines += "Number of trackpoints remaining: $trackpointCount"
    if ($cleanedTimeRange.FirstTimestamp -ne $null) {
        $outputLines += "First Point (Cleaned): $($cleanedTimeRange.FirstTime.ToString("yyyy-MM-dd HH:mm:ss")) (Timestamp UTC: $($cleanedTimeRange.FirstTimestamp))"
        $outputLines += "Last Point (Cleaned):  $($cleanedTimeRange.LastTime.ToString("yyyy-MM-dd HH:mm:ss")) (Timestamp UTC: $($cleanedTimeRange.LastTimestamp))"
    } else {
        $outputLines += "No time information found in the cleaned data."
    }
    $outputLines += ""


    # === Generate SQL Queries ===
    $outputLines += "--- Example PostgreSQL Queries ---"
    # SELECT Query (uses timestamps from the CLEANED data)
    if ($cleanedTimeRange.FirstTimestamp -ne $null) {
        $outputLines += "# Select points within the timestamp range of the *cleaned* data:"
        $outputLines += "SELECT * FROM your_table_name WHERE timestamp_column BETWEEN $($cleanedTimeRange.FirstTimestamp) AND $($cleanedTimeRange.LastTimestamp);"
        $outputLines += ""
    } else {
        $outputLines += "# Cannot generate SELECT query: No time information found in cleaned data."
        $outputLines += ""
    }

    # DELETE Query (uses ORIGINAL timestamps AND the coordinate filter)
    $outputLines += "# Delete points matching the filter criteria within the *original* time range:"
    if (-not [string]::IsNullOrWhiteSpace($coordinateValue) -and $originalTimeRange.FirstTimestamp -ne $null) {
        # Determine the coordinate column placeholder based on the filter type
        $coordColumnPlaceholder = if ($coordinateType -eq 'lat') { 'your_latitude_column' } else { 'your_longitude_column' }

        # Construct the specific DELETE query
        $outputLines += "-- !!! WARNING: EXECUTE DELETE STATEMENTS WITH EXTREME CAUTION !!! --"
        $outputLines += "-- Ensure 'your_table_name', 'timestamp_column', and '$coordColumnPlaceholder' are correct! --"
        $outputLines += "DELETE FROM your_table_name"
        $outputLines += "WHERE timestamp_column BETWEEN $($originalTimeRange.FirstTimestamp) AND $($originalTimeRange.LastTimestamp)"
        # Add the crucial coordinate filter condition
        $outputLines += "  AND $coordColumnPlaceholder::text LIKE '$($coordinateValue)%';" # Use ::text cast for LIKE on numeric types if needed
        $outputLines += "-- The '::text' cast might be needed if your coordinate column is numeric. Adjust as necessary. --"

    } elseif ([string]::IsNullOrWhiteSpace($coordinateValue)) {
        $outputLines += "-- DELETE query targeting specific coordinates skipped: No filter value was provided. --"
    } else { # No filter value was provided, but original timestamps might be null
        $outputLines += "-- Cannot generate specific DELETE query: No time information found in original data or no filter value provided. --"
    }
    $outputLines += "---------------------------------------"


    # --- Part 4: Save the Cleaned File ---
    if ($changesMade) {
        Write-Host "Changes were made to the data in memory."
        $confirmResult = [System.Windows.Forms.MessageBox]::Show(
            "Save changes and overwrite the original file '$($gpxFilePath)'?",
            "Confirm Save",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirmResult -eq [System.Windows.Forms.DialogResult]::Yes) {
             try {
                Write-Host "Saving changes to $gpxFilePath..."
                $gpx.Save($gpxFilePath)
                Write-Host "File saved successfully."
                $outputLines += "`n--- File Saving ---"
                $outputLines += "Changes were saved successfully to: $gpxFilePath"
                [System.Windows.Forms.MessageBox]::Show("File saved successfully.", "Save Successful", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
             } catch {
                 $saveErrorMessage = "Error saving file: $($_.Exception.Message)"
                 Write-Error $saveErrorMessage
                 $outputLines += "`n--- File Saving ---"
                 $outputLines += "ERROR saving file: $saveErrorMessage"
                 [System.Windows.Forms.MessageBox]::Show($saveErrorMessage, "Save Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
             }
        } else {
            Write-Warning "Save operation canceled by user. The original file was not overwritten."
            $outputLines += "`n--- File Saving ---"
            $outputLines += "Save operation canceled by user. File not overwritten."
        }
    } else {
        Write-Host "No changes requiring saving were made."
        $outputLines += "`n--- File Saving ---"
        $outputLines += "No changes required saving."
        # Optional: Show info message box
        # [System.Windows.Forms.MessageBox]::Show("No points were found for removal or the filter value was empty. The file was not modified.", "No Changes", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }

} catch {
    # Catch unexpected errors
    $errorMessage = "A critical error occurred during processing: $($_.Exception.Message)`n$($_.Exception.StackTrace)"
    Write-Error $errorMessage
    $outputLines += "`n--- CRITICAL ERROR ---"
    $outputLines += $errorMessage
     [System.Windows.Forms.MessageBox]::Show($errorMessage, "Script Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
     if ($_.InvocationInfo) { Write-Error "Error on line: $($_.InvocationInfo.ScriptLineNumber)" }
} finally {

    # --- Part 5: Display Collected Output ---
    Write-Host "Processing complete. Displaying results window..."
    $finalOutputString = $outputLines -join [Environment]::NewLine
    Show-OutputWindow -OutputText $finalOutputString -WindowTitle "GPX Processing Results for $($gpxFilePath)"

    Write-Host "Script finished."
}