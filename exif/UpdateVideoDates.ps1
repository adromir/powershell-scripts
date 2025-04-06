<#
.SYNOPSIS
Updates the creation date and date taken of video files in a selected folder, displays progress, and provides a detailed summary.

.DESCRIPTION
This script allows you to select a folder via a GUI.
It asks whether subfolders should be searched AND whether to attempt to extract the date from file names.
File name analysis is only performed if no date is found in the metadata AND the file name matches the pattern 'XXX_YYYYMMDD_HHMMSS.ext' (XXX are 3 letters).

It then searches for video files (AVI, MP4, MOV, WMV, MPG, MPEG, MKV) and displays a progress indicator during processing.
For each file found, it checks if the 'Date Taken' or 'Creation Time' is missing or has a default value (01/01/1601).

If one of the dates is missing, the script attempts to find a date in the following order:
1. 'Media Create Date' metadata field
2. 'Track Create Date' metadata field (if index is configured)
3. File name (if option is enabled and pattern matches: XXX_YYYYMMDD_HHMMSS.ext)

The first valid date found is then used to set the file's 'CreationTime' and 'LastWriteTime'.
Setting the 'Date Taken' is often not reliably possible with pure PowerShell and is NOT performed here.

Finally, a detailed summary of the actions performed is output.

.NOTES
Version:        1.32
Author:         Adromir
Creation Date:  2025-04-06
Last Modified:  2025-04-06
Requirements:   PowerShell 5.1 or later. Windows with .NET Framework for GUI elements.
Limitations:   - Setting the 'Date Taken' metadata field is not possible for many video formats with PowerShell alone. This script only sets CreationTime and LastWriteTime.
                - The detection of the 'Media Create Date' and 'Track Create Date' metadata fields depends on the file type and the software that created the file. The indices used (58, ??) are estimates and may need to be adjusted.
                - File name analysis is limited to the pattern 'ABC_YYYYMMDD_HHMMSS.ext'.
                - The script searches for common video formats. The list can be customized in the script ($videoExtensions).
                - Errors may occur during date analysis or file access.

.EXAMPLE
.\UpdateVideoDates.ps1
Starts the script, displays the folder selection and the queries for subfolder/file name analysis, processes the files with progress display, and outputs a summary.
#>

#region Load GUI and Assembly
#-----------------------------------------------------------------------------------
# Load the required assembly for GUI elements
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    Write-Error "Error loading the .NET assemblies for the GUI. Make sure the .NET Framework is installed."
    Exit 1
}
#endregion

#region Functions for GUI
#-----------------------------------------------------------------------------------
Function Select-FolderDialog {
    param(
        [string]$Description = "Select the folder containing the video files",
        [string]$InitialDirectory = [Environment]::GetFolderPath("MyVideos") # Starts in the user's video folder
    )

    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = $Description
    $folderBrowser.ShowNewFolderButton = $false
    if (Test-Path $InitialDirectory) {
        $folderBrowser.SelectedPath = $InitialDirectory
    }

    # Display the dialog
    $result = $folderBrowser.ShowDialog((New-Object System.Windows.Forms.Form -Property @{TopMost = $true }))

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    } else {
        Write-Warning "No folder selected. Script will be terminated."
        return $null
    }
}

Function Ask-IncludeSubfolders {
    param(
        [string]$Title = "Include subfolders?",
        [string]$Question = "Should video files in subfolders also be processed?"
    )

    $messageBoxResult = [System.Windows.Forms.MessageBox]::Show($Question, $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)

    return ($messageBoxResult -eq [System.Windows.Forms.DialogResult]::Yes)
}

Function Ask-ParseFilename {
    param(
        [string]$Title = "Analyze file name?",
        [string]$Question = "Should an attempt be made to extract the date/time from file names if no metadata is found?`n(Pattern: LETTERS_YYYYMMDD_HHMMSS.ext)"
    )

    $messageBoxResult = [System.Windows.Forms.MessageBox]::Show($Question, $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)

    return ($messageBoxResult -eq [System.Windows.Forms.DialogResult]::Yes)
}
#endregion

#region Script Main Body
#-----------------------------------------------------------------------------------

# --- Configuration ---
# List of video file extensions to consider (lowercase!)
$videoExtensions = @("*.avi", "*.mp4", "*.mov", "*.wmv", "*.mpg", "*.mpeg", "*.mkv") # Add more if necessary

# Indices for metadata properties (These can vary depending on the system/language!)
# You can determine the indices by listing all properties for a test file, e.g.:
# $shell = New-Object -ComObject Shell.Application; $folder = $shell.Namespace('C:\path\to\folder'); $item = $folder.ParseName('filename.avi'); 0..300 | ForEach-Object { "$_ $($folder.GetDetailsOf($null, $_)): $($folder.GetDetailsOf($item, $_))" }
$dateTakenIndex = 12    # Date Taken (often index 12)
$mediaCreateDateIndex = 58 # Media Create Date (index is often difficult to determine, 58 is one possibility under Windows Media Player)
$trackCreateDateIndex = -1 # Track Create Date (even less standardized, -1 means it is not searched for)
# Digitalization date is also not available by default via Shell.Application.

# Regex for the file name pattern: 3 letters, underscore, 8 digits (date), underscore, 6 digits (time), dot, extension
# We check against the base name (without extension)
$filenamePattern = '^([a-zA-Z]{3})_(\d{8})_(\d{6})$'
$filenameDateFormat = "yyyyMMddHHmmss" # Format for ParseExact

# Default "Null" date, often used by PowerShell for missing data
$nullDate = [DateTime]::FromFileTime(0) # Often corresponds to 01/01/1601 00:00:00 UTC, adjusted locally
Write-Verbose "Null date recognized as: $($nullDate.ToString())"

# --- Step 1: Select Path ---
$targetFolderPath = Select-FolderDialog
if (-not $targetFolderPath) {
    Exit # Exit if no folder was selected
}
Write-Host "Selected folder: $targetFolderPath"

# --- Step 2a: Include subfolders? ---
$includeSubfolders = Ask-IncludeSubfolders
if ($includeSubfolders) {
    Write-Host "Subfolders will be included."
    $recurseOption = $true
    $depthOption = [uint32]::MaxValue # No depth limit for recursion
} else {
    Write-Host "Only files in the main folder '$targetFolderPath' will be considered."
    $recurseOption = $false
    $depthOption = 0 # Only the top level
}

# --- Step 2b: Analyze file names? ---
$parseFilename = Ask-ParseFilename
if ($parseFilename) {
    Write-Host "Analysis of file names (pattern: 'XXX_YYYYMMDD_HHMMSS') for date extraction is enabled."
} else {
    Write-Host "File names will NOT be analyzed for date extraction."
}

# --- Step 3: Search for video files ---
Write-Host "Searching for video files ($($videoExtensions -join ', '))..."
$getFilesParams = @{
    Path = $targetFolderPath
    File = $true # Only files
    ErrorAction = 'SilentlyContinue' # Ignore folders that cannot be accessed
}
# Sets the search depth and include pattern based on the PowerShell version and user options
if ($PSVersionTable.PSVersion.Major -ge 5) {
    # Depth is available from PS 5 onwards and is more efficient for non-recursion
    $getFilesParams.Depth = $depthOption
    $getFilesParams.Include = $videoExtensions
    $files = Get-ChildItem @getFilesParams
} else {
    # Older PS versions: Use Recurse or filter afterwards
    $getFilesParams.Recurse = $recurseOption
    if ($recurseOption) {
        $getFilesParams.Include = $videoExtensions
        $files = Get-ChildItem @getFilesParams
    } else {
        # Without recursion: First get all files, then filter
        $files = Get-ChildItem @getFilesParams | Where-Object { $ext = $_.Extension.ToLower(); $videoExtensions -contains "*$ext" }
    }
}


if (-not $files) {
    Write-Host "No video files found in '$targetFolderPath'" + $(if ($includeSubfolders) { " (including subfolders)." } else { "." })
    Exit
} else {
    Write-Host "$($files.Count) video file(s) found."
}

# --- Step 4: Check and process files ---
# Initialize COM object for metadata access
$shell = New-Object -ComObject Shell.Application

# Initialize counters for the summary
$totalFiles = $files.Count
$processedCount = 0      # Total number of loop iterations (should equal $totalFiles, except in case of errors)
$skippedExistingDateCount = 0 # Skipped because date already existed
$skippedNoDateFoundCount = 0 # Skipped because no alternative date was found
$updatedCount = 0          # Successfully updated
$errorCount = 0            # Errors occurred while processing a file

# Initialize progress display
$currentFile = 0
Write-Host "Start processing $totalFiles files..."

foreach ($file in $files) {
    $currentFile++
    $processedCount++ # Counts every attempt to process a file

    # Update progress display
    $percentComplete = if ($totalFiles -gt 0) { ($currentFile / $totalFiles) * 100 } else { 0 }
    Write-Progress -Activity "Processing video files" -Status "Checking file $currentFile of $totalFiles : $($file.Name)" -PercentComplete $percentComplete -Id 1

    $fileName = $file.Name
    $baseName = $file.BaseName # File name without extension
    $directoryPath = $file.DirectoryName
    $fileObject = $null      # Ensure that the variable is defined for finally
    $folderObject = $null      # Ensure that the variable is defined for finally

    try {
        # Get shell objects for the file
        $folderObject = $shell.Namespace($directoryPath)
        if (-not $folderObject) {
            Write-Warning "Cannot access the folder '$directoryPath'. Skipping file '$fileName'."
            $errorCount++
            continue # Next file in the loop
        }
        $fileObject = $folderObject.ParseName($fileName)
        if (-not $fileObject) {
            Write-Warning "Cannot process the file '$fileName' in the folder '$directoryPath'. Skipping."
            $errorCount++
            continue # Next file in the loop
        }

        # Check current date values
        $creationTime = $file.CreationTime
        $dateTakenStr = $folderObject.GetDetailsOf($fileObject, $dateTakenIndex) # Date Taken
        $dateTaken = $null
        $hasValidDateTaken = $false

        # Check if Date Taken is a valid date
        if (-not [string]::IsNullOrWhiteSpace($dateTakenStr)) {
            try {
                # Attempt to parse with current culture
                $dateTaken = [datetime]::Parse($dateTakenStr, [System.Globalization.CultureInfo]::CurrentCulture)
                # Check if it is a "sensible" date (not 01/01/1601 or similar)
                if ($dateTaken -gt $nullDate.AddDays(1)) { # Add a small buffer
                    $hasValidDateTaken = $true
                }
            } catch {
                # Optional: Attempt with invariant culture or other formats, if necessary
                Write-Verbose "Could not convert Date Taken string '$dateTakenStr' to [DateTime] for file '$($file.Name)'."
            }
        }

        # Check if Creation Time is a valid date
        $hasValidCreationTime = $false
        if ($creationTime -gt $nullDate.AddDays(1)) {
            $hasValidCreationTime = $true
        }

        Write-Verbose "File: $($file.Name) | Created: $($creationTime) (Valid: $hasValidCreationTime) | Taken: $($dateTakenStr) (Valid: $hasValidDateTaken)"

        # Skip if both dates appear to be valid
        if ($hasValidCreationTime -and $hasValidDateTaken) {
            Write-Verbose "File '$($file.Name)' already has a valid creation and date taken. Skipping."
            $skippedExistingDateCount++ # Increment counter for existing date
            continue # Next file
        }

        # --- Search for alternative dates ---
        $sourceDate = $null
        $sourceDateString = $null
        $sourceFieldName = "Unknown"

        # 1. Try Media Create Date (index may need to be adjusted)
        if ($mediaCreateDateIndex -ge 0) {
            $sourceDateString = $folderObject.GetDetailsOf($fileObject, $mediaCreateDateIndex)
            if (-not [string]::IsNullOrWhiteSpace($sourceDateString)) {
                try {
                    $parsedDate = [datetime]::Parse($sourceDateString, [System.Globalization.CultureInfo]::CurrentCulture)
                    if ($parsedDate -gt $nullDate.AddDays(1)) {
                        $sourceDate = $parsedDate
                        $sourceFieldName = "'Media Create Date' (Index $($mediaCreateDateIndex))" # Corrected here
                        Write-Verbose "Valid date found from $($sourceFieldName): $sourceDate"
                    } else {
                        Write-Verbose "'Media Create Date' ('$sourceDateString') is not a valid date."
                        $sourceDateString = $null # Reset for next attempt
                    }
                } catch {
                    Write-Verbose "Could not parse '$sourceDateString' (Media Create Date)."
                    $sourceDateString = $null # Reset for next attempt
                }
            }
        }

        # 2. Try Track Create Date (if no Media Create Date was found and index is configured)
        if (-not $sourceDate -and $trackCreateDateIndex -ge 0) {
            $sourceDateString = $folderObject.GetDetailsOf($fileObject, $trackCreateDateIndex)
            if (-not [string]::IsNullOrWhiteSpace($sourceDateString)) {
                try {
                    $parsedDate = [datetime]::Parse($sourceDateString, [System.Globalization.CultureInfo]::CurrentCulture)
                    if ($parsedDate -gt $nullDate.AddDays(1)) {
                        $sourceDate = $parsedDate
                        $sourceFieldName = "'Track Create Date' (Index $($trackCreateDateIndex))" # Corrected here
                        Write-Verbose "Valid date found from $($sourceFieldName): $sourceDate"
                    } else {
                        Write-Verbose "'Track Create Date' ('$sourceDateString') is not a valid date."
                        $sourceDateString = $null
                    }
                } catch {
                    Write-Verbose "Could not parse '$sourceDateString' (Track Create Date)."
                    $sourceDateString = $null
                }
            }
        }

        # 3. Try to extract date from file name (if option is enabled and no date has been found so far)
        if (-not $sourceDate -and $parseFilename) {
            Write-Verbose "No metadata date found. Checking file name '$baseName' for pattern '$filenamePattern'..."
            if ($baseName -match $filenamePattern) {
                # Pattern matches! Extract date and time from the Capture Groups of the $matches variable
                $datePart = $matches[2] #оборотMMDD (second parenthesis in the regex)
                $timePart = $matches[3] # HHMMSS (third parenthesis in the regex)
                $dateTimeString = $datePart + $timePart # Results in e.g. "20231027153000"

                Write-Verbose "Pattern found in file name. Extracted date string: '$dateTimeString'"

                try {
                    # Parse the string with the exact format
                    $parsedDate = [datetime]::ParseExact($dateTimeString, $filenameDateFormat, [System.Globalization.CultureInfo]::InvariantCulture)

                    # Simple plausibility check (e.g. not before 1980)
                    if ($parsedDate -gt ([datetime]"1980-01-01")) {
                        $sourceDate = $parsedDate
                        $sourceFieldName = "File name ('$fileName')"
                        Write-Verbose "Valid date successfully parsed from $($sourceFieldName): $sourceDate" # Corrected here
                    } else {
                        Write-Verbose "Date '$dateTimeString' from file name '$fileName' seems invalid (too old)."
                    }
                } catch {
                    Write-Warning "Error parsing date/time string '$dateTimeString' from file name '$fileName': $($_.Exception.Message)"
                    # No $errorCount++ here, as the file is only skipped
                }
            } else {
                Write-Verbose "File name '$baseName' does not match the pattern '$filenamePattern'."
            }
        }


        # --- Set date if a source was found ---
        if ($sourceDate) {
            Write-Host "Updating date for '$($file.Name)' with date from ${sourceFieldName}: $($sourceDate.ToString())"
            try {
                # IMPORTANT: Set CreationTime and LastWriteTime.
                # Setting 'Date Taken' is NOT implemented here.
                $file.CreationTime = $sourceDate
                $file.LastWriteTime = $sourceDate # It is often useful to also set the modification date
                Write-Host "  -> Creation date and last write date successfully set." -ForegroundColor Green
                $updatedCount++
            } catch {
                Write-Warning "Error setting the date for '$($file.Name)': $($_.Exception.Message)"
                $errorCount++
            }
        } else {
            # Only skip if no date was found at all (not even in the file name)
            Write-Host "For file '$($file.Name)', no valid date could be found in either the metadata or the file name. Skipping."
            $skippedNoDateFoundCount++ # Increment counter for "no date found"
        }

    } catch {
        Write-Warning "Unexpected error processing file '$($file.Name)': $($_.Exception.Message)"
        $errorCount++
    } finally {
        # Release COM objects (important!), even if errors occurred
        if ($fileObject) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fileObject) | Out-Null
            $fileObject = $null # Ensure that it is retrieved again in the next iteration
        }
        if ($folderObject) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($folderObject) | Out-Null
            $folderObject = $null
        }
    }
} # End foreach ($file in $files)

# --- Conclusion ---
# Complete and remove progress display
Write-Progress -Activity "Processing video files" -Completed -Id 1

# Output detailed summary
Write-Host "--------------------------------------------------" -ForegroundColor Blue
Write-Host " PROCESSING SUMMARY" -ForegroundColor Blue
Write-Host "--------------------------------------------------" -ForegroundColor Blue
Write-Host " Selected folder        : $targetFolderPath"
Write-Host " Subfolders searched    : $(if($includeSubfolders){'Yes'}else{'No'})"
Write-Host " File names analyzed     : $(if($parseFilename){'Yes (Pattern: XXX_YYYYMMDD_HHMMSS)'}else{'No'})"
Write-Host "--------------------------------------------------"
Write-Host " Total files found       : $totalFiles"
#Write-Host " Files checked          : $processedCount" # Should equal $totalFiles, except in case of serious errors
Write-Host " Files updated          : $updatedCount" -ForegroundColor Green
Write-Host " Skipped (Date OK)      : $skippedExistingDateCount" -ForegroundColor Yellow
Write-Host " Skipped (No Date)      : $skippedNoDateFoundCount" -ForegroundColor Cyan
Write-Host " Errors during processing: $errorCount" -ForegroundColor Red
Write-Host "--------------------------------------------------" -ForegroundColor Blue

# Finally release shell COM object
if ($shell) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null }
Write-Verbose "Performing Garbage Collection..."
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Write-Host "Script finished."

#endregion
