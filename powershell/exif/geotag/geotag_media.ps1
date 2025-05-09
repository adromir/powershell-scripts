<#
.SYNOPSIS
Searches a selected folder for image and MP4 files, optionally updating GPS and location metadata for better compatibility with Google Photos.
For Images: Updates standard GPS tags, XMP GPS tags, country, city, country code. Writes to existing XMP sidecar if present, otherwise writes to image file directly.
For MP4s: Updates ONLY GPS coordinates directly into the MP4 file using Google Photos preferred tags ('UserData:GPSCoordinates', 'GPSAltitude', 'Rotation'), overwriting the original. Country/City/Code are NOT written to MP4s.
Queries a primary API (Dawarich) for location data based on a time window around the file's creation date.
Optionally uses reverse geocoding via a secondary API (Photon) if primary data is missing or user chooses to always query.
Writes the found data using exiftool.
Includes a GUI for configuration and options.
Outputs lists of skipped files at the end.

.DESCRIPTION
This script performs the following steps:
1.  Checks for a configuration file (config.json) and loads settings if found. Handles backward compatibility for renamed API keys.
2.  Displays a GUI window for configuration:
    - Dawarich API URL
    - Dawarich API Key
    - Photon API URL (for reverse geocoding)
    - Default Time Window (seconds)
    - Option to Save Configuration
    - Option to Overwrite Existing EXIF Data (Applies to relevant tags for images and MP4s)
    - Option to Always Query Photon API for Location Details (Photon results used for Country/City/Code for images, but NOT written to MP4s)
3.  If the user clicks OK in the GUI:
    - Saves the configuration if requested.
    - Prompts the user to select a folder to scan using a GUI.
    - Searches the selected folder for supported image/video files.
    - Reads EXIF/XMP/UserData tags for each file using exiftool.
    - Determines if a file needs processing based on missing relevant GPS data OR the "Overwrite" flag.
    - If processing is needed:
        a. Determines the creation date.
        b. Queries the configured Dawarich API using a time window around the creation date.
        c. Selects the closest valid match within the time window.
        d. If coordinates found:
            i.   Optionally queries Photon API for missing country/city/country code (for images), or if 'Always Query Photon' is checked. Photon results take precedence if this option is checked (for images).
            ii.  Writes data using exiftool:
                 - For MP4 files: Writes ONLY GPS data using 'UserData:GPSCoordinates' (formatted to 4 decimal places), 'GPSAltitude=0', and 'Rotation=0' directly into the MP4 file using -overwrite_original.
                 - For Image files: Writes standard GPS*, XMP:GPS*, Country, City, and Country Code (XMP tag). Data is written to an existing .xmp sidecar if found, otherwise directly into the image file using -overwrite_original.
        e. If no suitable coordinates are found via the API, the file is added to a "skipped (no API data)" list.
    - If processing is not needed (data exists, overwrite off), the file is added to a "skipped (already has data)" list.
4.  Outputs status messages during processing, including warnings for large files.
5.  Outputs a final summary including counts of processed, updated, and error files, followed by lists of skipped files (if any).

.NOTES
Ensure that exiftool.exe is either in the system PATH or the full path is specified correctly (now defaults or via config file/GUI).
The API keys and URLs are now primarily managed via the GUI and optional config file.
Processing large video files can be slow due to I/O limitations.
Writing data overwrites the original files (using exiftool -overwrite_original) for MP4s and for images that do NOT have an existing XMP sidecar. If an image sidecar exists, it will be updated instead. It is strongly recommended to back up your files beforehand!
The configuration file (config.json) stores settings, including the API key, in plain text in the script's directory. Handle this file with care.
MP4 tags ('UserData:GPSCoordinates', 'GPSAltitude', 'Rotation') are based on common requirements for Google Photos compatibility.
Image tags include standard EXIF GPS and XMP GPS for broad compatibility.
#>

#region Configuration Defaults & File Handling
# ================== CONFIGURATION DEFAULTS & FILE HANDLING ==================

# Default values (used if config file not found or value missing)
$defaultConfig = @{
    dawarichApiUrl = "https://your-api-host.com/api/v1/points" # Renamed
    dawarichApiKey = "YOUR_API_KEY" # Renamed
    photonApiUrl = "https://photon.komoot.io" # Renamed
    defaultTimeWindowSeconds = 60
    exiftoolPath = "exiftool.exe" # Default assumption: exiftool is in PATH
    overwriteExisting = $false # Default behavior is NOT to overwrite
    # exiftoolTimeoutMs = 300000 # Removed timeout setting
    alwaysQueryPhoton = $false # Default: Only query Photon if Dawarich data is missing
}

# Configuration file path (in the script's directory)
# Ensure $PSScriptRoot is valid, provide fallback if running interactively/ISE
if ($PSScriptRoot) {
    $configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
} else {
    # Fallback if $PSScriptRoot is not available (e.g., running selection in ISE)
    $configFilePath = Join-Path -Path (Get-Location) -ChildPath "config.json"
    Write-Warning "Variable `$PSScriptRoot not found. Using current directory for config file: $configFilePath"
}


# Function to load configuration
# ** MODIFIED ** to handle old key names for backward compatibility
function Load-Configuration {
    param(
        [string]$FilePath,
        [hashtable]$Defaults
    )
    $config = $Defaults.Clone() # Start with defaults
    $loadedConfig = $null
    if (Test-Path -Path $FilePath -PathType Leaf) {
        Write-Verbose "Loading configuration from $FilePath"
        try {
            $loadedConfig = Get-Content -Path $FilePath -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warning "Failed to load or parse configuration file '$FilePath'. Using defaults. Error: $($_.Exception.Message)"
            # Keep $loadedConfig as $null, defaults will be used
        }
    } else {
        Write-Verbose "Configuration file '$FilePath' not found. Using defaults."
    }

    # Process known keys, checking for old names as fallbacks
    if ($loadedConfig -ne $null) {
        # Dawarich API URL (Check new name, then old name)
        if ($loadedConfig.PSObject.Properties.Name -contains 'dawarichApiUrl') {
            $config.dawarichApiUrl = $loadedConfig.dawarichApiUrl
        } elseif ($loadedConfig.PSObject.Properties.Name -contains 'gpsApiUrl') { # Fallback to old name
            $config.dawarichApiUrl = $loadedConfig.gpsApiUrl
            Write-Verbose "Using value from old config key 'gpsApiUrl' for 'dawarichApiUrl'."
        }

        # Dawarich API Key (Check new name, then old name)
        if ($loadedConfig.PSObject.Properties.Name -contains 'dawarichApiKey') {
            $config.dawarichApiKey = $loadedConfig.dawarichApiKey
        } elseif ($loadedConfig.PSObject.Properties.Name -contains 'gpsApiKey') { # Fallback to old name
            $config.dawarichApiKey = $loadedConfig.gpsApiKey
            Write-Verbose "Using value from old config key 'gpsApiKey' for 'dawarichApiKey'."
        }

        # Photon API URL (Check new name, then old name)
        if ($loadedConfig.PSObject.Properties.Name -contains 'photonApiUrl') {
            $config.photonApiUrl = $loadedConfig.photonApiUrl
        } elseif ($loadedConfig.PSObject.Properties.Name -contains 'komootApiUrl') { # Fallback to old name
            $config.photonApiUrl = $loadedConfig.komootApiUrl
            Write-Verbose "Using value from old config key 'komootApiUrl' for 'photonApiUrl'."
        }

        # Other settings (use value if key exists, otherwise default is kept)
        if ($loadedConfig.PSObject.Properties.Name -contains 'defaultTimeWindowSeconds') { $config.defaultTimeWindowSeconds = $loadedConfig.defaultTimeWindowSeconds }
        if ($loadedConfig.PSObject.Properties.Name -contains 'exiftoolPath') { $config.exiftoolPath = $loadedConfig.exiftoolPath }
        if ($loadedConfig.PSObject.Properties.Name -contains 'overwriteExisting') { $config.overwriteExisting = $loadedConfig.overwriteExisting }
        if ($loadedConfig.PSObject.Properties.Name -contains 'alwaysQueryPhoton') { $config.alwaysQueryPhoton = $loadedConfig.alwaysQueryPhoton }
        # Old timeout setting is ignored if present
    }

    # Ensure numeric/boolean types are correct after potentially loading from JSON (which might make them strings/objects)
    try { $config.defaultTimeWindowSeconds = [int]$config.defaultTimeWindowSeconds } catch { Write-Warning "Invalid value '($($config.defaultTimeWindowSeconds))' for defaultTimeWindowSeconds. Using default $($Defaults.defaultTimeWindowSeconds)."; $config.defaultTimeWindowSeconds = [int]$Defaults.defaultTimeWindowSeconds }
    try { $config.overwriteExisting = [bool]::Parse($config.overwriteExisting.ToString()) } catch { Write-Warning "Invalid value '($($config.overwriteExisting))' for overwriteExisting. Using default $($Defaults.overwriteExisting)."; $config.overwriteExisting = [bool]$Defaults.overwriteExisting }
    try { $config.alwaysQueryPhoton = [bool]::Parse($config.alwaysQueryPhoton.ToString()) } catch { Write-Warning "Invalid value '($($config.alwaysQueryPhoton))' for alwaysQueryPhoton. Using default $($Defaults.alwaysQueryPhoton)."; $config.alwaysQueryPhoton = [bool]$Defaults.alwaysQueryPhoton }

    return $config
}


# Function to save configuration
function Save-Configuration {
    param(
        [string]$FilePath,
        [hashtable]$ConfigData
    )
    Write-Verbose "Saving configuration to $FilePath"
    try {
        # Ensure all expected keys exist before saving
        $dataToSave = $ConfigData.Clone() # Work on a copy
        # Remove timeout if it somehow exists in the input hashtable
        if ($dataToSave.ContainsKey('exiftoolTimeoutMs')) { $dataToSave.Remove('exiftoolTimeoutMs') }
        # Ensure other default keys are present
        foreach($key in $defaultConfig.Keys){
             if (-not $dataToSave.ContainsKey($key)){
                 $dataToSave[$key] = $defaultConfig[$key] # Add missing key with default value
             }
        }
        # Remove old keys before saving to avoid confusion
        $dataToSave.Remove('gpsApiUrl') | Out-Null
        $dataToSave.Remove('gpsApiKey') | Out-Null
        $dataToSave.Remove('komootApiUrl') | Out-Null

        $dataToSave | ConvertTo-Json -Depth 3 | Set-Content -Path $FilePath -Encoding UTF8 -ErrorAction Stop
        Write-Host "Configuration saved successfully." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to save configuration file '$FilePath'. Error: $($_.Exception.Message)"
    }
}

# ================== END CONFIGURATION DEFAULTS & FILE HANDLING ==================
#endregion Configuration Defaults & File Handling

#region GUI Function
# ================== GUI FUNCTION ==================
function Show-ConfigurationGui {
    param(
        [hashtable]$InitialConfig
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --- Create Form ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "EXIF Updater Configuration"
    $form.Size = New-Object System.Drawing.Size(450, 390) # Adjusted height
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    # --- Controls ---
    $yPos = 15
    $labelWidth = 150
    $textboxWidth = 250
    $controlHeight = 20
    $spacing = 5

    # Dawarich API URL
    $labelDawarichUrl = New-Object System.Windows.Forms.Label
    $labelDawarichUrl.Location = New-Object System.Drawing.Point(10, $yPos)
    $labelDawarichUrl.Size = New-Object System.Drawing.Size($labelWidth, $controlHeight)
    $labelDawarichUrl.Text = "Dawarich API URL:" # Renamed
    $form.Controls.Add($labelDawarichUrl)

    $textboxDawarichUrl = New-Object System.Windows.Forms.TextBox
    $textboxDawarichUrl.Location = New-Object System.Drawing.Point((10 + $labelWidth + $spacing), $yPos)
    $textboxDawarichUrl.Size = New-Object System.Drawing.Size($textboxWidth, $controlHeight)
    $textboxDawarichUrl.Text = $InitialConfig.dawarichApiUrl # Renamed
    $form.Controls.Add($textboxDawarichUrl)
    $yPos += $controlHeight + $spacing

    # Dawarich API Key
    $labelDawarichKey = New-Object System.Windows.Forms.Label
    $labelDawarichKey.Location = New-Object System.Drawing.Point(10, $yPos)
    $labelDawarichKey.Size = New-Object System.Drawing.Size($labelWidth, $controlHeight)
    $labelDawarichKey.Text = "Dawarich API Key:" # Renamed
    $form.Controls.Add($labelDawarichKey)

    $textboxDawarichKey = New-Object System.Windows.Forms.TextBox
    $textboxDawarichKey.Location = New-Object System.Drawing.Point((10 + $labelWidth + $spacing), $yPos)
    $textboxDawarichKey.Size = New-Object System.Drawing.Size($textboxWidth, $controlHeight)
    $textboxDawarichKey.Text = $InitialConfig.dawarichApiKey # Renamed
    $form.Controls.Add($textboxDawarichKey)
    $yPos += $controlHeight + $spacing

    # Photon API URL
    $labelPhotonUrl = New-Object System.Windows.Forms.Label
    $labelPhotonUrl.Location = New-Object System.Drawing.Point(10, $yPos)
    $labelPhotonUrl.Size = New-Object System.Drawing.Size($labelWidth, $controlHeight)
    $labelPhotonUrl.Text = "Photon API URL:" # Renamed
    $form.Controls.Add($labelPhotonUrl)

    $textboxPhotonUrl = New-Object System.Windows.Forms.TextBox
    $textboxPhotonUrl.Location = New-Object System.Drawing.Point((10 + $labelWidth + $spacing), $yPos)
    $textboxPhotonUrl.Size = New-Object System.Drawing.Size($textboxWidth, $controlHeight)
    $textboxPhotonUrl.Text = $InitialConfig.photonApiUrl # Renamed
    $form.Controls.Add($textboxPhotonUrl)
    $yPos += $controlHeight + $spacing

    # Time Window
    $labelTimeWindow = New-Object System.Windows.Forms.Label
    $labelTimeWindow.Location = New-Object System.Drawing.Point(10, $yPos)
    $labelTimeWindow.Size = New-Object System.Drawing.Size($labelWidth, $controlHeight)
    $labelTimeWindow.Text = "API Time Window (seconds):"
    $form.Controls.Add($labelTimeWindow)

    $textboxTimeWindow = New-Object System.Windows.Forms.TextBox
    $textboxTimeWindow.Location = New-Object System.Drawing.Point((10 + $labelWidth + $spacing), $yPos)
    $textboxTimeWindow.Size = New-Object System.Drawing.Size(80, $controlHeight) # Smaller width
    $textboxTimeWindow.Text = $InitialConfig.defaultTimeWindowSeconds
    $form.Controls.Add($textboxTimeWindow)
    $yPos += $controlHeight + $spacing

    # Exiftool Timeout - Removed

    # Exiftool Path
    $labelExiftool = New-Object System.Windows.Forms.Label
    $labelExiftool.Location = New-Object System.Drawing.Point(10, $yPos)
    $labelExiftool.Size = New-Object System.Drawing.Size($labelWidth, $controlHeight)
    $labelExiftool.Text = "Exiftool Path:"
    $form.Controls.Add($labelExiftool)

    $textboxExiftool = New-Object System.Windows.Forms.TextBox
    $textboxExiftool.Location = New-Object System.Drawing.Point((10 + $labelWidth + $spacing), $yPos)
    $textboxExiftool.Size = New-Object System.Drawing.Size($textboxWidth, $controlHeight)
    $textboxExiftool.Text = $InitialConfig.exiftoolPath
    $form.Controls.Add($textboxExiftool)
    $yPos += $controlHeight + $spacing + 10 # Extra spacing


    # Overwrite Checkbox
    $checkboxOverwrite = New-Object System.Windows.Forms.CheckBox
    $checkboxOverwrite.Location = New-Object System.Drawing.Point(15, $yPos)
    $checkboxOverwrite.Size = New-Object System.Drawing.Size(400, $controlHeight)
    # Updated text to be more generic about GPS tags
    $checkboxOverwrite.Text = "Overwrite existing GPS/Location data in files"
    $checkboxOverwrite.Checked = $InitialConfig.overwriteExisting
    $form.Controls.Add($checkboxOverwrite)
    $yPos += $controlHeight + $spacing

    # Always Query Photon Checkbox
    $checkboxAlwaysQueryPhoton = New-Object System.Windows.Forms.CheckBox
    $checkboxAlwaysQueryPhoton.Location = New-Object System.Drawing.Point(15, $yPos)
    $checkboxAlwaysQueryPhoton.Size = New-Object System.Drawing.Size(400, $controlHeight)
    $checkboxAlwaysQueryPhoton.Text = "Always query Photon API (overwrites Dawarich location details for Images)" # Updated text
    $checkboxAlwaysQueryPhoton.Checked = $InitialConfig.alwaysQueryPhoton
    $form.Controls.Add($checkboxAlwaysQueryPhoton)
    $yPos += $controlHeight + $spacing

    # Save Config Checkbox
    $checkboxSaveConfig = New-Object System.Windows.Forms.CheckBox
    $checkboxSaveConfig.Location = New-Object System.Drawing.Point(15, $yPos)
    $checkboxSaveConfig.Size = New-Object System.Drawing.Size(400, $controlHeight)
    $checkboxSaveConfig.Text = "Save these settings to config.json (in script directory)"
    $checkboxSaveConfig.Checked = $false # Default to not saving unless user checks it
    $form.Controls.Add($checkboxSaveConfig)
    $yPos += $controlHeight + $spacing + 15 # Extra spacing before buttons

    # --- Buttons ---
    $buttonOK = New-Object System.Windows.Forms.Button
    $buttonOK.Location = New-Object System.Drawing.Point(130, $yPos)
    $buttonOK.Size = New-Object System.Drawing.Size(80, 30)
    $buttonOK.Text = "OK"
    $buttonOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $buttonOK
    $form.Controls.Add($buttonOK)

    $buttonCancel = New-Object System.Windows.Forms.Button
    $buttonCancel.Location = New-Object System.Drawing.Point(230, $yPos)
    $buttonCancel.Size = New-Object System.Drawing.Size(80, 30)
    $buttonCancel.Text = "Cancel"
    $buttonCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $buttonCancel
    $form.Controls.Add($buttonCancel)

    # --- Show Dialog ---
    # Make the form topmost to ensure it appears above other windows like the console
    $form.TopMost = $true
    $result = $form.ShowDialog()
    $form.Dispose() # Dispose of the form resources after closing

    # --- Process Result ---
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        # Validate numeric inputs
        $timeWindowValid = $textboxTimeWindow.Text -match "^\d+$"
        # $timeoutValid = $textboxTimeout.Text -match "^\d+$" -and ([int]$textboxTimeout.Text) -gt 0 # Removed timeout validation

        if (-not $timeWindowValid) { # Removed timeout validation
             $errorMsg = "Invalid input:`n"
             if (-not $timeWindowValid) { $errorMsg += "- Time Window must be a non-negative integer.`n"}
             # if (-not $timeoutValid) { $errorMsg += "- Exiftool Timeout must be a positive integer (milliseconds).`n"}
             [System.Windows.Forms.MessageBox]::Show($errorMsg, "Input Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return $null # Indicate validation failure
        }

        $outputConfig = @{
            dawarichApiUrl = $textboxDawarichUrl.Text # Renamed
            dawarichApiKey = $textboxDawarichKey.Text # Renamed
            photonApiUrl = $textboxPhotonUrl.Text     # Renamed
            defaultTimeWindowSeconds = [int]$textboxTimeWindow.Text
            # exiftoolTimeoutMs = [int]$textboxTimeout.Text # Removed
            exiftoolPath = $textboxExiftool.Text
            overwriteExisting = $checkboxOverwrite.Checked
            alwaysQueryPhoton = $checkboxAlwaysQueryPhoton.Checked # Added
            saveConfig = $checkboxSaveConfig.Checked
        }
        return $outputConfig
    } else {
        # User cancelled
        return $null
    }
}
# ================== END GUI FUNCTION ==================
#endregion GUI Function


#region Helper Functions (Select-FolderDialog, ConvertTo-ApiTimestamp, Get-DawarichDataFromApi, Get-LocationFromPhoton, Set-ExifData)
# Function to select a folder via GUI
function Select-FolderDialog {
    param(
        [string]$Description = "Select a folder",
        [string]$InitialDirectory = ([Environment]::GetFolderPath("MyPictures"))
    )
    Add-Type -AssemblyName System.Windows.Forms # Ensure loaded
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = $Description
    $folderBrowser.SelectedPath = $InitialDirectory
    $folderBrowser.ShowNewFolderButton = $false
    if ($folderBrowser.ShowDialog((New-Object System.Windows.Forms.Form -Property @{TopMost = $true })) -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    }
    else {
        Write-Warning "No folder selected. Exiting script."
        exit # Exit if folder selection is cancelled
    }
}

# Function to convert EXIF date/time to ISO8601 UTC
function ConvertTo-ApiTimestamp {
    param(
        [string]$ExifDateTimeString
    )
    if ([string]::IsNullOrWhiteSpace($ExifDateTimeString)) {
        return $null
    }
    # EXIF format is often 'YYYY:MM:DD HH:MM:SS' or similar
    # Handle potential sub-second values and timezone offsets returned by exiftool
    $ExifDateTimeString = $ExifDateTimeString -replace '([+-]\d{2}):(\d{2})$', '$1$2' # Remove colon in timezone offset like +02:00 -> +0200
    $cleanedString = $ExifDateTimeString.Split('.')[0] # Remove subseconds for initial parsing
    $cleanedString = $cleanedString -replace ":", "-" -replace " ", "T"

    $formats = @(
        "yyyy-MM-ddTHH-mm-ss",
        "yyyy-MM-ddTHH-mm-sszzz", # Format with timezone offset like +0200
        "yyyy-MM-ddTHH-mm-ssZ"   # Format with Z for UTC
    )
    $parsedDate = $null
    foreach ($format in $formats) {
        try {
            # Use InvariantCulture to avoid issues with regional settings for separators
            # Adjust styles based on format
            $style = [System.Globalization.DateTimeStyles]::None
            if ($format.EndsWith("zzz")) { $style = [System.Globalization.DateTimeStyles]::AdjustToUniversal } # Handle offset
            elseif ($format.EndsWith("Z")) { $style = [System.Globalization.DateTimeStyles]::AdjustToUniversal } # Handle Z

            $parsedDate = [datetime]::ParseExact($cleanedString, $format, [System.Globalization.CultureInfo]::InvariantCulture, $style)
            break # Successfully parsed
        } catch {
            # Ignore the error and try the next format
        }
    }

    if ($parsedDate) {
        # Convert to UTC and format for the API
        try {
             # If parsed without timezone or Z, assume it's Local and convert
             if ($parsedDate.Kind -eq [System.DateTimeKind]::Unspecified) {
                 $parsedDate = [DateTime]::SpecifyKind($parsedDate, [DateTimeKind]::Local)
             }
             # Ensure the final object is UTC before formatting
             return $parsedDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        } catch {
             Write-Warning "Error converting date '$ExifDateTimeString' to UTC: $($_.Exception.Message)"
             return $null
        }
    } else {
        Write-Warning "Could not parse date '$ExifDateTimeString' with known formats."
        return $null
    }
}

# Function to call the Dawarich API (Renamed from Get-GpsDataFromApi)
function Get-DawarichDataFromApi {
    param(
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$StartAt,
        [string]$EndAt
    )
    # Ensure proper URL encoding for date/time strings
    $encodedStartAt = [System.Web.HttpUtility]::UrlEncode($StartAt)
    $encodedEndAt = [System.Web.HttpUtility]::UrlEncode($EndAt)
    $apiUrlEffective = "$BaseUrl`?api_key=$ApiKey`&start_at=$encodedStartAt`&end_at=$encodedEndAt`&order=asc"

    Write-Verbose "Querying Dawarich API: $apiUrlEffective"
    try {
        $response = Invoke-RestMethod -Uri $apiUrlEffective -Method Get -TimeoutSec 120 -ErrorAction Stop
        return $response
    }
    catch {
        Write-Error "Error querying Dawarich API ($apiUrlEffective): $($_.Exception.Message)"
        if ($_.Exception.Response) {
             try {
                 $stream = $_.Exception.Response.GetResponseStream()
                 $reader = New-Object System.IO.StreamReader($stream)
                 $responseBody = $reader.ReadToEnd();
                 Write-Error "API Response Body: $responseBody"
             } catch { Write-Error "Could not read error response body." }
        }
        return $null
    }
}

# Function to call the Photon API for Reverse Geocoding (Renamed from Get-LocationFromKomoot)
function Get-LocationFromPhoton {
    param(
        [string]$BaseUrl,
        [double]$Latitude,
        [double]$Longitude
    )
    # Convert Latitude/Longitude to the format expected
    $latStr = $Latitude.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $lonStr = $Longitude.ToString([System.Globalization.CultureInfo]::InvariantCulture)

    $photonReverseUrl = "$BaseUrl/reverse?lat=$latStr&lon=$lonStr"
    Write-Verbose "Querying Photon API: $photonReverseUrl"
    try {
        $response = Invoke-RestMethod -Uri $photonReverseUrl -Method Get -TimeoutSec 60 -ErrorAction Stop
        # Extract data
        $country = $null
        $city = $null
        $countryCode = $null # Added
        if ($response.features -ne $null -and $response.features.Count -gt 0) {
             $props = $response.features[0].properties
             if ($props -ne $null) {
                 $country = $props.country
                 $city = $props.city
                 $countryCode = $props.countrycode # Added

                 # Fallbacks for city
                 if ([string]::IsNullOrWhiteSpace($city)) { $city = $props.county }
                 if ([string]::IsNullOrWhiteSpace($city)) { $city = $props.state }
             }
        } else {
            Write-Warning "Photon API response did not contain expected 'features' data."
        }

        return @{
            Country = $country
            City = $city
            CountryCode = $countryCode # Added
        }
    }
    catch {
        Write-Error "Error querying Photon API ($photonReverseUrl): $($_.Exception.Message)"
         if ($_.Exception.Response) {
             try {
                 $stream = $_.Exception.Response.GetResponseStream()
                 $reader = New-Object System.IO.StreamReader($stream)
                 $responseBody = $reader.ReadToEnd();
                 Write-Error "Photon API Response Body: $responseBody"
             } catch { Write-Error "Could not read error response body." }
        }
        return $null
    }
}

# Function to write EXIF/XMP data using exiftool
# ** MODIFIED **: Writes Google Photos compatible tags to MP4s. Writes standard/XMP GPS to Images.
function Set-ExifData {
    param(
        [string]$ExiftoolExePath,
        [string]$FilePath,
        [double]$Latitude,
        [double]$Longitude,
        [string]$Country, # Used only for images
        [string]$City,    # Used only for images
        [string]$CountryCode # Used only for images
        # Removed TimeoutMilliseconds parameter
    )

    $fileInfo = Get-Item -LiteralPath $FilePath
    $isMp4 = $fileInfo.Extension.ToLower() -eq ".mp4"

    # --- Determine Tags, Output Target, and Exiftool Arguments ---
    $tagArgs = @()
    $exifArgs = @()
    $outputTargetDescription = ""
    $xmpFilePath = ""

    if ($isMp4) {
        # --- MP4: Write Google Photos compatible tags ---
        $outputTargetDescription = "GPS (Google Photos format) into MP4 file '$($fileInfo.Name)'"

        # Format Latitude and Longitude for UserData:GPSCoordinates: "[+-]Lat.DDDD, [+-]Lon.DDDD, Alt"
        # Use InvariantCulture for decimal formatting to ensure '.' is used. Format to 4 decimal places.
        $latFormatted = ([Math]::Abs($Latitude)).ToString("F4", [System.Globalization.CultureInfo]::InvariantCulture)
        $lonFormatted = ([Math]::Abs($Longitude)).ToString("F4", [System.Globalization.CultureInfo]::InvariantCulture)
        $latSign = if ($Latitude -ge 0) { "+" } else { "-" }
        $lonSign = if ($Longitude -ge 0) { "+" } else { "-" }
        # Construct the string: +lat.dddd, +lon.dddd, 0 (altitude 0 assumed)
        $userDataGpsString = '"{0}{1}, {2}{3}, 0"' -f $latSign, $latFormatted, $lonSign, $lonFormatted

        # Define the tags for MP4
        $tagArgs = @(
            "-UserData:GPSCoordinates=$userDataGpsString",
            "-GPSAltitude=0", # Set default altitude
            "-GPSAltitudeRef=0", # 0 = Above Sea Level (Common default)
            "-Rotation=0" # Set default rotation
        )

        $exifArgs += "-overwrite_original" # Overwrite the original MP4
        $exifArgs += $tagArgs
        $exifArgs += "`"$FilePath`""       # Target file is the MP4 itself

    } else {
        # --- Image Files: Write standard EXIF and XMP GPS tags + location details ---
        $outputTargetDescription = "metadata into image file '$($fileInfo.Name)'" # Default description

        # Convert Lat/Lon for standard EXIF GPS tags
        $latRef = if ($Latitude -ge 0) { "N" } else { "S" }
        $lonRef = if ($Longitude -ge 0) { "E" } else { "W" }
        $latAbs = [Math]::Abs($Latitude).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $lonAbs = [Math]::Abs($Longitude).ToString([System.Globalization.CultureInfo]::InvariantCulture)

        # Include standard EXIF GPS, XMP GPS, and location tags for images
        $tagArgs = @(
            "-GPSLatitude=$latAbs",
            "-GPSLatitudeRef=$latRef",
            "-GPSLongitude=$lonAbs",
            "-GPSLongitudeRef=$lonRef",
            "-XMP:GPSLatitude=$latAbs",    # Add XMP Latitude
            "-XMP:GPSLongitude=$lonAbs"   # Add XMP Longitude
        )
        if (-not [string]::IsNullOrWhiteSpace($Country)) {
            $tagArgs += "-Country=`"$Country`"" # Quote value
        }
        if (-not [string]::IsNullOrWhiteSpace($City)) {
            $tagArgs += "-City=`"$City`"" # Quote value
        }
        if (-not [string]::IsNullOrWhiteSpace($CountryCode)) {
            # Use standard XMP tag for Country Code
            $tagArgs += "-XMP-iptcCore:CountryCode=`"$CountryCode`""
        }

        # Check if XMP sidecar exists for the image
        $xmpFilePath = [System.IO.Path]::ChangeExtension($FilePath, ".xmp")
        if (Test-Path -LiteralPath $xmpFilePath -PathType Leaf) {
            # Sidecar exists for image, update it
            $outputTargetDescription = "existing XMP sidecar '$([System.IO.Path]::GetFileName($xmpFilePath))'"
            $exifArgs += $tagArgs
            $exifArgs += "-o"               # Specify output file argument
            $exifArgs += "`"$xmpFilePath`"" # Add quoted XMP file path
            # Add source file when updating existing sidecar via -o
            $exifArgs += "`"$FilePath`""
        } else {
            # Sidecar does not exist for image, write directly to image file
            # Output description already set above
            $exifArgs += "-overwrite_original"
            $exifArgs += $tagArgs
            $exifArgs += "`"$FilePath`""
        }
    }

    # --- Execute Exiftool ---
    try {
        Write-Verbose "Executing exiftool write to $outputTargetDescription"
        $commandToLog = "$ExiftoolExePath $($exifArgs -join ' ')"
        Write-Verbose "Command: $commandToLog"

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $ExiftoolExePath
        $processInfo.Arguments = $exifArgs -join ' '
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $process.Start() | Out-Null

        # Read output before waiting to prevent deadlocks
        $stdOutput = $process.StandardOutput.ReadToEnd()
        $stdError = $process.StandardError.ReadToEnd()

        # Wait for exit (indefinitely, timeout removed)
        $process.WaitForExit()

        # Check exit code after waiting
        if ($process.ExitCode -ne 0) {
            # Treat Exit Code 1 as error unless it's "Nothing to write".
            if ($process.ExitCode -eq 1 -and ($stdError -match 'Nothing to write|0 image files updated|0 output files created|0 video files updated')) {
                Write-Host "    -> No changes needed for ${outputTargetDescription} (Tags likely identical)." -ForegroundColor Yellow
                if ($stdError -notmatch 'Nothing to write|0 image files updated|0 output files created|0 video files updated') { Write-Warning "Exiftool write warnings: $stdError"}
                return $true # Treat as success/non-fatal
            } else {
                Write-Error "Exiftool write operation exited with code $($process.ExitCode) for ${outputTargetDescription}. Stderr: $stdError Stdout: $stdOutput"
                return $false # Real error
            }
        } else {
            $successMsg = "Metadata successfully written to" # Generic message applicable to file or sidecar
            Write-Host "    -> $successMsg ${outputTargetDescription}." -ForegroundColor Green
            # Check for standard success messages before logging verbose output/warnings
            $successPattern = '1 image files updated|1 output files created|1 video files updated'
            if (-not [string]::IsNullOrWhiteSpace($stdOutput) -and $stdOutput -notmatch $successPattern) { Write-Verbose "Exiftool write output: $stdOutput"}
            if (-not [string]::IsNullOrWhiteSpace($stdError) -and $stdError -notmatch $successPattern) { Write-Warning "Exiftool write warnings: $stdError"}
            return $true
        }
    } catch {
        Write-Error "Error executing exiftool write for ${outputTargetDescription}: $($_.Exception.Message)"
        return $false
    }
}
#endregion Helper Functions


#region Main Script Logic
# ================== MAIN SCRIPT LOGIC ==================

# --- 0. Load Config and Show GUI ---
$loadedConfig = Load-Configuration -FilePath $configFilePath -Defaults $defaultConfig
$userConfig = Show-ConfigurationGui -InitialConfig $loadedConfig

if ($userConfig -eq $null) {
    Write-Host "Configuration cancelled by user. Exiting script."
    exit
}

# Extract values from GUI result
$dawarichApiUrl = $userConfig.dawarichApiUrl # Renamed
$dawarichApiKey = $userConfig.dawarichApiKey # Renamed
$photonApiUrl = $userConfig.photonApiUrl     # Renamed
$defaultTimeWindowSeconds = $userConfig.defaultTimeWindowSeconds
$exiftoolPath = $userConfig.exiftoolPath
$overwriteExistingData = $userConfig.overwriteExisting
$alwaysQueryPhoton = $userConfig.alwaysQueryPhoton # Added
$saveConfig = $userConfig.saveConfig
# $exiftoolTimeoutMs = $userConfig.exiftoolTimeoutMs # Removed

# --- 0a. Save Config if requested ---
if ($saveConfig) {
    # Create a hashtable with only the settings to save (exclude 'saveConfig' itself)
    $configToSave = $userConfig.Clone()
    $configToSave.Remove("saveConfig")
    # Remove timeout before saving if it exists from older config
    if ($configToSave.ContainsKey('exiftoolTimeoutMs')) { $configToSave.Remove('exiftoolTimeoutMs') }
    Save-Configuration -FilePath $configFilePath -ConfigData $configToSave
}

# --- 0b. Pre-checks (Exiftool Path) ---
$exiftoolFound = $false
if (Test-Path $exiftoolPath -PathType Leaf) {
    $exiftoolFound = $true
} else {
    $checkPath = Get-Command $exiftoolPath -ErrorAction SilentlyContinue
    if ($checkPath) {
        $exiftoolPath = $checkPath.Source
        $exiftoolFound = $true
        Write-Warning "Exiftool not found at configured path, but found in system PATH: $exiftoolPath"
    }
}

if (-not $exiftoolFound) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Exiftool could not be found at '$exiftoolPath' or in the system PATH. Please check the path in the configuration GUI or ensure exiftool is installed correctly.", "Exiftool Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    Write-Error "Exiftool could not be found. Exiting script."
    exit
}
Write-Host "Using exiftool: $exiftoolPath"
# Write-Host "Using Exiftool timeout: $($exiftoolTimeoutMs / 1000) seconds" # Removed
if ($overwriteExistingData) { Write-Host "Overwrite existing data flag is ON." -ForegroundColor Yellow }
if ($alwaysQueryPhoton) { Write-Host "Always Query Photon flag is ON (affects image location details)." -ForegroundColor Yellow }


# --- 1. Select Folder ---
$targetFolder = Select-FolderDialog -Description "Select the folder containing image/video files"
if (-not $targetFolder) { exit }
Write-Host "Processing folder: $targetFolder"

# --- 2. File Extensions ---
$imageExtensions = @(".jpg", ".jpeg", ".png", ".tiff", ".heic", ".gif", ".cr2", ".dng")
$videoExtensions = @(".mp4") # Only MP4 explicitly supported for direct GPS writing
$allExtensions = $imageExtensions + $videoExtensions

# Define large file threshold in MB for warning message
$largeFileThresholdMB = 200
$largeFileThresholdBytes = $largeFileThresholdMB * 1024 * 1024

# --- 3. Find Files ---
Write-Host "Searching for files with extensions: $($allExtensions -join ', ')"
try{
    $filesToProcess = Get-ChildItem -Path $targetFolder -File -ErrorAction Stop | Where-Object { $allExtensions -contains $_.Extension.ToLower() }
} catch {
     Write-Error "Error accessing folder '$targetFolder' or finding files: $($_.Exception.Message)"
     exit
}

if ($filesToProcess.Count -eq 0) { Write-Warning "No matching files found in folder '$targetFolder'."; exit }

Write-Host "$($filesToProcess.Count) files found. Starting processing..."
$processedCount = 0; $updatedCount = 0; $errorCount = 0
$skippedFiles = @() # List for files skipped because they already have data
$noApiDataFiles = @() # List for files skipped due to no API match or invalid coords

# --- 4. & 5. Process Files ---
foreach ($file in $filesToProcess) {
    $processedCount++
    Write-Host "[$processedCount/$($filesToProcess.Count)] Processing file: $($file.Name)" -ForegroundColor Cyan
    $fileHadError = $false
    $isMp4File = $file.Extension.ToLower() -eq ".mp4" # Check if current file is MP4
    $bestMatch = $null # Initialize bestMatch for this file iteration

    if ($file.Length -gt $largeFileThresholdBytes) {
        Write-Host "    -> Large file detected ($($file.Length / 1MB -as [int]) MB). Exiftool processing may take some time..." -ForegroundColor Yellow
    }

    # ** Read EXIF/XMP/UserData data using Invoke-Expression **
    # Read all potentially relevant tags for checking existing data
    $exifReadArgs = @(
        "-j", # JSON output
        # Standard GPS (primarily for images)
        "-GPSLatitude", "-GPSLongitude",
        # Google Photos Video GPS Tag
        "-UserData:GPSCoordinates",
        # Location Details (Images)
        "-Country", "-City", "-XMP-iptcCore:CountryCode",
        # Date Tags
        "-DateTimeOriginal", "-CreateDate", "-MediaCreateDate", "-TrackCreateDate",
        # File Path
        "-FilePath"
    )
    $exifJson = $null; $exifData = $null
    try {
        $quotedExiftoolPath = if ($exiftoolPath -match '\s') { "`"$exiftoolPath`"" } else { $exiftoolPath }
        $quotedFilePath = "`"$($file.FullName)`""
        $commandString = "$quotedExiftoolPath $($exifReadArgs -join ' ') $quotedFilePath"
        Write-Verbose "Executing exiftool read: $commandString"
        $exifOutput = Invoke-Expression $commandString -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($exifOutput)) { Write-Warning "    Exiftool read operation produced no output for '$($file.Name)'." }

        $exifJson = $exifOutput | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($exifJson -eq $null -and -not ([string]::IsNullOrWhiteSpace($exifOutput))) {
             Write-Warning "    Failed to parse JSON output from exiftool read for '$($file.Name)'. Raw output: $exifOutput"
             $fileHadError = $true; $errorCount++; continue # Error, count and skip to next file
        } elseif ($exifJson -eq $null) {
             # If output was empty, this is expected, otherwise log it
             if (-not ([string]::IsNullOrWhiteSpace($exifOutput))) {
                 Write-Host "    No parsable EXIF/XMP/UserData structure retrieved for '$($file.Name)'. Skipping."
             } else {
                 Write-Host "    No EXIF/XMP/UserData data found for '$($file.Name)'. Skipping."
             }
             continue # No data, skip to next file
        }

        if ($exifJson -is [array]) {
             if ($exifJson.Count -gt 0) { $exifData = $exifJson[0] }
             else { Write-Host "    Exiftool returned empty data array for '$($file.Name)'."; $exifData = $null }
        } else { $exifData = $exifJson }

    } catch {
        Write-Warning "    Error executing or processing exiftool read for '$($file.Name)': $($_.Exception.Message)"
        if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) { Write-Warning "    Exiftool may have exited with code $LASTEXITCODE." }
        $fileHadError = $true; $errorCount++; continue # Error, count and skip to next file
    }

    if ($exifData -eq $null) { continue } # Skip if no data structure

    # Check existing tags relevant to the file type
    $gpsLat = $null; $gpsLon = $null; $country = $null; $city = $null; $countryCode = $null; $userDataGps = $null
    $hasRequiredData = $false

    if ($isMp4File) {
        # For MP4, check UserData:GPSCoordinates
        if ($exifData.PSObject.Properties.Name -contains 'UserData:GPSCoordinates') {
            $userDataGps = $exifData.'UserData:GPSCoordinates'
            if (-not [string]::IsNullOrWhiteSpace($userDataGps)) {
                $hasRequiredData = $true
            }
        }
    } else {
        # For Images, check standard GPS and location tags
        $hasGps = $false
        $hasLocation = $false
        if ($exifData.PSObject.Properties.Name -contains 'GPSLatitude') { $gpsLat = $exifData.GPSLatitude }
        if ($exifData.PSObject.Properties.Name -contains 'GPSLongitude') { $gpsLon = $exifData.GPSLongitude }
        if (($gpsLat -ne $null) -and ($gpsLon -ne $null) -and ($gpsLat -ne 0 -or $gpsLon -ne 0)) {
             $hasGps = $true
        }

        if ($exifData.PSObject.Properties.Name -contains 'Country') { $country = $exifData.Country }
        if ($exifData.PSObject.Properties.Name -contains 'City') { $city = $exifData.City }
        if ($exifData.PSObject.Properties.Name -contains 'XMP-iptcCore:CountryCode') { $countryCode = $exifData.'XMP-iptcCore:CountryCode' }
        if (-not ([string]::IsNullOrWhiteSpace($country) -and [string]::IsNullOrWhiteSpace($city) -and [string]::IsNullOrWhiteSpace($countryCode))) {
            $hasLocation = $true
        }
        # Image has required data if it has both GPS and some location info
        if ($hasGps -and $hasLocation) {
            $hasRequiredData = $true
        }
    }

    # Determine if processing is needed
    $shouldProcessFile = $false
    if ($overwriteExistingData) {
        $shouldProcessFile = $true
        Write-Host "    -> Overwrite flag set. Processing file..."
    } elseif (-not $hasRequiredData) {
        $shouldProcessFile = $true
        if ($isMp4File) { Write-Host "    -> MP4 UserData:GPSCoordinates missing." }
        else { Write-Host "    -> Image GPS or Location data missing." }
    }

    if (-not $shouldProcessFile) {
         Write-Host "    -> File does not need processing (has required data and overwrite flag is off)."
         $skippedFiles += $file.FullName # Add to skipped list
         continue # Skip to next file
    }

    # --- Proceed with processing only if $shouldProcessFile is true ---

    # Determine creation date (needed for API query)
    $creationDateString = $null
    if ($exifData.PSObject.Properties.Name -contains 'DateTimeOriginal') { $creationDateString = $exifData.DateTimeOriginal }
    if ([string]::IsNullOrWhiteSpace($creationDateString) -and ($exifData.PSObject.Properties.Name -contains 'CreateDate')) { $creationDateString = $exifData.CreateDate }
    if ([string]::IsNullOrWhiteSpace($creationDateString) -and ($exifData.PSObject.Properties.Name -contains 'MediaCreateDate')) { $creationDateString = $exifData.MediaCreateDate }
    if ([string]::IsNullOrWhiteSpace($creationDateString) -and ($exifData.PSObject.Properties.Name -contains 'TrackCreateDate')) { $creationDateString = $exifData.TrackCreateDate }

    if ([string]::IsNullOrWhiteSpace($creationDateString)) { Write-Warning "    Could not determine suitable creation date from EXIF for '$($file.Name)'."; $fileHadError = $true; $errorCount++; continue } # Error, count and skip

    # Convert date for API
    $fileTimestampUTC = ConvertTo-ApiTimestamp -ExifDateTimeString $creationDateString
    if ($fileTimestampUTC -eq $null) { Write-Warning "    Could not convert creation date '$creationDateString' for API."; $fileHadError = $true; $errorCount++; continue } # Error, count and skip

    $fileDateTime = $null
    try { $fileDateTime = [datetime]::ParseExact($fileTimestampUTC,"yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal) }
    catch { Write-Warning "    Failed to parse back converted UTC timestamp '$fileTimestampUTC'."; $fileHadError = $true; $errorCount++; continue } # Error, count and skip

    Write-Host "    Determined creation date (UTC): $fileTimestampUTC"

    # --- Dawarich API Query (Time Window Only) ---
    # Directly query using the time window
    $startDate = $fileDateTime.AddSeconds(-$defaultTimeWindowSeconds).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $endDate = $fileDateTime.AddSeconds($defaultTimeWindowSeconds).ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Host "    Attempting Dawarich API query within time window: $startDate to $endDate..."
    $apiResultRange = Get-DawarichDataFromApi -BaseUrl $dawarichApiUrl -ApiKey $dawarichApiKey -StartAt $startDate -EndAt $endDate # Use renamed function/vars

    # $bestMatch is already initialized to $null
    if ($apiResultRange -ne $null) {
         $resultsRangeArray = @($apiResultRange)
         if ($resultsRangeArray.Count -gt 0) {
             $validResultsRange = $resultsRangeArray | Where-Object { $_.PSObject.Properties.Name -contains 'latitude' -and $_.PSObject.Properties.Name -contains 'longitude' -and $_.latitude -ne $null -and $_.longitude -ne $null -and $_.latitude -ne 0 -and $_.longitude -ne 0 }
             if ($validResultsRange.Count -gt 0) {
                 Write-Host "    -> $($validResultsRange.Count) valid results found in time window. Finding closest..."
                 $closestDiff = [double]::MaxValue
                 foreach ($result in $validResultsRange) {
                     try {
                         $resultTimestamp = $null; # ... timestamp parsing ...
                         if ($result.PSObject.Properties.Name -contains 'timestamp' -and $result.timestamp -ne $null) {
                             if ($result.timestamp -is [long] -or $result.timestamp -is [int]) { $resultTimestamp = [datetimeoffset]::FromUnixTimeSeconds($result.timestamp).UtcDateTime }
                             elseif ($result.timestamp -is [string]) {
                                 try { $resultTimestamp = [datetime]::ParseExact($result.timestamp,"yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal) } catch {
                                     if ($result.timestamp -match "\.\d+Z$") { try { $resultTimestamp = [datetime]::ParseExact($result.timestamp,"yyyy-MM-ddTHH:mm:ss.fffffffZ", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal) } catch {}}
                                     else { Write-Warning "Could not parse timestamp string: $($result.timestamp)" } } }
                             else { Write-Warning "Unknown data type for timestamp: $($result.timestamp.GetType().FullName)" }
                         } else { Write-Warning "Timestamp field missing or null." }
                         if ($resultTimestamp -ne $null) {
                             $timeDiff = New-TimeSpan -Start $fileDateTime -End $resultTimestamp; $absDiffSeconds = [Math]::Abs($timeDiff.TotalSeconds)
                             if ($absDiffSeconds -lt $closestDiff) { $closestDiff = $absDiffSeconds; $bestMatch = $result } }
                     } catch { Write-Warning "Error processing timestamp: '$($result.timestamp)' - $($_.Exception.Message)" }
                 }
                 if ($bestMatch -ne $null) { Write-Host "    -> Closest match found (Difference: $($closestDiff.ToString('F2'))s)." }
                 else { Write-Host "    -> Could not find a valid, time-comparable result." }
             } else { Write-Host "    -> API query returned results, but none with valid coordinates." }
         } else { Write-Host "    -> No results returned from API query within time window." }
    } else { Write-Host "    -> Dawarich API query failed or returned null for time window." }


    # --- Process Best Match (if found) ---
    if ($bestMatch -ne $null) {
        $latitude = $null; $longitude = $null
        if ($bestMatch.PSObject.Properties.Name -contains 'latitude') { $latitude = try { [double]$bestMatch.latitude } catch { Write-Warning "Cast latitude failed."; $null } }
        if ($bestMatch.PSObject.Properties.Name -contains 'longitude') { $longitude = try { [double]$bestMatch.longitude } catch { Write-Warning "Cast longitude failed."; $null } }

        if ($latitude -eq $null -or $longitude -eq $null) {
             Write-Warning "    -> Invalid lat/lon from Dawarich API. Skipping write.";
             $noApiDataFiles += $file.FullName # Add to list: invalid coords
             $fileHadError = $true; $errorCount++; continue # Count as error, skip to next file
        }

        # Initialize variables for writing (relevant mainly for images)
        $countryToWrite = $null
        $cityToWrite = $null
        $countryCodeToWrite = $null

        # Only attempt to get/process Country/City/Code if it's an image file
        if (-not $isMp4File) {
            # Get initial values from Dawarich API result (check if properties exist)
            $countryFromDawarich = if ($bestMatch.PSObject.Properties.Name -contains 'country') { $bestMatch.country } else { $null }
            $cityFromDawarich = if ($bestMatch.PSObject.Properties.Name -contains 'city') { $bestMatch.city } else { $null }
            $countryCodeFromDawarich = if ($bestMatch.PSObject.Properties.Name -contains 'country_code') { $bestMatch.country_code } else { $null } # Assuming field name 'country_code'

            $countryToWrite = $countryFromDawarich
            $cityToWrite = $cityFromDawarich
            $countryCodeToWrite = $countryCodeFromDawarich

            # --- Photon Reverse Geocoding (only if needed/forced for IMAGE files) ---
            $needsPhotonQuery = $false
            if ($alwaysQueryPhoton) {
                $needsPhotonQuery = $true
                Write-Host "    -> 'Always Query Photon' is enabled. Querying Photon API for image details..."
            } elseif ([string]::IsNullOrWhiteSpace($countryFromDawarich) -or [string]::IsNullOrWhiteSpace($cityFromDawarich) -or [string]::IsNullOrWhiteSpace($countryCodeFromDawarich)) {
                 $needsPhotonQuery = $true
                 Write-Host "    -> Country, City, or Country Code missing/empty in Dawarich API result for image. Querying Photon API..."
            }

            if ($needsPhotonQuery) {
                $locationData = Get-LocationFromPhoton -BaseUrl $photonApiUrl -Latitude $latitude -Longitude $longitude # Use renamed function/vars
                if ($locationData -ne $null) {
                    Write-Host "        -> Photon found: Country='$($locationData.Country)', City='$($locationData.City)', Code='$($locationData.CountryCode)'"
                    # If always querying, Photon data takes precedence. Otherwise, only fill missing fields.
                    if ($alwaysQueryPhoton) {
                        # Overwrite with Photon data only if Photon provided a value
                        if (-not ([string]::IsNullOrWhiteSpace($locationData.Country))) { $countryToWrite = $locationData.Country }
                        if (-not ([string]::IsNullOrWhiteSpace($locationData.City))) { $cityToWrite = $locationData.City }
                        if (-not ([string]::IsNullOrWhiteSpace($locationData.CountryCode))) { $countryCodeToWrite = $locationData.CountryCode }
                        Write-Host "        -> Photon results will overwrite Dawarich results where available for image."
                    } else {
                        # Only fill missing data from Dawarich results
                        if (-not ([string]::IsNullOrWhiteSpace($locationData.Country)) -and [string]::IsNullOrWhiteSpace($countryToWrite)) { $countryToWrite = $locationData.Country }
                        if (-not ([string]::IsNullOrWhiteSpace($locationData.City)) -and [string]::IsNullOrWhiteSpace($cityToWrite)) { $cityToWrite = $locationData.City }
                        if (-not ([string]::IsNullOrWhiteSpace($locationData.CountryCode)) -and [string]::IsNullOrWhiteSpace($countryCodeToWrite)) { $countryCodeToWrite = $locationData.CountryCode }
                    }
                } else {
                    Write-Warning "    -> Error during Photon reverse geocoding for image. Using Dawarich data if available."
                    # Keep original Dawarich values as Photon failed
                }
            }
        } # End if (-not $isMp4File) for location details processing

        # --- Write Data ---
        # Check coordinates again (redundant check based on above logic, but safe)
        if (($latitude -ne 0 -or $longitude -ne 0)) {
            if ($isMp4File) {
                Write-Host "    Writing GPS data to MP4 '$($file.Name)' (Google Photos format)..."
            } else {
                Write-Host "    Writing data to Image '$($file.Name)': Lat=$latitude, Lon=$longitude, Country='$countryToWrite', City='$cityToWrite', Code='$countryCodeToWrite'"
            }

            # Call Set-ExifData - it now handles the logic for what to write based on file type
            $writeSuccess = Set-ExifData -ExiftoolExePath $exiftoolPath -FilePath $file.FullName `
                -Latitude $latitude -Longitude $longitude `
                -Country $countryToWrite -City $cityToWrite -CountryCode $countryCodeToWrite # Pass all values; function decides what to use

            if (-not $writeSuccess) { $fileHadError = $true; $errorCount++; } # Count write errors
            else { $updatedCount++; }
        } else {
            # This case should technically not be reached due to the earlier check, but added for robustness
            Write-Warning "    -> Best match has invalid coordinates (Lat=0, Lon=0). Skipping write operation."
            $noApiDataFiles += $file.FullName # Add to list: invalid coords
        }
    }
    else {
        # No bestMatch found from API
        Write-Host "    -> No suitable GPS data found via Dawarich API for '$($file.Name)'."
        $noApiDataFiles += $file.FullName # Add to list: no API data found
    }

    # Separator only if no error occurred in this iteration
    if (-not $fileHadError) { Write-Host "---" }

} # end foreach file

# --- Final Summary ---
Write-Host "`nProcessing finished." -ForegroundColor Green
Write-Host "--- SUMMARY ---"
Write-Host " * Files scanned: $processedCount"
Write-Host " * Files updated successfully: $updatedCount"
if ($errorCount -gt 0) {
    Write-Host " * Files with errors during processing: $errorCount" -ForegroundColor Yellow
}

# --- List Skipped Files ---
if ($skippedFiles.Count -gt 0) {
    Write-Host "`n--- Files Skipped (Already Have Data) ---" -ForegroundColor Cyan
    $skippedFiles | ForEach-Object { Write-Host " - $_" }
}

if ($noApiDataFiles.Count -gt 0) {
    Write-Host "`n--- Files Skipped (No Suitable API Data Found or Invalid Coordinates) ---" -ForegroundColor Cyan
    $noApiDataFiles | ForEach-Object { Write-Host " - $_" }
}

Write-Host "`nScript ended."

#endregion Main Script Logic