# EXIF Date Updater PowerShell Script (`exif_date_update.ps1`)

## Overview

This PowerShell script automates the process of correcting missing EXIF date and time metadata (`DateTimeOriginal`, `CreateDate`) in image files (JPG, DNG, CR2). It achieves this by parsing the date and time information directly from filenames that follow a specific format. Additionally, it updates the file system's creation and last modified timestamps to match the extracted date.

The script is designed to be run interactively, prompting the user to select a folder containing the images they wish to process.

## Features

* **Folder Selection:** Uses a graphical interface (Folder Browser Dialog) for easy selection of the target image folder.
* **File Type Support:** Processes `.jpg`, `.dng`, and `.cr2` image files.
* **EXIF Check:** Checks if `DateTimeOriginal` already exists in the image's metadata using ExifTool. Skips files that already have this tag populated.
* **Filename Parsing:** Identifies files with missing `DateTimeOriginal` whose names match the patterns:
    * `IMG_YYYYMMDD_HHMMSS.ext`
    * `IMG_YYYYMMDD_HHMMSS_TAG.ext` (where `TAG` is any three letters, case-insensitive)
* **EXIF Data Writing:** Writes the extracted date and time to the `DateTimeOriginal` and `CreateDate` EXIF tags using ExifTool.
* **IPTCDigest Handling:** Attempts to clear the `IPTCDigest` tag if present, which can help ensure other applications recognize the metadata changes.
* **File Timestamp Update:** Modifies the file's system `CreationTime` and `LastWriteTime` to match the extracted date and time.
* **Progress & Feedback:** Provides console output detailing the selected folder, files found, processing progress (including a progress bar), actions taken per file (success, skipped, warnings), and a final summary.
* **Error Handling:** Includes checks for ExifTool availability, ability to load required assemblies, file access errors, and date parsing errors.
* **Safety Option:** Uses ExifTool's `-overwrite_original` flag by default for faster in-place editing. This can be commented out in the script to enable automatic backups (`_original` files).

## Requirements

1.  **Windows PowerShell:** Version 5.1 or later (checked via `#Requires -Version 5.1`).
2.  **ExifTool:** Phil Harvey's ExifTool must be installed and accessible. The script assumes `exiftool.exe` is in the system's PATH environment variable.
    * You can download ExifTool from [https://exiftool.org/](https://exiftool.org/).
    * If ExifTool is installed elsewhere, you *must* edit the `$exiftoolPath` variable at the beginning of the script to provide the full path to `exiftool.exe`.
3.  **.NET Framework:** Required for `System.Windows.Forms` used by the folder browser dialog (typically available on modern Windows systems).
4.  **Permissions:** The user running the script needs read and write permissions for the image files and the folder containing them.

## Installation

1.  **Install ExifTool:** Download ExifTool from [https://exiftool.org/](https://exiftool.org/) and follow its installation instructions. Ensure `exiftool.exe` is either added to your system's PATH or note its full installation path.
2.  **Save the Script:** Save the PowerShell code as `exif_date_update.ps1` in a convenient location.
3.  **(Optional) Configure ExifTool Path:** If `exiftool.exe` is not in your PATH, open `exif_date_update.ps1` in a text editor and modify the line `$exiftoolPath = "exiftool.exe"` to `$exiftoolPath = "C:\path\to\your\exiftool.exe"`, replacing the example path with the actual one.

## Usage

1.  **Open PowerShell:** Launch a PowerShell console. You might need to run it as Administrator if you encounter permission issues, although standard user permissions are usually sufficient if you own the files.
2.  **Navigate to Script Directory (Optional):** You can change the directory to where you saved the script using the `cd` command:
    ```powershell
    cd C:\path\to\your\scripts
    ```
3.  **Run the Script:** Execute the script by typing its path and name:
    * If you navigated to the directory:
        ```powershell
        .\exif_date_update.ps1
        ```
    * If running from a different directory:
        ```powershell
        C:\path\to\your\scripts\exif_date_update.ps1
        ```
    * **Execution Policy:** If you encounter an error about scripts being disabled, you may need to adjust PowerShell's execution policy for the current session:
        ```powershell
        Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
        .\exif_date_update.ps1
        ```
4.  **Select Folder:** A folder browser dialog will appear. Navigate to and select the folder containing the JPG, DNG, or CR2 files you want to process. Click "OK".
5.  **Monitor Progress:** The script will output its progress to the PowerShell console, indicating which file it's processing, whether it's updating a file, skipping it, or encountering issues.
6.  **Review Summary:** Once finished, a summary showing the total files checked and the number of files updated will be displayed.

## Expected Filename Format

The script specifically looks for filenames matching these patterns (case-insensitive):

1.  `IMG_YYYYMMDD_HHMMSS.ext`
2.  `IMG_YYYYMMDD_HHMMSS_TAG.ext`

Where:
* `IMG_`: Literal prefix.
* `YYYYMMDD`: 8 digits representing the date (Year, Month, Day).
* `HHMMSS`: 6 digits representing the time (Hour, Minute, Second) in 24-hour format.
* `_TAG`: (Optional) An underscore followed by exactly three letters (e.g., `_ABC`, `_XYZ`).
* `.ext`: The file extension (`.jpg`, `.dng`, or `.cr2`).

**Examples of matching filenames:**

* `IMG_20240422_153000.jpg`
* `img_20231101_090515.dng`
* `IMG_20250110_235958_XYZ.cr2`
* `img_20241225_000001_abc.jpg`

**Examples of non-matching filenames:**

* `IMG_2024-04-22_15-30-00.jpg` (uses hyphens)
* `MyPhoto_20240422_153000.jpg` (different prefix)
* `IMG_20240422_153000_ABCD.jpg` (tag is four letters)
* `IMG_20240422153000.jpg` (missing underscore between date and time)

## Important Notes

* **Backups:** By default, the script uses the `-overwrite_original` flag with ExifTool, which modifies files *in place* without creating backups. This is faster but carries more risk if the process is interrupted or fails unexpectedly. To enable backups (ExifTool will create `filename.ext_original` files), comment out or remove the line `"-overwrite_original",` within the `$exiftoolArgs` array in the script.
* **Irreversible Changes:** Modifying EXIF data and file timestamps are generally irreversible actions unless you have backups. Use with caution and consider testing on a small batch of copied files first.
* **Verbose Output:** The script includes `Write-Verbose` commands. To see this detailed output (e.g., exact EXIF data found, parsing steps), run the script with the `-Verbose` switch: `.\exif_date_update.ps1 -Verbose`.
