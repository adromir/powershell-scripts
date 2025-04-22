<#
.SYNOPSIS
    Updates missing EXIF date information (DateTimeOriginal, CreateDate) in image files (JPG, DNG, CR2) by parsing date and time from filenames formatted as 'IMG_YYYYMMDD_HHMMSS[_TAG].ext'. Also updates file system timestamps.

.DESCRIPTION
    This script automates the process of correcting missing date and time metadata in image files. It targets JPG, DNG, and CR2 files located within a user-specified folder.

    The script performs the following actions for each eligible image file:
    1. Checks for an existing EXIF 'DateTimeOriginal' tag using ExifTool.
    2. If 'DateTimeOriginal' is missing, it examines the filename.
    3. It looks for filenames matching the specific patterns (case-insensitive):
        - IMG_YYYYMMDD_HHMMSS.ext
        - IMG_YYYYMMDD_HHMMSS_TAG.ext (where TAG is any three letters)
       (e.g., IMG_20240422_153000.jpg or IMG_20240422_153000_ABC.dng)
    4. If a matching filename is found, the script extracts the year, month, day, hour, minute, and second.
    5. Using ExifTool, it writes this extracted date and time to the following EXIF tags:
        - DateTimeOriginal
        - CreateDate
    6. It also attempts to clear the IPTCDigest tag if it exists, which might be necessary for some applications to recognize the changes properly.
    7. Finally, it updates the file's system timestamps ('CreationTime' and 'LastWriteTime') to match the date and time extracted from the filename.
    8. The script provides verbose output to the console, showing the selected folder, files found, processing progress, and actions taken for each file.

    Prerequisites:
    - ExifTool (exiftool.exe) must be installed and accessible via the system's PATH environment variable.
    - The script requires permissions to read and write files in the selected folder and modify their metadata.

.NOTES
    Author: Adromir

.PARAMETER Folder
    (Implicit) The script prompts the user to select the target folder containing the image files via a graphical folder browser dialog. There is no command-line parameter for the folder.

.EXAMPLE
    .\exif_date_update.ps1

    Executing the script without parameters will trigger a folder selection dialog. Navigate to and select the folder containing the images you wish to process. The script will then scan the folder and update files according to the logic described above, printing progress and results to the console.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.PowerShell.Utility

# --- Configuration ---
# Define the path to exiftool.exe. Assumes it's in the system PATH.
# If exiftool.exe is elsewhere, provide the full path, e.g., "C:\path\to\exiftool.exe"
$exiftoolPath = "exiftool.exe"

# --- Script Body ---

# Check if ExifTool exists in PATH or specified location
if (-not (Get-Command $exiftoolPath -ErrorAction SilentlyContinue)) {
    Write-Error "ExifTool ('$exiftoolPath') could not be found. Please ensure it is installed and in your system's PATH or provide the full path in the script."
    exit 1
}

# Load necessary assemblies for the folder browser dialog
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    Write-Error "Failed to load Windows Forms assemblies. This script requires a GUI environment to select the folder."
    exit 1
}

# Configure and display the folder browser dialog
$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
$folderBrowser.Description = "Select the folder containing the image files (JPG, DNG, CR2) to process."
$folderBrowser.ShowNewFolderButton = $false
$folderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer # Start browsing from 'My Computer'

# Show the dialog and process if the user clicks OK
if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $folder = $folderBrowser.SelectedPath
    Write-Host "Selected Folder: $folder" -ForegroundColor Green

    # Find image files (JPG, DNG, CR2) directly in the selected folder (non-recursive)
    # Use -LiteralPath for robustness with special characters in folder names
    try {
        $imageFiles = Get-ChildItem -LiteralPath $folder -Include "*.jpg", "*.dng", "*.cr2" -File -ErrorAction Stop
    } catch {
        Write-Error "Error accessing folder or files in '$folder': $($_.Exception.Message)"
        exit 1
    }


    if (-not $imageFiles) {
        Write-Host "No image files (.jpg, .dng, .cr2) found in the selected folder."
        exit 0
    }

    Write-Host "Found $($imageFiles.Count) image files to check."
    # Optional: List found files for confirmation (can be verbose for many files)
    # Write-Host "Files to check:"
    # $imageFiles | ForEach-Object { Write-Host "- $($_.Name)" }

    # Initialize progress variables
    $totalFiles = $imageFiles.Count
    $processedFilesCount = 0
    $updatedFilesCount = 0

    # Process each image file
    foreach ($file in $imageFiles) {
        $processedFilesCount++
        $filePath = $file.FullName
        Write-Progress -Activity "Processing Images" -Status "Checking file $processedFilesCount of $totalFiles: $($file.Name)" -PercentComplete (($processedFilesCount / $totalFiles) * 100)

        Write-Verbose "Processing file $($processedFilesCount) of $($totalFiles): $($file.Name)"

        # Check existing EXIF DateTimeOriginal using ExifTool
        try {
            # -s -s -s : Short output format (value only)
            $exifDateOutput = & $exiftoolPath -s -s -s -DateTimeOriginal "$filePath" -ErrorAction SilentlyContinue # Continue if exiftool gives an error for one file
            $exifDate = $exifDateOutput.Trim() # Trim potential whitespace
        } catch {
            Write-Warning "ExifTool error while reading '$($file.Name)': $($_.Exception.Message)"
            Continue # Skip to the next file
        }


        Write-Verbose "File: $($file.Name), Current EXIF DateTimeOriginal: '$exifDate'"

        # If DateTimeOriginal tag is empty or missing, attempt to parse filename
        if (-not $exifDate) {
            Write-Host "File: $($file.Name) - No existing DateTimeOriginal found. Checking filename..." -ForegroundColor Yellow

            # Check filename pattern (case-insensitive): img_YYYYMMDD_HHMMSS.ext or img_YYYYMMDD_HHMMSS_TAG.ext
            if ($file.Name -imatch "^img_(\d{8})_(\d{6})(?:_[a-zA-Z]{3})?\.(jpg|dng|cr2)$") {
                # Regex breakdown:
                # ^                 - Start of string
                # img_              - Literal "img_"
                # (\d{8})           - Capture group 1: Exactly 8 digits (Date YYYYMMDD)
                # _                 - Literal "_"
                # (\d{6})           - Capture group 2: Exactly 6 digits (Time HHMMSS)
                # (?:_[a-zA-Z]{3})? - Optional non-capturing group: "_" followed by exactly 3 letters (TAG)
                # \.                - Literal "."
                # (jpg|dng|cr2)     - Capture group 3: File extension
                # $                 - End of string

                $datePart = $matches[1] # YYYYMMDD
                $timePart = $matches[2] # HHMMSS

                Write-Verbose "File: $($file.Name) - Filename pattern recognized. Date: $datePart, Time: $timePart"

                # Construct the EXIF date/time string (YYYY:MM:DD HH:MM:SS)
                $year = $datePart.Substring(0, 4)
                $month = $datePart.Substring(4, 2)
                $day = $datePart.Substring(6, 2)
                $hour = $timePart.Substring(0, 2)
                $minute = $timePart.Substring(2, 2)
                $second = $timePart.Substring(4, 2)

                $exifDateTimeString = "${year}:${month}:${day} ${hour}:${minute}:${second}"
                $dotnetDateTimeString = "${year}-${month}-${day} ${hour}:${minute}:${second}" # Format for .NET parsing

                # Validate the parsed date/time before attempting to write
                try {
                    $parsedDateTime = [datetime]::ParseExact($dotnetDateTimeString, "yyyy-MM-dd HH:mm:ss", $null)
                    Write-Verbose "File: $($file.Name) - Parsed DateTime object: $parsedDateTime"
                } catch {
                    Write-Warning "File: $($file.Name) - Could not parse '$dotnetDateTimeString' into a valid DateTime object. Skipping update for this file. Error: $($_.Exception.Message)"
                    Continue # Skip to the next file
                }

                Write-Host "File: $($file.Name) - Attempting to set EXIF date to: $exifDateTimeString" -ForegroundColor Cyan

                # Use ExifTool to write DateTimeOriginal and CreateDate
                # Use -overwrite_original to modify the file in place (faster, but riskier if interrupted)
                # Remove -overwrite_original to have ExifTool create backups (safer)
                # Clear IPTCDigest if it exists, as it can sometimes interfere with updates being recognized
                $exiftoolArgs = @(
                    "-DateTimeOriginal=$exifDateTimeString",
                    "-CreateDate=$exifDateTimeString",
                    "-overwrite_original", # Remove this line to keep backups (_original files)
                    "-if", # Conditional processing: only clear IPTCDigest if it exists
                    '$IPTCDigest',
                    "-IPTCDigest=", # Set IPTCDigest to empty
                    "$filePath"
                )

                try {
                    & $exiftoolPath @exiftoolArgs -ErrorAction Stop
                    Write-Verbose "File: $($file.Name) - ExifTool command executed successfully."

                    # Update file system timestamps (CreationTime, LastWriteTime)
                    $file.CreationTime = $parsedDateTime
                    $file.LastWriteTime = $parsedDateTime

                    Write-Host "File: $($file.Name) - Successfully updated EXIF and file timestamps to: $exifDateTimeString" -ForegroundColor Green
                    $updatedFilesCount++

                } catch {
                    Write-Warning "File: $($file.Name) - ExifTool failed to update metadata. Error: $($_.Exception.Message)"
                    # Attempt to report ExifTool's specific error if possible
                     if ($_.Exception.InnerException) {
                         Write-Warning "ExifTool Inner Exception: $($_.Exception.InnerException.Message)"
                     }
                    # Note: File system timestamps won't be updated if ExifTool fails.
                }
            } else {
                Write-Host "File: $($file.Name) - Filename does not match the required pattern (IMG_YYYYMMDD_HHMMSS[_TAG].ext)."
            }
        } else {
             Write-Verbose "File: $($file.Name) - Already has an EXIF DateTimeOriginal value ('$exifDate'). No action needed."
        }
         Write-Verbose ("-"*40) # Separator for verbose output
    }

    # Final summary
    Write-Progress -Activity "Processing Images" -Completed
    Write-Host "----------------------------------------"
    Write-Host "Processing Complete." -ForegroundColor Green
    Write-Host "Total files checked: $totalFiles"
    Write-Host "Files updated: $updatedFilesCount"
    Write-Host "----------------------------------------"

} else {
    Write-Host "Folder selection cancelled by user."
}

# Clean up variables if running interactively
if ($Host.Name -eq 'ConsoleHost') {
    Remove-Variable folderBrowser, imageFiles, file, exifDate, datePart, timePart, year, month, day, hour, minute, second, exifDateTimeString, dotnetDateTimeString, parsedDateTime, exiftoolArgs -ErrorAction SilentlyContinue
}
