<#
.SYNOPSIS
    Processes image files (JPG, DNG, CR2) in a selected folder and updates their EXIF data based on filenames.

.DESCRIPTION
    This script processes image files (JPG, DNG, CR2) within a user-selected folder. It checks if the image files have EXIF DateTimeOriginal data. If this data is missing, it attempts to extract date and time information from the filenames, provided they match the format IMG_YYYYMMDD_HHMMSS.ext or IMG_YYYYMMDD_HHMMSS_TAG.ext (where TAG is a 3-letter identifier). The extracted data is then written to the EXIF DateTimeOriginal and CreateDate tags. Additionally, the file's creation and last write times are updated to match the extracted date and time. The script provides verbose output, displaying progress and actions taken.

.NOTES
    Author: Adromir
    Date: 06.04.2025
    Version: 1.0

.PARAMETER Folder
    The folder containing the image files to process.

.EXAMPLE
    .\exif_date_update.ps1
    A folder selection dialog will appear. Select the folder containing the image files. The script will process the files and display progress.
#>

# ExifTool Path (uses system PATH)
$exiftoolPath = "exiftool.exe"

# Folder Selection Dialog
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
$folderBrowser.Description = "Please select the folder containing the images."
$folderBrowser.ShowNewFolderButton = $false

if ($folderBrowser.ShowDialog() -eq "OK") {
    $folder = $folderBrowser.SelectedPath

    Write-Host "Selected Folder: $folder"

    # Find image files in folder (corrected with wildcard in path)
    $imageFiles = Get-ChildItem -Path "$folder\*" -Include "*.jpg", "*.dng", "*.cr2" -File

    Write-Host "Found Files:"
    foreach ($file in $imageFiles) {
        Write-Host $file.FullName
    }

    # Initialize progress variables
    $totalFiles = $imageFiles.Count
    $processedFiles = 0

    # Process each image file
    foreach ($file in $imageFiles) {
        $processedFiles++
        Write-Host "Processing file $($processedFiles) of $($totalFiles): $($file.Name)"

        # Check EXIF data
        $exifDate = & $exiftoolPath -s -s -s -DateTimeOriginal "$($file.FullName)"

        Write-Host "File: $($file.Name), EXIF Date: $exifDate"

        # If no EXIF date found, check filename
        if (-not $exifDate) {
            # Case-insensitive filename comparison (extended for tag)
            if ($file.Name -imatch "img_(\d{8})_(\d{6})(_[a-z]{3})?\.(jpg|dng|cr2)$") {
                $datePart = $matches[1]
                $timePart = $matches[2]
                $fileExtension = $matches[4]

                Write-Host "File: $($file.Name), Filename pattern recognized"

                # Create date and time from filename
                $year = $datePart.Substring(0, 4)
                $month = $datePart.Substring(4, 2)
                $day = $datePart.Substring(6, 2)
                $hour = $timePart.Substring(0, 2)
                $minute = $timePart.Substring(2, 2)
                $second = $timePart.Substring(4, 2)

                # Corrected string interpolation with curly braces
                $dateTime = "${year}:${month}:${day} ${hour}:${minute}:${second}"

                Write-Host "File: $($file.Name), Setting EXIF date to: $dateTime"

                # Write EXIF data and update IPTCDigest
                & $exiftoolPath "-DateTimeOriginal=$dateTime" "-CreateDate=$dateTime" "-if" "\$IPTCDigest" "-IPTCDigest=" "$($file.FullName)"

                # Update file date
                $file.CreationTime = [datetime]::ParseExact($dateTime, "yyyy:MM:dd HH:mm:ss", $null)
                $file.LastWriteTime = [datetime]::ParseExact($dateTime, "yyyy:MM:dd HH:mm:ss", $null)

                Write-Host "File: $($file.Name), EXIF and file date updated: $dateTime"
            } else {
                Write-Host "File: $($file.Name), Filename pattern not recognized"
            }
        }
    }

    Write-Host "Processing completed."
} else {
    Write-Host "Folder selection cancelled."
}