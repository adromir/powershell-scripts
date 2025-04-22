# Convert-MOVtoMP4 PowerShell Script (`Convert-MOVtoMP4.ps1`)

## Description

This PowerShell script provides a user-friendly graphical interface (GUI) to convert `.mov` video files to `.mp4` format using the powerful `ffmpeg` and `ffprobe` tools. It allows batch conversion within a selected folder, optionally including subdirectories, and offers choices for video encoding quality and hardware acceleration.

## Features

* **GUI Interface:** Easy-to-use Windows Forms interface for selecting options.
* **Folder Selection:** Standard Windows folder browser to choose the source directory.
* **Recursive Search:** Option to include subdirectories when searching for `.mov` files.
* **Encoder Selection:** Choose between CPU encoding (`libx264`) or hardware-accelerated encoding if available:
    * **NVENC:** For NVIDIA GPUs
    * **Quick Sync (QSV):** For Intel integrated GPUs
    * **AMF:** For AMD GPUs
* **Encoder Availability Check:**
    * Performs functional tests for NVENC and QSV before enabling them in the GUI.
    * Checks for the presence of AMD hardware (via WMI/CIM) and confirms `ffmpeg` lists the AMF encoder before enabling it.
* **Quality Presets:**
    * **Low:** Smaller file size (CRF/CQ 28).
    * **Medium:** Balanced size and quality (CRF/CQ 23).
    * **High:** Better quality, larger files (CRF/CQ 18).
    * **Original:** High quality VBR (~CRF/CQ 18) with the maximum bitrate capped near the source video's average bitrate to help control file size while maintaining quality relative to the original.
* **Progress Display:** Shows individual file progress (percentage, time elapsed/duration, source bitrate) and overall progress (files completed/total) in the PowerShell console.
* **Error Handling:** Captures and reports errors from `ffmpeg` and provides a summary of successful and failed conversions.
* **Overwrite Warning:** Warns if an output `.mp4` file already exists (it will be overwritten).

## Requirements

1.  **Windows Operating System:** The script uses Windows Forms and WMI/CIM, making it Windows-specific.
2.  **PowerShell:** Version 3 or higher recommended (for `Get-CimInstance`, although it falls back to `Get-WmiObject`).
3.  **.NET Framework:** Required for Windows Forms. Usually included with Windows.
4.  **FFmpeg and FFprobe:**
    * Must be installed.
    * The `ffmpeg.exe` and `ffprobe.exe` executables must be accessible via the system's `PATH` environment variable. You can download static builds from sites like [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) or the official [FFmpeg website](https://ffmpeg.org/download.html).
5.  **Compatible Hardware and Drivers (for GPU encoding):**
    * **NVENC:** Requires a supported NVIDIA GPU and up-to-date drivers.
    * **QSV:** Requires a supported Intel CPU/iGPU and up-to-date drivers/libraries (often included with Intel graphics drivers).
    * **AMF:** Requires a supported AMD GPU and up-to-date drivers (both GPU and potentially chipset drivers from AMD).

## Usage

1.  Save the script to a file, for example, `Convert-MOVtoMP4.ps1`.
2.  Open PowerShell.
3.  Navigate to the directory where you saved the script using the `cd` command.
4.  Run the script: `.\Convert-MOVtoMP4.ps1`
5.  **Folder Selection:** A folder browser dialog will appear. Select the root folder containing the `.mov` files you want to convert.
6.  **Encoder/Quality Options:** After testing/checking encoder availability, a window will appear:
    * **Select Encoder:** Choose an *enabled* encoder (CPU or available GPU option).
    * **Select Quality:** Choose the desired quality preset. See "Features" above for details on the "Original" setting.
    * **Include Subdirectories:** Check this box if you want the script to search for `.mov` files in subfolders of the selected root folder.
    * Click **Start Conversion**.
7.  **Conversion Process:** The script will search for files and begin converting them one by one. Progress will be displayed in the PowerShell console.
8.  **Completion:** A summary of successful and failed conversions will be shown upon completion.

## Notes

* The "Original" quality setting aims to preserve quality similar to the source *within the limits of the source's average bitrate*. It is *not* a lossless copy and still involves re-encoding. If the source bitrate cannot be determined via `ffprobe`, it defaults to the "High" quality settings without a bitrate cap for that specific file.
* Audio is re-encoded to AAC at 192kbps by default for broad compatibility.
* The script uses `-hide_banner` and `-nostats` for cleaner console output during conversion, relying on the `-progress pipe:1` output for the progress bar.
* If a GPU encoder is listed as available but fails during the actual conversion, ensure your graphics drivers are fully up-to-date directly from the manufacturer (NVIDIA/Intel/AMD).

## Disclaimer
The author is not responsible for any data loss or file corruption that may occur as a result of using this script. **Use at your own risk and always back up important data.**
