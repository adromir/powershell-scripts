<#
.SYNOPSIS
Searches a selected folder for image and MP4 files, optionally updating EXIF/XMP data (GPS, country, city, country code).
Queries a primary API (Dawarich) for location data based on the file's creation date.
Optionally uses reverse geocoding via a secondary API (Photon) if primary data is missing or user chooses to always query.
Writes the found data using exiftool. For images, writes to existing XMP sidecar if present, otherwise writes to image file directly. For MP4s, always writes to XMP sidecar (overwriting existing).
Includes a GUI for configuration and options.

.DESCRIPTION
This script performs the following steps:
1.  Checks for a configuration file (config.json) and loads settings if found. Handles backward compatibility for renamed API keys.
2.  Displays a GUI window for configuration:
    - Dawarich API URL
    - Dawarich API Key
    - Photon API URL (for reverse geocoding)
    - Default Time Window (seconds)
    - Option to Save Configuration
    - Option to Overwrite Existing EXIF Data
    - Option to Always Query Photon API for Location Details
3.  If the user clicks OK in the GUI:
    - Saves the configuration if requested (using new key names).
    - Prompts the user to select a folder to scan using a GUI.
    - Searches the selected folder for supported image/video files.
    - Reads EXIF data for each file using exiftool.
    - Determines if a file needs processing based on missing data OR the "Overwrite" flag.
    - If processing is needed:
        a. Determines the creation date.
        b. Queries the configured Dawarich API (exact match first, then time window).
        c. Selects the closest valid match.
        d. If coordinates found:
            i.  Optionally queries Photon API for missing country/city/country code, or if 'Always Query Photon' is checked. Photon results take precedence if this option is checked.
            ii. Writes GPS, Country, City, and Country Code (using XMP tag) using exiftool.
                - For MP4 files: Data is written to a separate .xmp sidecar file (deleting any existing sidecar first).
                - For Image files: Data is written to an existing .xmp sidecar if found, otherwise directly into the image file.
4.  Outputs status messages during processing, including warnings for large files.

.NOTES
Ensure that exiftool.exe is either in the system PATH or the full path is specified correctly (now defaults or via config file/GUI).
The API keys and URLs are now primarily managed via the GUI and optional config file.
Processing large video files can be slow due to I/O limitations. Writing to XMP sidecars for MP4s is much faster.
Writing EXIF data overwrites the original image files (using exiftool -overwrite_original) ONLY if an XMP sidecar does not already exist for that image. If a sidecar exists, it will be updated instead. MP4 files are NOT modified; .xmp files are created/updated instead (by deleting and recreating). It is strongly recommended to back up your files beforehand!
The configuration file (config.json) stores settings, including the API key, in plain text in the script's directory. Handle this file with care.
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
    $checkboxOverwrite.Text = "Overwrite existing GPS/Country/City/Code data in files" # Updated text
    $checkboxOverwrite.Checked = $InitialConfig.overwriteExisting
    $form.Controls.Add($checkboxOverwrite)
    $yPos += $controlHeight + $spacing

    # Always Query Photon Checkbox
    $checkboxAlwaysQueryPhoton = New-Object System.Windows.Forms.CheckBox
    $checkboxAlwaysQueryPhoton.Location = New-Object System.Drawing.Point(15, $yPos)
    $checkboxAlwaysQueryPhoton.Size = New-Object System.Drawing.Size(400, $controlHeight)
    $checkboxAlwaysQueryPhoton.Text = "Always query Photon API (overwrites Dawarich location)" # New checkbox
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
# Now includes CountryCode and uses XMP tag for it
# ** MODIFIED ** to delete existing XMP before writing new one for MP4
function Set-ExifData {
    param(
        [string]$ExiftoolExePath,
        [string]$FilePath,
        [double]$Latitude,
        [double]$Longitude,
        [string]$Country,
        [string]$City,
        [string]$CountryCode # Added
        # Removed TimeoutMilliseconds parameter
    )

    $fileInfo = Get-Item -LiteralPath $FilePath
    $isMp4 = $fileInfo.Extension.ToLower() -eq ".mp4"

    # Convert Lat/Lon
    $latStr = $Latitude.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $lonStr = $Longitude.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $latRef = if ($Latitude -ge 0) { "N" } else { "S" }
    $lonRef = if ($Longitude -ge 0) { "E" } else { "W" }
    $latAbs = [Math]::Abs($Latitude).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $lonAbs = [Math]::Abs($Longitude).ToString([System.Globalization.CultureInfo]::InvariantCulture)

    # Base arguments for tags
    $tagArgs = @(
        "-GPSLatitude=$latAbs",
        "-GPSLatitudeRef=$latRef",
        "-GPSLongitude=$lonAbs",
        "-GPSLongitudeRef=$lonRef"
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

    # --- Determine output target and specific arguments ---
    $exifArgs = @()
    $outputTargetDescription = ""
    $xmpFilePath = "" # Initialize outside the if block

    if ($isMp4) {
        # Write to XMP Sidecar file for MP4
        $xmpFilePath = [System.IO.Path]::ChangeExtension($FilePath, ".xmp")
        $outputTargetDescription = "XMP sidecar '$([System.IO.Path]::GetFileName($xmpFilePath))'"

        # **FIX**: Delete existing XMP file first to ensure overwrite/update via -o
        if (Test-Path -LiteralPath $xmpFilePath -PathType Leaf) {
            Write-Verbose "Removing existing XMP sidecar: $xmpFilePath"
            Remove-Item -LiteralPath $xmpFilePath -Force -ErrorAction SilentlyContinue
        }

        $exifArgs += $tagArgs
        $exifArgs += "-o"                # Specify output file argument
        $exifArgs += "`"$xmpFilePath`""  # Add quoted XMP file path
        # No source file needed as final arg when using -o to create sidecar from tags
        # Exiftool creates the XMP file based on the tags provided.

    } else {
        # For non-MP4 files (images), check if sidecar exists
        $xmpFilePath = [System.IO.Path]::ChangeExtension($FilePath, ".xmp")
        if (Test-Path -LiteralPath $xmpFilePath -PathType Leaf) {
            # Sidecar exists for image, update it
            $outputTargetDescription = "existing XMP sidecar '$([System.IO.Path]::GetFileName($xmpFilePath))'"
            $exifArgs += $tagArgs
            $exifArgs += "-o"
            $exifArgs += "`"$xmpFilePath`""
            # Add source file when updating existing sidecar via -o
            $exifArgs += "`"$FilePath`""
        } else {
            # Sidecar does not exist for image, write directly to image file
            $outputTargetDescription = "file '$($fileInfo.Name)'"
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
             # The "already exists" error should be prevented by deleting first for MP4s.
             # For images, updating existing XMP via -o might give "Nothing to write".
             if ($process.ExitCode -eq 1 -and ($stdError -match 'Nothing to write|0 image files updated|0 output files created')) {
                  Write-Host "   -> No changes needed for ${outputTargetDescription} (Tags likely identical)." -ForegroundColor Yellow
                  if ($stdError -notmatch 'Nothing to write|0 image files updated|0 output files created') { Write-Warning "Exiftool write warnings: $stdError"}
                  return $true # Treat as success/non-fatal
             } else {
                 Write-Error "Exiftool write operation exited with code $($process.ExitCode) for ${outputTargetDescription}. Stderr: $stdError Stdout: $stdOutput"
                 return $false # Real error
             }
        } else {
             $successMsg = if ($isMp4 -or (Test-Path -LiteralPath $xmpFilePath -PathType Leaf)) { "Metadata successfully written to" } else { "EXIF data successfully written to" } # Adjust success message based on target
             Write-Host "   -> $successMsg ${outputTargetDescription}." -ForegroundColor Green
             if (-not [string]::IsNullOrWhiteSpace($stdOutput) -and $stdOutput -notmatch '1 image files updated|1 output files created') { Write-Verbose "Exiftool write output: $stdOutput"}
             if (-not [string]::IsNullOrWhiteSpace($stdError) -and $stdError -notmatch '1 image files updated|1 output files created') { Write-Warning "Exiftool write warnings: $stdError"}
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
if ($alwaysQueryPhoton) { Write-Host "Always Query Photon flag is ON." -ForegroundColor Yellow }


# --- 1. Select Folder ---
$targetFolder = Select-FolderDialog -Description "Select the folder containing image/video files"
if (-not $targetFolder) { exit }
Write-Host "Processing folder: $targetFolder"

# --- 2. File Extensions ---
$imageExtensions = @(".jpg", ".jpeg", ".png", ".tiff", ".heic", ".gif", ".cr2", ".dng")
$videoExtensions = @(".mp4")
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

# --- 4. & 5. Process Files ---
foreach ($file in $filesToProcess) {
    $processedCount++
    Write-Host "[$processedCount/$($filesToProcess.Count)] Processing file: $($file.Name)" -ForegroundColor Cyan
    $fileHadError = $false

    if ($file.Length -gt $largeFileThresholdBytes) {
        Write-Host "   -> Large file detected ($($file.Length / 1MB -as [int]) MB). Exiftool processing may take some time..." -ForegroundColor Yellow
    }

    # ** Read EXIF data using Invoke-Expression **
    # ** FIX**: Use XMP tag name for country code reading
    $exifReadArgs = @(
        "-j", "-GPSLatitude", "-GPSLongitude", "-Country", "-City", "-XMP-iptcCore:CountryCode",
        "-DateTimeOriginal", "-CreateDate", "-MediaCreateDate", "-TrackCreateDate", "-FilePath"
    )
    $exifJson = $null; $exifData = $null
    try {
        $quotedExiftoolPath = if ($exiftoolPath -match '\s') { "`"$exiftoolPath`"" } else { $exiftoolPath }
        $quotedFilePath = "`"$($file.FullName)`""
        $commandString = "$quotedExiftoolPath $($exifReadArgs -join ' ') $quotedFilePath"
        Write-Verbose "Executing exiftool read: $commandString"
        $exifOutput = Invoke-Expression $commandString -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($exifOutput)) { Write-Warning "   Exiftool read operation produced no output for '$($file.Name)'." }

        $exifJson = $exifOutput | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($exifJson -eq $null -and -not ([string]::IsNullOrWhiteSpace($exifOutput))) {
             Write-Warning "   Failed to parse JSON output from exiftool read for '$($file.Name)'. Raw output: $exifOutput"
             $fileHadError = $true; $errorCount++; continue
        } elseif ($exifJson -eq $null) {
             Write-Host "   No parsable EXIF data structure retrieved for '$($file.Name)'. Skipping."
             continue
        }

        if ($exifJson -is [array]) {
             if ($exifJson.Count -gt 0) { $exifData = $exifJson[0] }
             else { Write-Host "   Exiftool returned empty data array for '$($file.Name)' (No EXIF)."; $exifData = $null }
        } else { $exifData = $exifJson }

    } catch {
        Write-Warning "   Error executing or processing exiftool read for '$($file.Name)': $($_.Exception.Message)"
        if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) { Write-Warning "   Exiftool may have exited with code $LASTEXITCODE." }
        $fileHadError = $true; $errorCount++; continue
    }

    if ($exifData -eq $null) { continue } # Skip if no data structure

    # Check existing tags
    $gpsLat = $null; $gpsLon = $null; $country = $null; $city = $null; $countryCode = $null # Added countryCode
    if ($exifData.PSObject.Properties.Name -contains 'GPSLatitude') { $gpsLat = $exifData.GPSLatitude }
    if ($exifData.PSObject.Properties.Name -contains 'GPSLongitude') { $gpsLon = $exifData.GPSLongitude }
    if ($exifData.PSObject.Properties.Name -contains 'Country') { $country = $exifData.Country }
    if ($exifData.PSObject.Properties.Name -contains 'City') { $city = $exifData.City }
    # ** FIX**: Use XMP tag name for checking existing country code
    if ($exifData.PSObject.Properties.Name -contains 'XMP-iptcCore:CountryCode') { $countryCode = $exifData.'XMP-iptcCore:CountryCode' }

    # Determine if processing is needed based on missing data OR overwrite flag
    $shouldProcessFile = $false
    if ($overwriteExistingData) {
        $shouldProcessFile = $true
        Write-Host "   -> Overwrite flag set. Processing file..."
    } else {
        if (($gpsLat -eq $null) -or ($gpsLon -eq $null) -or ($gpsLat -eq 0 -and $gpsLon -eq 0)) { Write-Host "   -> GPS coordinates missing or zero."; $shouldProcessFile = $true }
        if ([string]::IsNullOrWhiteSpace($country)) { Write-Host "   -> Country missing."; $shouldProcessFile = $true }
        if ([string]::IsNullOrWhiteSpace($city)) { Write-Host "   -> City missing."; $shouldProcessFile = $true }
        if ([string]::IsNullOrWhiteSpace($countryCode)) { Write-Host "   -> Country Code missing."; $shouldProcessFile = $true } # Added check
    }

    if (-not $shouldProcessFile) {
         Write-Host "   -> File does not need processing (has data and overwrite flag is off)."
         continue # Skip to next file
    }

    # --- Proceed with processing only if $shouldProcessFile is true ---

    # Determine creation date
    $creationDateString = $null
    if ($exifData.PSObject.Properties.Name -contains 'DateTimeOriginal') { $creationDateString = $exifData.DateTimeOriginal }
    if ([string]::IsNullOrWhiteSpace($creationDateString) -and ($exifData.PSObject.Properties.Name -contains 'CreateDate')) { $creationDateString = $exifData.CreateDate }
    if ([string]::IsNullOrWhiteSpace($creationDateString) -and ($exifData.PSObject.Properties.Name -contains 'MediaCreateDate')) { $creationDateString = $exifData.MediaCreateDate }
    if ([string]::IsNullOrWhiteSpace($creationDateString) -and ($exifData.PSObject.Properties.Name -contains 'TrackCreateDate')) { $creationDateString = $exifData.TrackCreateDate }

    if ([string]::IsNullOrWhiteSpace($creationDateString)) { Write-Warning "   Could not determine suitable creation date from EXIF for '$($file.Name)'."; $fileHadError = $true; $errorCount++; continue }

    # Convert date for API
    $fileTimestampUTC = ConvertTo-ApiTimestamp -ExifDateTimeString $creationDateString
    if ($fileTimestampUTC -eq $null) { Write-Warning "   Could not convert creation date '$creationDateString' for API."; $fileHadError = $true; $errorCount++; continue }

    $fileDateTime = $null
    try { $fileDateTime = [datetime]::ParseExact($fileTimestampUTC,"yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal) }
    catch { Write-Warning "   Failed to parse back converted UTC timestamp '$fileTimestampUTC'."; $fileHadError = $true; $errorCount++; continue }

    Write-Host "   Determined creation date (UTC): $fileTimestampUTC"

    # --- Dawarich API Query ---
    Write-Host "   Attempting exact Dawarich API query for $fileTimestampUTC..."
    $apiResultExact = Get-DawarichDataFromApi -BaseUrl $dawarichApiUrl -ApiKey $dawarichApiKey -StartAt $fileTimestampUTC -EndAt $fileTimestampUTC # Use renamed function/vars
    $bestMatch = $null

    if ($apiResultExact -ne $null) {
        $resultsArray = @($apiResultExact)
        if ($resultsArray.Count -gt 0) {
            $validResultsExact = $resultsArray | Where-Object { $_.PSObject.Properties.Name -contains 'latitude' -and $_.PSObject.Properties.Name -contains 'longitude' -and $_.latitude -ne $null -and $_.longitude -ne $null -and $_.latitude -ne 0 -and $_.longitude -ne 0 }
            if ($validResultsExact.Count -gt 0) { $bestMatch = $validResultsExact[0]; Write-Host "   -> Exact match found." }
            else { Write-Host "   -> Exact query returned results, but without valid coordinates." }
        } else { Write-Host "   -> No results returned from exact Dawarich API query." }
    } else { Write-Host "   -> Dawarich API query failed or returned null for exact match." }

    if ($bestMatch -eq $null) {
        $startDate = $fileDateTime.AddSeconds(-$defaultTimeWindowSeconds).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $endDate = $fileDateTime.AddSeconds($defaultTimeWindowSeconds).ToString("yyyy-MM-ddTHH:mm:ssZ")
        Write-Host "   Attempting Dawarich API query within time window: $startDate to $endDate..."
        $apiResultRange = Get-DawarichDataFromApi -BaseUrl $dawarichApiUrl -ApiKey $dawarichApiKey -StartAt $startDate -EndAt $endDate # Use renamed function/vars

        if ($apiResultRange -ne $null) {
             $resultsRangeArray = @($apiResultRange)
             if ($resultsRangeArray.Count -gt 0) {
                 $validResultsRange = $resultsRangeArray | Where-Object { $_.PSObject.Properties.Name -contains 'latitude' -and $_.PSObject.Properties.Name -contains 'longitude' -and $_.latitude -ne $null -and $_.longitude -ne $null -and $_.latitude -ne 0 -and $_.longitude -ne 0 }
                 if ($validResultsRange.Count -gt 0) {
                     Write-Host "   -> $($validResultsRange.Count) valid results found in time window. Finding closest..."
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
                     if ($bestMatch -ne $null) { Write-Host "   -> Closest match found (Difference: $($closestDiff.ToString('F2'))s)." }
                     else { Write-Host "   -> Could not find a valid, time-comparable result." }
                 } else { Write-Host "   -> API query returned results, but none with valid coordinates." }
             } else { Write-Host "   -> No results returned from API query within time window." }
        } else { Write-Host "   -> Dawarich API query failed or returned null for time window." }
    }

    # --- Process Best Match (if found) ---
    if ($bestMatch -ne $null) {
        $latitude = $null; $longitude = $null
        if ($bestMatch.PSObject.Properties.Name -contains 'latitude') { $latitude = try { [double]$bestMatch.latitude } catch { Write-Warning "Cast latitude failed."; $null } }
        if ($bestMatch.PSObject.Properties.Name -contains 'longitude') { $longitude = try { [double]$bestMatch.longitude } catch { Write-Warning "Cast longitude failed."; $null } }

        if ($latitude -eq $null -or $longitude -eq $null) { Write-Warning "   -> Invalid lat/lon from Dawarich API. Skipping write."; $fileHadError = $true; $errorCount++; continue }

        # Get initial values from Dawarich API result (check if properties exist)
        $countryFromDawarich = if ($bestMatch.PSObject.Properties.Name -contains 'country') { $bestMatch.country } else { $null }
        $cityFromDawarich = if ($bestMatch.PSObject.Properties.Name -contains 'city') { $bestMatch.city } else { $null }
        $countryCodeFromDawarich = if ($bestMatch.PSObject.Properties.Name -contains 'country_code') { $bestMatch.country_code } else { $null } # Assuming field name 'country_code'

        # Initialize variables for writing
        $countryToWrite = $countryFromDawarich
        $cityToWrite = $cityFromDawarich
        $countryCodeToWrite = $countryCodeFromDawarich

        # --- Photon Reverse Geocoding (if needed or forced) ---
        $needsPhotonQuery = $false
        if ($alwaysQueryPhoton) {
            $needsPhotonQuery = $true
            Write-Host "   -> 'Always Query Photon' is enabled. Querying Photon API..."
        } elseif ([string]::IsNullOrWhiteSpace($countryFromDawarich) -or [string]::IsNullOrWhiteSpace($cityFromDawarich) -or [string]::IsNullOrWhiteSpace($countryCodeFromDawarich)) {
             $needsPhotonQuery = $true
             Write-Host "   -> Country, City, or Country Code missing/empty in Dawarich API result. Querying Photon API..."
        }

        if ($needsPhotonQuery) {
            $locationData = Get-LocationFromPhoton -BaseUrl $photonApiUrl -Latitude $latitude -Longitude $longitude # Use renamed function/vars
            if ($locationData -ne $null) {
                Write-Host "      -> Photon found: Country='$($locationData.Country)', City='$($locationData.City)', Code='$($locationData.CountryCode)'"
                # If always querying, Photon data takes precedence. Otherwise, only fill missing fields.
                if ($alwaysQueryPhoton) {
                    # Overwrite with Photon data only if Photon provided a value
                    if (-not ([string]::IsNullOrWhiteSpace($locationData.Country))) { $countryToWrite = $locationData.Country }
                    if (-not ([string]::IsNullOrWhiteSpace($locationData.City))) { $cityToWrite = $locationData.City }
                    if (-not ([string]::IsNullOrWhiteSpace($locationData.CountryCode))) { $countryCodeToWrite = $locationData.CountryCode }
                    Write-Host "      -> Photon results will overwrite Dawarich results where available."
                } else {
                    # Only fill missing data from Dawarich results
                    if (-not ([string]::IsNullOrWhiteSpace($locationData.Country)) -and [string]::IsNullOrWhiteSpace($countryToWrite)) { $countryToWrite = $locationData.Country }
                    if (-not ([string]::IsNullOrWhiteSpace($locationData.City)) -and [string]::IsNullOrWhiteSpace($cityToWrite)) { $cityToWrite = $locationData.City }
                    if (-not ([string]::IsNullOrWhiteSpace($locationData.CountryCode)) -and [string]::IsNullOrWhiteSpace($countryCodeToWrite)) { $countryCodeToWrite = $locationData.CountryCode }
                }
            } else {
                Write-Warning "   -> Error during Photon reverse geocoding. Using Dawarich data if available."
                # Keep original Dawarich values as Photon failed
            }
        }

        # --- Write EXIF/XMP Data ---
        if (($latitude -ne 0 -or $longitude -ne 0)) {
            $targetDesc = if ($file.Extension.ToLower() -eq ".mp4") { "XMP sidecar for '$($file.Name)'" } else { "EXIF in '$($file.Name)'" }
            # **FIX**: Use ${} for variable interpolation
            Write-Host "   Writing data to ${targetDesc}: Lat=$latitude, Lon=$longitude, Country='$countryToWrite', City='$cityToWrite', Code='$countryCodeToWrite'"

            $writeSuccess = Set-ExifData -ExiftoolExePath $exiftoolPath -FilePath $file.FullName `
                -Latitude $latitude -Longitude $longitude `
                -Country $countryToWrite -City $cityToWrite -CountryCode $countryCodeToWrite # Removed timeout argument

            if (-not $writeSuccess) { $fileHadError = $true; $errorCount++; }
            else { $updatedCount++; }
        } else { Write-Warning "   -> Best match has invalid coordinates (Lat=0, Lon=0). Skipping write operation." }
    }
    else {
        Write-Host "   -> No suitable GPS data found via Dawarich API for '$($file.Name)'."
    }

    if (-not $fileHadError) { Write-Host "---" } # Separator

} # end foreach file

# --- Final Summary ---
Write-Host "`nProcessing finished." -ForegroundColor Green
Write-Host " * Files processed: $processedCount"
Write-Host " * Files updated successfully: $updatedCount"
if ($errorCount -gt 0) {
    Write-Host " * Files with errors or warnings during processing: $errorCount" -ForegroundColor Yellow
}
Write-Host "Script ended."

#endregion Main Script Logic
