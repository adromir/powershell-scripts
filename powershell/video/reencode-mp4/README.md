# PowerShell MP4 Re-encoder Script (`reencode-mp4.ps1`)

## Overview

This PowerShell script provides a graphical user interface (GUI) to re-encode existing MP4 video files using FFmpeg. It allows users to select a folder, choose encoding settings (quality presets or specific bitrates), select hardware acceleration (NVENC, QSV, AMF) if available, and optionally process subdirectories and overwrite original files.

The script automatically tests for the availability and basic functionality of NVIDIA (NVENC) and Intel (QSV) hardware encoders. For AMD (AMF), it checks for the presence of compatible hardware and whether the AMF encoder is listed by FFmpeg.

## Features

* **Graphical User Interface (GUI):** Easy-to-use interface for selecting options.
* **Folder Selection:** Browse and select the root folder containing MP4 files.
* **Recursive Search:** Option to include MP4 files in subdirectories.
* **Encoder Detection & Selection:**
    * Automatically tests NVENC (NVIDIA) and QSV (Intel) encoders.
    * Checks for AMD hardware and AMF encoder listing in FFmpeg.
    * Allows selection between available hardware encoders (NVENC, QSV, AMF) or CPU encoding (libx264).
* **Flexible Encoding Settings:**
    * **Quality Presets:** Choose from Low, Medium, or High quality using Constant Rate Factor (CRF) or equivalent Constant Quality (CQ) modes (lower CRF/CQ means higher quality and larger file size).
    * **Specific Bitrate:** Select a target average video bitrate from a predefined list (e.g., 1000 kbps, 5000 kbps, 12000 kbps).
* **Overwrite Option:** Choose whether to overwrite the original MP4 files or create new files with an `_reencoded` suffix (default). **Use overwrite with caution!**
* **Stream Copying:** Copies audio (`-c:a copy`) and subtitle (`-c:s copy`) streams by default to preserve original quality and avoid unnecessary re-encoding.
* **Progress Display:** Shows individual file conversion progress and overall progress in the PowerShell console.

## Requirements

1.  **Windows Operating System:** The script relies on Windows Forms and WMI/CIM for hardware detection.
2.  **PowerShell:** Version 5.1 or later recommended (usually included in Windows 10/11).
3.  **.NET Framework:** Required for Windows Forms GUI elements (usually pre-installed on modern Windows).
4.  **FFmpeg and FFprobe:**
    * Must be installed.
    * The `ffmpeg.exe` and `ffprobe.exe` executables must be accessible via the system's `PATH` environment variable. You can download FFmpeg builds from [https://ffmpeg.org/download.html](https://ffmpeg.org/download.html) or use package managers like Chocolatey or Scoop.
5.  **Compatible Hardware & Drivers (for GPU encoding):**
    * **NVENC:** Requires an NVIDIA GPU with NVENC support and up-to-date drivers.
    * **QSV:** Requires an Intel CPU with integrated graphics supporting Quick Sync Video and up-to-date drivers.
    * **AMF:** Requires an AMD GPU with AMF/VCE/VCN support and up-to-date drivers.

## Installation

1.  **Install FFmpeg:** Download FFmpeg from the official website or using a package manager. Ensure `ffmpeg.exe` and `ffprobe.exe` are in a directory included in your system's `PATH`. You can verify this by opening PowerShell and typing `ffmpeg -version` and `ffprobe -version`. If the commands are recognized, you're set.
2.  **Download the Script:** Save the script content as a `.ps1` file (e.g., `reencode-mp4.ps1`).

## Usage

1.  **Open PowerShell:** Navigate to the directory where you saved the script using the `cd` command.
2.  **Run the Script:** Execute the script by typing:
    ```powershell
    .\reencode-mp4.ps1
    ```
3.  **Folder Selection:** A folder browser dialog will appear. Select the root folder containing the MP4 files you want to process.
4.  **Encoder Check:** The script will test/check available encoders and display the results in the console.
5.  **Options GUI:** The main options window will appear. Select your desired settings (see below).
6.  **Start Conversion:** Click "Start Re-encoding".
7.  **Monitor Progress:** Conversion progress will be displayed in the PowerShell console.

## Options Explained

### 1. Select Encoder (Available)

* Choose the video encoder to use. Only functional/detected encoders will be enabled.
    * **NVENC (NVIDIA):** Uses NVIDIA's hardware encoder. Generally fast and efficient.
    * **Quick Sync (Intel):** Uses Intel's integrated GPU encoder. Good efficiency, especially on laptops.
    * **AMF (AMD):** Uses AMD's hardware encoder. Performance and quality vary depending on the specific GPU and driver version.
    * **CPU (libx264):** Uses software encoding via the highly regarded libx264 library. Offers excellent quality and compatibility but is much slower than hardware encoding.

### 2. Encoding Settings

* Choose **one** method for controlling the output video quality/size:
    * **Quality: Low/Medium/High:** Uses Constant Rate Factor (CRF) for libx264 or equivalent Constant Quality (CQ) modes for hardware encoders. This aims for a consistent visual quality level. Lower values mean higher quality and larger files (CRF/CQ ~28=Low, ~23=Medium, ~18=High). This is generally recommended for quality-based encoding.
    * **Specific Bitrate:** Select a target average video bitrate (in kilobits per second) from the dropdown. This aims for a specific file size based on video duration. Useful if you have strict file size requirements. The script uses appropriate rate control modes (VBR or CBR depending on the encoder) to target the selected bitrate.

### 3. Other Options

* **Include Subdirectories:** Check this box to search for MP4 files within all subfolders of the selected root folder.
* **Overwrite Original Files (Use Caution!):** Check this box to replace the original MP4 files with the re-encoded versions. **This action is irreversible.** If unchecked (default), new files with an `_reencoded` suffix will be created alongside the originals (e.g., `video.mp4` becomes `video_reencoded.mp4`).

## Output Files

* By default (Overwrite unchecked), the script creates new MP4 files in the same directory as the originals, appending `_reencoded` to the original filename before the `.mp4` extension.
* If "Overwrite Original Files" is checked, the original files are replaced.

## Important Notes

* **Overwriting is Permanent:** Double-check your settings before enabling the "Overwrite Original Files" option. There is no undo.
* **GPU Drivers:** Hardware encoding (NVENC, QSV, AMF) heavily relies on having the correct and up-to-date graphics drivers installed. If hardware options are disabled or fail, ensure your drivers are current.
* **Encoder Tests:** The tests for NVENC and QSV attempt a minimal encoding task. The check for AMF only verifies hardware presence and encoder listing. A successful test/check doesn't guarantee flawless encoding for all files or settings, but indicates the encoder is likely usable.
* **Audio/Subtitles:** The script uses `-c:a copy` and `-c:s copy` by default, meaning audio and subtitle tracks are copied directly from the source without re-encoding. This is usually faster and preserves quality. If you need to re-encode audio (e.g., to change bitrate or format), you'll need to modify the `$arguments` line in the script.

## Troubleshooting

* **"ffmpeg/ffprobe command failed or not found":** Ensure FFmpeg is installed and its directory is correctly added to your system's PATH environment variable. Restart PowerShell after modifying the PATH.
* **Hardware Encoder Disabled/Failing:**
    * Verify your hardware supports the specific encoding technology (NVENC, QSV, AMF).
    * Update your graphics drivers (NVIDIA, Intel, or AMD) to the latest version.
    * Check the console output for specific error messages from the encoder test or during conversion.
* **Permissions:** Ensure the script has read permissions for the source files and write permissions for the output directory.

## Disclaimer
The author is not responsible for any data loss or file corruption that may occur as a result of using this script. **Use at your own risk and always back up important data.**

