# MP4 Add Missing Date Metadata Script (`mp4_add_missing_date.ps1`)


## Purpose

This PowerShell script provides a graphical user interface (GUI) to select multiple MP4 video files and set or overwrite their creation date metadata. Specifically, it targets the `CreateDate`, `MediaCreateDate`, and `TrackCreateDate` tags, which are often used by software and operating systems (like Windows Explorer's "Media created" column) to determine the video's creation time.

The script is designed to address scenarios where these date tags are missing, empty, or incorrect in MP4 files.

## Features

* **Graphical User Interface (GUI):** Uses Windows Forms for easy file selection and date/time input.
* **Batch Processing:** Allows selecting and processing multiple MP4 files at once.
* **Targeted Metadata Tags:** Reads and writes the following crucial date tags:
    * `CreateDate` (Often read by Windows Explorer)
    * `MediaCreateDate` (QuickTime specific)
    * `TrackCreateDate` (QuickTime specific)
* **Conditional Writing:** By default, writes tags only if at least one of the target date tags appears missing or empty.
* **Overwrite Option:** Includes a checkbox in the GUI to **force** overwriting the date tags, even if they already exist and appear valid.
* **Cancel Option:** Includes a "Cancel" button in the date/time input dialog to abort the process.
* **Direct ExifTool Call:** Uses PowerShell's call operator (`&`) for potentially more reliable execution of the external `exiftool.exe` compared to `Start-Process`.
* **Console Output:** Provides feedback on the processing status of each file, including which tags were found and whether tags were written.

## :warning: CRITICAL WARNING :warning:

* **OVERWRITES ORIGINAL FILES:** This script uses the `-overwrite_original_in_place` option of ExifTool. This means it **MODIFIES YOUR ORIGINAL MP4 FILES DIRECTLY**.
* **NO BACKUPS CREATED:** The script **DOES NOT** create backup copies (`_original` files) of your videos.
* **USE WITH EXTREME CAUTION:** Incorrect usage or unexpected errors could potentially lead to data loss or file corruption.
* **BACK UP YOUR FILES:** It is **STRONGLY RECOMMENDED** to back up your video files manually *before* running this script, especially when processing large batches or valuable files.

## Prerequisites

1.  **Windows Operating System:** The script relies on Windows Forms and PowerShell.
2.  **PowerShell:** Version 3.0 or higher (for `-ErrorVariable` capture, although the latest version removes reliance on it for primary logic) / Version 5.1 or higher recommended (standard on Windows 10/11).
3.  **ExifTool by Phil Harvey:** This script **requires** `exiftool.exe`.
    * Download from the official website: [https://exiftool.org/](https://exiftool.org/)
    * Download the "Windows Executable" version.
    * Rename the downloaded file `exiftool(-k).exe` to `exiftool.exe`.

## Setup

1.  **Save the Script:** Save the PowerShell code as `mp4_add_missing_date.ps1` in a convenient location.
2.  **ExifTool Location:** Ensure `exiftool.exe` is accessible to the script:
    * **Option A (Recommended):** Place `exiftool.exe` in a folder that is included in your system's `PATH` environment variable. The script can then find it automatically.
    * **Option B:** Place `exiftool.exe` in any folder (e.g., `C:\Tools\`) and specify the full path when running the script using the `-ExifToolPath` parameter (see Usage below).
3.  **PowerShell Execution Policy:** You might need to adjust PowerShell's execution policy to run local scripts. Open PowerShell **as Administrator** and run:
    ```powershell
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
    ```
    (Or `Bypass` for testing, though less secure). Answer `Y` (Yes) if prompted. You only need to do this once.

## Usage

1.  **Open PowerShell:** Open a regular PowerShell console (no administrator privileges needed for running, only for changing execution policy).
2.  **Navigate to Script Directory:** Use the `cd` command to change to the directory where you saved `mp4_add_missing_date.ps1`.
    ```powershell
    cd "C:\path\to\your\scripts"
    ```
3.  **Run the Script:**
    * **If `exiftool.exe` is in your PATH:**
        ```powershell
        .\mp4_add_missing_date.ps1
        ```
    * **If `exiftool.exe` is elsewhere:**
        ```powershell
        .\mp4_add_missing_date.ps1 -ExifToolPath "C:\Tools\exiftool.exe"
        ```
        (Replace `"C:\Tools\exiftool.exe"` with the actual path).

4.  **GUI Interaction:**
    * **File Selection:** A window will appear titled "Select MP4 Video Files...". Select one or more MP4 files and click "Open".
    * **Date/Time Input:** A second window "Enter Date, Time, and Options" will appear.
        * Enter the desired **Date** in `DD.MM.YYYY` format.
        * Enter the desired **Time** in `HH:MM:SS` format (24-hour clock).
        * **Overwrite Checkbox:** Check the box "Overwrite existing date tags" if you want to force writing the new date/time even if the script detects existing, valid date tags. Leave it unchecked to only write if tags appear missing/empty.
        * Click **OK** to proceed with the entered values.
        * Click **Cancel** (or press `Esc`) to abort the entire operation.
    * **Processing:** The script will then process the selected files one by one, displaying progress and status messages in the PowerShell console.

## Parameters

* `[-ExifToolPath <String>]`
    * Optional. Specifies the full path to the `exiftool.exe` executable.
    * If not provided, the script assumes `exiftool.exe` is accessible via the system's `PATH` environment variable.
    * **Default:** `"exiftool.exe"`

## Dependencies

* **ExifTool:** Absolutely required. The script is essentially a GUI wrapper around ExifTool's functionality for these specific tags.

## Troubleshooting

* **"ExifTool could not be executed..." Error:** Ensure `exiftool.exe` is correctly named, accessible via the PATH, or that the path provided via `-ExifToolPath` is correct and points to the executable file.
* **"Invalid date or time format..." Error:** Make sure you enter the date as `DD.MM.YYYY` and time as `HH:MM:SS` in the input dialog.
* **ExifTool Exit Code Non-Zero:** If the console output shows `Error writing tags... ExifTool Exit Code: X` (where X is not 0), it means ExifTool encountered an issue.
    * Exit Code 1 usually indicates minor errors or warnings (e.g., file structure issues).
    * The script suggests running the command manually with the `-v` (verbose) option to get more details. Copy the command shown in the console output (`Executing: exiftool.exe ...`), add `-v` after `exiftool.exe`, and run it directly in PowerShell or CMD on a *copy* of the problematic file to diagnose.
* **Date Not Appearing in Windows Explorer:** Windows Explorer most commonly reads the `CreateDate` tag for the "Media created" column. This script writes `CreateDate`, `MediaCreateDate`, and `TrackCreateDate`. If the date still doesn't show after running the script, the file might be unusual, or Explorer might be caching old data (try refreshing with F5 or restarting Explorer).

## License

(Optional: Add a license here, e.g., MIT License)

MIT LicenseCopyright (c) [Year] [Your Name/Alias]Permission is hereby granted, free of charge, to any person obtaining a copyof this software and associated documentation files (the "Software"), to dealin the Software without restriction, including without limitation the rightsto use, copy, modify, merge, publish, distribute, sublicense, and/or sellcopies of the Software, and to permit persons to whom the Software isfurnished to do so, subject to the following conditions:The above copyright notice and this permission notice shall be included in allcopies or substantial portions of the Software.THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS ORIMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THEAUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHERLIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THESOFTWARE.
## Disclaimer

This script modifies files directly without creating backups. The author is not responsible for any data loss or file corruption that may occur as a result of using this script. **Use at your own risk and always back up important data.**
