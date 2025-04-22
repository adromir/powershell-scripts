<#
.SYNOPSIS
Adds/Overwrites CreateDate, MediaCreateDate, and TrackCreateDate in MP4 files.
Uses an improved GUI with overwrite checkbox and Cancel button. Calls ExifTool directly using '&'.
Requires exiftool.exe.
*** WARNING: This version OVERWRITES the original files directly! ***

.DESCRIPTION
The script first opens a file selection dialog to choose one or more MP4 files.
Then, a dialog for entering a date (DD.MM.YYYY), time (HH:MM:SS), and an option
to overwrite existing tags is displayed. This dialog now includes a Cancel button and corrected spacing.
For each selected file, the script uses exiftool to check if the metadata tags
'CreateDate', 'MediaCreateDate', and 'TrackCreateDate' exist and contain valid data.
If the 'Overwrite existing date tags' checkbox is checked OR if any of these tags
appear missing or empty, ALL THREE tags will be written (or overwritten) with the
entered date and time using a direct call to exiftool ('&').
This aims to ensure visibility in Windows Explorer (via 'CreateDate') and compatibility.
*** This version MODIFIES FILES IN-PLACE. NO BACKUPS (.mp4_original) ARE CREATED. ***

.PARAMETER ExifToolPath
Optional: The full path to exiftool.exe. If not specified,
the script attempts to call exiftool via the system path (PATH).

.EXAMPLE
.\mp4_add_missing_date.ps1
# Opens the GUI dialogs (with overwrite checkbox, Cancel button) and processes the selected files, overwriting originals.

.EXAMPLE
.\mp4_add_missing_date.ps1 -ExifToolPath "C:\Tools\exiftool.exe"
# Uses exiftool from the specified path, overwriting originals.

.NOTES
Ensure that exiftool.exe is available and executable.
*** CRITICAL WARNING: This script version overwrites original files directly! ***
*** NO backup files (_original) are created. Use with extreme caution. ***
*** It is strongly recommended to back up your files manually before running this script. ***
Windows Explorer most likely reads the 'CreateDate' tag for its "Media created" column.
This version uses the '&' call operator instead of Start-Process.
Includes checkbox to force overwriting existing tags.
GUI layout calculation and spacing corrected.
#>
param(
    [string]$ExifToolPath = "exiftool.exe" # Default: Search in PATH
)

# --- GUI and Helper Functions ---

# Function to display the file selection dialog
function Select-Mp4FilesDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openFileDialog.Title = "Select MP4 Video Files (Originals will be Overwritten!)"
    $openFileDialog.Filter = "MP4 Files (*.mp4)|*.mp4|All Files (*.*)|*.*"
    $openFileDialog.Multiselect = $true
    $result = $openFileDialog.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $openFileDialog.FileNames
    } else {
        Write-Warning "No files selected."
        return $null
    }
}

# Function to display the Date/Time input dialog with Overwrite Checkbox and Cancel Button
function Get-DateTimeDialog {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Enter Date, Time, and Options'
    # Increased height again for better spacing
    $form.Size = New-Object System.Drawing.Size(320, 260)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $labelDate = New-Object System.Windows.Forms.Label
    $labelDate.Location = New-Object System.Drawing.Point(10, 20)
    $labelDate.Size = New-Object System.Drawing.Size(280, 20)
    $labelDate.Text = 'Date (DD.MM.YYYY):'
    $form.Controls.Add($labelDate)

    $textBoxDate = New-Object System.Windows.Forms.TextBox
    $textBoxDate.Location = New-Object System.Drawing.Point(10, 40)
    $textBoxDate.Size = New-Object System.Drawing.Size(280, 20)
    $textBoxDate.Text = (Get-Date).ToString("dd.MM.yyyy") # Default: Today
    $form.Controls.Add($textBoxDate)

    $labelTime = New-Object System.Windows.Forms.Label
    $labelTime.Location = New-Object System.Drawing.Point(10, 70)
    $labelTime.Size = New-Object System.Drawing.Size(280, 20)
    $labelTime.Text = 'Time (HH:MM:SS):'
    $form.Controls.Add($labelTime)

    $textBoxTime = New-Object System.Windows.Forms.TextBox
    $textBoxTime.Location = New-Object System.Drawing.Point(10, 90)
    $textBoxTime.Size = New-Object System.Drawing.Size(280, 20)
    $textBoxTime.Text = (Get-Date).ToString("HH:mm:ss") # Default: Now
    $form.Controls.Add($textBoxTime)

    # --- Add Checkbox ---
    $checkBoxOverwrite = New-Object System.Windows.Forms.CheckBox
    $checkBoxOverwrite.Location = New-Object System.Drawing.Point(10, 130) # Position below time input
    $checkBoxOverwrite.Size = New-Object System.Drawing.Size(280, 20)
    $checkBoxOverwrite.Text = 'Overwrite existing date tags'
    $checkBoxOverwrite.Checked = $false # Default to not checked
    $form.Controls.Add($checkBoxOverwrite)

    # --- Add Buttons ---
    # Set Y position higher up to leave more space at the bottom
    $buttonY = $form.ClientSize.Height - 50
    $buttonWidth = 75
    $buttonHeight = 23
    $buttonSpacing = 10
    $totalButtonWidth = ($buttonWidth * 2) + $buttonSpacing
    # Corrected calculation, ensuring integer conversion for safety
    $buttonStartX = [int](($form.ClientSize.Width - $totalButtonWidth) / 2)
    # Calculate Cancel button X separately
    $cancelButtonX = $buttonStartX + $buttonWidth + $buttonSpacing

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Location = New-Object System.Drawing.Point($buttonStartX, $buttonY)
    $okButton.Size = New-Object System.Drawing.Size($buttonWidth, $buttonHeight)
    $okButton.Text = 'OK'
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)
    $form.AcceptButton = $okButton # Enter key triggers OK

    $cancelButton = New-Object System.Windows.Forms.Button
    # Use corrected X calculation
    $cancelButton.Location = New-Object System.Drawing.Point($cancelButtonX, $buttonY)
    $cancelButton.Size = New-Object System.Drawing.Size($buttonWidth, $buttonHeight)
    $cancelButton.Text = 'Cancel'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel # Closes form with Cancel result
    $form.Controls.Add($cancelButton)
    $form.CancelButton = $cancelButton # Escape key triggers Cancel

    # Validation logic on closing via OK
    $form.Add_FormClosing({
        param($sender, $e)
        # Only validate if closing via OK button
        if ($sender.DialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
            $dateTimeString = "$($textBoxDate.Text) $($textBoxTime.Text)"
            try {
                $parsedDateTime = [datetime]::ParseExact($dateTimeString, 'dd.MM.yyyy HH:mm:ss', $null)
                # Store both DateTime and Checkbox state in the Tag using a PSCustomObject
                $sender.Tag = [PSCustomObject]@{
                    TargetDateTime = $parsedDateTime
                    OverwriteTags = $checkBoxOverwrite.Checked
                }
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Invalid date or time format.`nPlease use DD.MM.YYYY and HH:MM:SS.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                $e.Cancel = $true # Prevent closing if validation fails
            }
        }
    })

    $dialogResult = $form.ShowDialog()

    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        # Return the PSCustomObject stored in the Tag
        return $form.Tag
    } else {
        Write-Warning "Date/Time input cancelled."
        return $null # Return null if Cancelled or closed
    }
}

# --- Main Logic ---
# (No changes below this line compared to V6)

# 0. Check if exiftool is accessible
$exiftoolTest = & $ExifToolPath -ver 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "ExifTool could not be executed at '$ExifToolPath'. Ensure it is installed and in the PATH, or provide the correct path using -ExifToolPath."
    exit 1
} else {
    Write-Host "ExifTool Version $($exiftoolTest) found."
}


# 1. Select files
$selectedFiles = Select-Mp4FilesDialog
if (-not $selectedFiles) {
    Write-Host "Operation cancelled."
    exit
}
Write-Host "Files selected: $($selectedFiles.Count)"
Write-Warning "!!! WARNING: THE ORIGINAL FILES LISTED ABOVE WILL BE OVERWRITTEN DIRECTLY !!!"
# Optional: Add a pause here to allow the user to cancel
# Read-Host -Prompt "Press Enter to continue or CTRL+C to abort"


# 2. Enter date and time and get overwrite flag
$dateTimeInputResult = Get-DateTimeDialog
if (-not $dateTimeInputResult) {
    Write-Host "Operation cancelled."
    exit # Exit if user cancelled the date/time dialog
}
# Extract values from the returned object
$targetDateTime = $dateTimeInputResult.TargetDateTime
$overwriteExistingTags = $dateTimeInputResult.OverwriteTags

# Prepare format for Exiftool (YYYY:MM:DD HH:MM:SS)
$exifToolDateTimeFormat = $targetDateTime.ToString('yyyy:MM:dd HH:mm:ss')
Write-Host "Target date/time for metadata: $exifToolDateTimeFormat"
Write-Host "Overwrite existing tags requested: $overwriteExistingTags"


# 3. Loop through files and check/write metadata
Write-Host "Starting file processing (overwriting originals)..."
$filesProcessed = 0
$tagsWrittenCount = 0

foreach ($filePath in $selectedFiles) {
    $filesProcessed++
    $fileName = Split-Path -Leaf $filePath
    Write-Host "[$($filesProcessed)/$($selectedFiles.Count)] Processing: $fileName"

    try {
        # Read potentially relevant date tags using exiftool (as JSON)
        $metadataJson = & $ExifToolPath -j -G1 -a -s -api "QuickTimeUTC" -CreateDate -MediaCreateDate -TrackCreateDate $filePath | ConvertFrom-Json
        $metadata = $metadataJson[0] # Exiftool returns an array

        # --- Refined Check ---
        # Check if the specific keys exist AND have a non-empty/non-null value.
        $createDateExists = $false
        $mediaCreateDateExists = $false
        $trackCreateDateExists = $false
        $reasonForWriting = "" # Store why we are writing

        if ($metadata) {
             if (($metadata.'QuickTime:CreateDate' -ne $null -and $metadata.'QuickTime:CreateDate' -ne "") `
              -or ($metadata.'Keys:CreationDate' -ne $null -and $metadata.'Keys:CreationDate' -ne "")) {
                 $createDateExists = $true
                 Write-Host "  -> Found existing CreateDate/CreationDate tag." # Debugging info
             }
             if ($metadata.'QuickTime:MediaCreateDate' -ne $null -and $metadata.'QuickTime:MediaCreateDate' -ne "") {
                 $mediaCreateDateExists = $true
                 Write-Host "  -> Found existing MediaCreateDate tag." # Debugging info
             }
             if ($metadata.'QuickTime:TrackCreateDate' -ne $null -and $metadata.'QuickTime:TrackCreateDate' -ne "") {
                 $trackCreateDateExists = $true
                 Write-Host "  -> Found existing TrackCreateDate tag." # Debugging info
             }
        }

        # --- Modified Decision Logic ---
        # Decide whether to write: Write if Overwrite requested OR if ANY relevant date tags seem missing/empty
        $tagsAreMissingOrEmpty = (-not ($createDateExists -and $mediaCreateDateExists -and $trackCreateDateExists))
        if ($overwriteExistingTags -or $tagsAreMissingOrEmpty) {

            # Determine the reason for logging message
            if ($overwriteExistingTags) {
                $reasonForWriting = "(Overwrite requested)"
            } else { # $tagsAreMissingOrEmpty must be true
                $reasonForWriting = "(At least one tag missing/empty)"
            }

            Write-Host "  -> Writing CreateDate, MediaCreateDate, TrackCreateDate $reasonForWriting (Overwriting Original)..." -ForegroundColor Yellow

            # Define arguments for direct call
            $directArguments = @(
                "-CreateDate=$exifToolDateTimeFormat",
                "-MediaCreateDate=$exifToolDateTimeFormat",
                "-TrackCreateDate=$exifToolDateTimeFormat",
                "-overwrite_original_in_place", # WARNING: Overwrites the original file directly!
                "-api", "QuickTimeUTC",
                # "-m",
                $filePath
            )

            Write-Host "  -> Executing: $ExifToolPath $($directArguments -join ' ')" # Debug: Show command line

            try {
                # Use the call operator '&' to execute exiftool directly
                & $ExifToolPath $directArguments

                # Check PowerShell's automatic $LASTEXITCODE variable
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  -> Tags written successfully (Original file overwritten)." -ForegroundColor Green
                    $tagsWrittenCount++
                } else {
                    # ExifTool returned a non-zero exit code
                    Write-Warning "  -> Error writing tags for '$fileName'. ExifTool Exit Code: $LASTEXITCODE."
                    Write-Warning "  -> Run manually with '-v' option for details if needed: $($ExifToolPath) -v $($directArguments -join ' ')"
                }
            } catch {
                 # Catch errors from PowerShell trying to execute '&' itself
                 Write-Error "  -> PowerShell execution error when trying to run ExifTool for '$fileName':"
                 Write-Error "     $($_.Exception.Message)"
                 Write-Error "     $($_.ScriptStackTrace)"
            }
            # --- End of Direct Call block ---

        } else {
            Write-Host "  -> All relevant date tags seem to exist and have values. Skipping write (Overwrite not requested)."
        }

    } catch {
        Write-Error "Error processing '$fileName': $($_.Exception.Message)"
        Write-Error "Exception Details: $($_.Exception | Format-List -Force | Out-String)"
        # if ($metadataJson) { Write-Error "Problematic JSON: $($metadataJson | ConvertTo-Json -Depth 5)" }
    }
    Write-Host "---"
}

Write-Host "Processing complete."
Write-Host "Total files processed: $filesProcessed"
Write-Host "Files modified (Originals Overwritten): $tagsWrittenCount"
Write-Warning "Reminder: Original files were modified directly. No automatic backups were created by this script."
