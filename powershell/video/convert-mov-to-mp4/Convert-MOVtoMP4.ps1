<# .SYNOPSIS
Converts MOV files to MP4 files with optional subfolder processing, progress display, and GPU acceleration selection (VBR). Checks for functional encoders (NVENC/QSV) or hardware+listing (AMF). "Original" quality uses VBR capped at source average bitrate.

.DESCRIPTION
This script allows you to select a folder, search it (and optionally subfolders) for MOV files, and convert them into MP4 files using ffmpeg.
Before showing options, it tests if NVENC and Quick Sync encoders are functional. For AMF, it checks if an AMD GPU is detected AND if AMF is listed by ffmpeg.
It provides a GUI to select an available encoder, quality (Low, Medium, High, Original), and whether to include subdirectories.
The "Original" quality setting now uses high-quality VBR parameters, but caps the maximum bitrate near the average bitrate of the source video to control file size.
The progress of each conversion and the overall progress will be displayed in the console.

.PARAMETER IncludeSubdirectories
This parameter is handled via the GUI checkbox now. Running the script directly with parameters is not the primary intended use after GUI addition.

.EXAMPLE
.\Convert-MOVtoMP4.ps1
# This will launch the folder browser, test/check encoders, and then show the options GUI.

.NOTES
Make sure that ffmpeg and ffprobe are installed and available in the system's PATH.
The script requires .NET Framework for the Windows Forms GUI and WMI/CIM access for the AMF hardware check.
GPU encoding options (NVENC, QSV, AMF) require compatible hardware AND correctly installed/updated drivers.
The script attempts functional tests for NVENC/QSV. For AMF, it checks for compatible hardware via WMI/CIM and if ffmpeg lists the encoder. Ensure drivers are updated if selecting AMF.
The "Original" quality setting requires ffprobe to determine the source bitrate for capping; if ffprobe fails or bitrate is unavailable, it falls back to standard High quality VBR for that file.
#>

# Load necessary assembly for Windows Forms
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing # Required for Point and Size

# --- Function to Test FFmpeg Encoder Functionality (Used for NVENC, QSV) ---
function Test-FfmpegEncoder {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EncoderName
    )

    Write-Host "Testing encoder: $EncoderName..."
    # Use testsrc which generates a standard pattern
    $testArguments = "-v quiet -f lavfi -i testsrc=size=32x32:rate=1:duration=0.1 -pix_fmt yuv420p -frames:v 1 -c:v $EncoderName -f null NUL"

    # Write-Host "[DEBUG] Test Command: ffmpeg $testArguments" # Uncomment to see exact test command

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = "ffmpeg"
    $processInfo.Arguments = $testArguments
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardError = $true # Capture errors
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $errorOutput = "" # Initialize error output string

    try {
        $process.Start() | Out-Null
        if ($process.WaitForExit(7000)) { # Timeout 7 seconds
             $errorOutput = $process.StandardError.ReadToEnd()
             if ($process.ExitCode -eq 0) {
                Write-Host "Encoder '$EncoderName' test successful." -ForegroundColor Green
                return $true
             } else {
                Write-Warning "Encoder '$EncoderName' test failed (ExitCode: $($process.ExitCode)). It might be unavailable or misconfigured."
                if (![string]::IsNullOrWhiteSpace($errorOutput)) {
                    Write-Warning "FFmpeg error output during test for $EncoderName : $errorOutput"
                }
                return $false
             }
        } else {
            Write-Warning "Encoder '$EncoderName' test timed out after 7 seconds. Assuming unavailable."
            if (!$process.HasExited) { try { $process.Kill() } catch { Write-Warning "Failed to kill timed-out test process for $EncoderName." } }
            try { $errorOutput = $process.StandardError.ReadToEnd(); if (![string]::IsNullOrWhiteSpace($errorOutput)) { Write-Warning "FFmpeg error output during timed-out test for $EncoderName : $errorOutput" } } catch {}
            return $false
        }
    } catch {
        Write-Error "An exception occurred while testing encoder '$EncoderName': $($_.Exception.Message)"
        try { if ($process -ne $null -and !$process.HasExited) { $errorOutput = $process.StandardError.ReadToEnd(); if (![string]::IsNullOrWhiteSpace($errorOutput)) { Write-Warning "FFmpeg error output during exception for $EncoderName : $errorOutput" } } } catch {}
        return $false
    } finally {
        if ($process -ne $null) { $process.Dispose() }
    }
}

# --- Check FFmpeg/FFprobe Availability and Get Encoder List ---
try {
    Write-Host "Checking ffprobe..."
    $null = ffprobe -version -v quiet 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ffprobe command failed or not found." }
    Write-Host "ffprobe found."

    Write-Host "Getting ffmpeg encoder list..."
    # Run without -v quiet to ensure encoder list is included
    $ffmpegEncodersOutput = ffmpeg -encoders 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($ffmpegEncodersOutput -match "Unrecognized option 'encoders'") { throw "Your ffmpeg version might be too old and doesn't support '-encoders'. Please update ffmpeg." }
        else { throw "ffmpeg -encoders command failed. Ensure ffmpeg is in PATH and working." }
    }
    if ($ffmpegEncodersOutput -notlike "*Encoders:*`n*-------*") { Write-Warning "ffmpeg -encoders output format might be unexpected. Encoder detection may be unreliable." }
    Write-Host "FFmpeg encoder list retrieved."

} catch {
    Write-Error "ffmpeg/ffprobe command failed or not found. Please ensure FFmpeg tools are installed and added to your system's PATH. Exiting script."
    Write-Error "Specific Error: $($_.Exception.Message)"
    Read-Host "Press Enter to exit..."
    return
}

# --- Check Hardware and Encoder Availability ---
Write-Host "`n--- Checking Encoder Availability ---"
# Functional tests for NVENC and QSV
$isNvencFunctional = Test-FfmpegEncoder -EncoderName "h264_nvenc"
$isQsvFunctional = Test-FfmpegEncoder -EncoderName "h264_qsv"

# Combined check for AMF: Hardware presence + ffmpeg listing
Write-Host "Checking for AMD GPU hardware..."
$amdGpuDetected = $false
try {
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) { $videoControllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop }
    else { $videoControllers = Get-WmiObject -Class Win32_VideoController -ErrorAction Stop }
    if ($videoControllers | Where-Object { $_.Name -like '*AMD*' -or $_.Name -like '*Radeon*' }) { $amdGpuDetected = $true; Write-Host "AMD GPU detected." -ForegroundColor Green }
    else { Write-Host "No AMD GPU detected." }
} catch { Write-Warning "Could not query video controllers via WMI/CIM: $($_.Exception.Message)" }

Write-Host "Checking for AMF encoder listing (using -match)..."
$amfListed = $ffmpegEncodersOutput -match 'h264_amf'
if ($amfListed) { Write-Host "Encoder 'h264_amf' was found in ffmpeg output." -ForegroundColor Green }
else { Write-Host "Encoder 'h264_amf' was NOT found in ffmpeg output." }

# AMF is considered functional if hardware is detected AND it's listed in ffmpeg
$isAmfFunctional = $amdGpuDetected -and $amfListed
if ($isAmfFunctional) { Write-Host "AMF option will be enabled (Hardware found and encoder listed)." -ForegroundColor Green }
else { Write-Host "AMF option will be disabled (Hardware: $amdGpuDetected, Listed: $amfListed)." }

# CPU (libx264) is assumed functional if ffmpeg runs
$isCpuFunctional = $true
Write-Host "------------------------------------`n"


# Determine the default checked encoder based on availability
$defaultEncoder = "CPU" # Fallback
if ($isNvencFunctional) { $defaultEncoder = "NVENC" }
elseif ($isQsvFunctional) { $defaultEncoder = "Quick Sync" }
elseif ($isAmfFunctional) { $defaultEncoder = "AMF" }
# --- DEBUGGING OUTPUT ---
# Write-Host "[DEBUG] Encoder Check Results:"
# Write-Host "[DEBUG] NVENC Functional: $isNvencFunctional"
# Write-Host "[DEBUG] QSV Functional:   $isQsvFunctional"
# Write-Host "[DEBUG] AMD GPU Detected: $amdGpuDetected"
# Write-Host "[DEBUG] AMF Listed (-match): $amfListed"
# Write-Host "[DEBUG] AMF Enabled:      $isAmfFunctional"
# Write-Host "[DEBUG] Determined Default Encoder: $defaultEncoder"
# --- END DEBUGGING ---

# --- Folder Selection ---
$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
$folderBrowser.Description = "Select the folder containing MOV files:"
$folderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer
if ($folderBrowser.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "Folder selection cancelled. Exiting script."
    return
}
$folderPath = $folderBrowser.SelectedPath
Write-Host "Selected folder: $folderPath"

# --- Options Form Creation ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Conversion Options"
$form.Size = New-Object System.Drawing.Size(300, 380)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false; $form.MinimizeBox = $false

# --- Encoder Selection GroupBox ---
$encoderGroupBox = New-Object System.Windows.Forms.GroupBox
$encoderGroupBox.Text = "Select Encoder (Available)"
$encoderGroupBox.Location = New-Object System.Drawing.Point(10, 10)
$encoderGroupBox.Size = New-Object System.Drawing.Size(260, 125)
$encoderRadioButtons = @(); $yPosEncoder = 20
# NVENC
$nvencRadioButton = New-Object System.Windows.Forms.RadioButton; $nvencRadioButton.Text = "NVENC (NVIDIA)"; $nvencRadioButton.Location = New-Object System.Drawing.Point(10, $yPosEncoder); $nvencRadioButton.AutoSize = $true; $nvencRadioButton.Enabled = $isNvencFunctional; $nvencRadioButton.Checked = ($defaultEncoder -eq "NVENC"); $encoderRadioButtons += $nvencRadioButton; $yPosEncoder += 25
# QSV
$qsvRadioButton = New-Object System.Windows.Forms.RadioButton; $qsvRadioButton.Text = "Quick Sync (Intel)"; $qsvRadioButton.Location = New-Object System.Drawing.Point(10, $yPosEncoder); $qsvRadioButton.AutoSize = $true; $qsvRadioButton.Enabled = $isQsvFunctional; $qsvRadioButton.Checked = ($defaultEncoder -eq "Quick Sync"); $encoderRadioButtons += $qsvRadioButton; $yPosEncoder += 25
# AMF
$amfRadioButton = New-Object System.Windows.Forms.RadioButton; $amfRadioButton.Text = "AMF (AMD)"; $amfRadioButton.Location = New-Object System.Drawing.Point(10, $yPosEncoder); $amfRadioButton.AutoSize = $true; $amfRadioButton.Enabled = $isAmfFunctional; $amfRadioButton.Checked = ($defaultEncoder -eq "AMF"); $encoderRadioButtons += $amfRadioButton; $yPosEncoder += 25
# CPU
$cpuRadioButton = New-Object System.Windows.Forms.RadioButton; $cpuRadioButton.Text = "CPU (libx264)"; $cpuRadioButton.Location = New-Object System.Drawing.Point(10, $yPosEncoder); $cpuRadioButton.AutoSize = $true; $cpuRadioButton.Enabled = $isCpuFunctional; $cpuRadioButton.Checked = ($defaultEncoder -eq "CPU"); $encoderRadioButtons += $cpuRadioButton
$encoderGroupBox.Controls.AddRange($encoderRadioButtons); $form.Controls.Add($encoderGroupBox)

# --- Quality Selection GroupBox ---
$qualityGroupBox = New-Object System.Windows.Forms.GroupBox
$qualityGroupBox.Text = "Select Quality"
$qualityGroupBoxY = [int]($encoderGroupBox.Bottom + 10)
$qualityGroupBox.Location = New-Object System.Drawing.Point(10, $qualityGroupBoxY)
$qualityGroupBox.Size = New-Object System.Drawing.Size(260, 125)
$qualityRadioButtons = @(); $yPosQuality = 20
# Low
$lowQualityRadioButton = New-Object System.Windows.Forms.RadioButton; $lowQualityRadioButton.Text = "Low (Smaller File, CRF 28)"; $lowQualityRadioButton.Location = New-Object System.Drawing.Point(10, $yPosQuality); $lowQualityRadioButton.AutoSize = $true; $qualityRadioButtons += $lowQualityRadioButton; $yPosQuality += 25
# Medium
$mediumQualityRadioButton = New-Object System.Windows.Forms.RadioButton; $mediumQualityRadioButton.Text = "Medium (Balanced, CRF 23)"; $mediumQualityRadioButton.Location = New-Object System.Drawing.Point(10, $yPosQuality); $mediumQualityRadioButton.AutoSize = $true; $qualityRadioButtons += $mediumQualityRadioButton; $yPosQuality += 25
# High
$highQualityRadioButton = New-Object System.Windows.Forms.RadioButton; $highQualityRadioButton.Text = "High (Better Quality, CRF 18)"; $highQualityRadioButton.Location = New-Object System.Drawing.Point(10, $yPosQuality); $highQualityRadioButton.AutoSize = $true; $qualityRadioButtons += $highQualityRadioButton; $yPosQuality += 25
# Original (Modified Behavior)
$originalQualityRadioButton = New-Object System.Windows.Forms.RadioButton; $originalQualityRadioButton.Text = "Original (VBR, ~CRF 18, Bitrate Cap)"; $originalQualityRadioButton.Location = New-Object System.Drawing.Point(10, $yPosQuality); $originalQualityRadioButton.AutoSize = $true; $originalQualityRadioButton.Checked = $true; $qualityRadioButtons += $originalQualityRadioButton
$qualityGroupBox.Controls.AddRange($qualityRadioButtons); $form.Controls.Add($qualityGroupBox)

# --- Include Subdirectories Checkbox ---
$includeSubdirectoriesCheckbox = New-Object System.Windows.Forms.CheckBox
$includeSubdirectoriesCheckbox.Text = "Include Subdirectories"
$includeSubdirectoriesCheckboxY = [int]($qualityGroupBox.Bottom + 10)
$includeSubdirectoriesCheckbox.Location = New-Object System.Drawing.Point(15, $includeSubdirectoriesCheckboxY)
$includeSubdirectoriesCheckbox.AutoSize = $true; $form.Controls.Add($includeSubdirectoriesCheckbox)

# --- OK Button ---
$okButton = New-Object System.Windows.Forms.Button; $okButton.Text = "Start Conversion"; $okButton.Size = New-Object System.Drawing.Size(120, 30)
$okButtonX = $form.ClientSize.Width - $okButton.Width - 10; $okButtonY = $form.ClientSize.Height - $okButton.Height - 10
$okButton.Location = New-Object System.Drawing.Point($okButtonX, $okButtonY); $okButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$form.AcceptButton = $okButton; $okButton.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() }); $form.Controls.Add($okButton)

# --- Cancel Button ---
$cancelButton = New-Object System.Windows.Forms.Button; $cancelButton.Text = "Cancel"; $cancelButton.Size = New-Object System.Drawing.Size(80, 30)
$cancelButtonX = $okButton.Left - $cancelButton.Width - 10; $cancelButtonY = $okButton.Top
$cancelButton.Location = New-Object System.Drawing.Point($cancelButtonX, $cancelButtonY); $cancelButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$form.CancelButton = $cancelButton; $cancelButton.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() }); $form.Controls.Add($cancelButton)


# --- Show the Form and Process Results ---
$formResult = $form.ShowDialog()

if ($formResult -eq [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "Options selected. Proceeding with conversion..."

    # Get selected encoder
    if ($nvencRadioButton.Checked) { $selectedEncoder = "NVENC" }
    elseif ($qsvRadioButton.Checked) { $selectedEncoder = "Quick Sync" }
    elseif ($amfRadioButton.Checked) { $selectedEncoder = "AMF" }
    else { $selectedEncoder = "CPU" }
    Write-Host "Selected Encoder: $selectedEncoder"

    # Get selected quality preset name
    if ($lowQualityRadioButton.Checked) { $selectedQualityPreset = "Low" }
    elseif ($mediumQualityRadioButton.Checked) { $selectedQualityPreset = "Medium" }
    elseif ($highQualityRadioButton.Checked) { $selectedQualityPreset = "High" }
    else { $selectedQualityPreset = "Original" } # Original Quality
    Write-Host "Selected Quality Preset: $selectedQualityPreset"

    $recurse = $includeSubdirectoriesCheckbox.Checked
    Write-Host "Include Subdirectories: $recurse"

} else {
    Write-Host "Operation cancelled by user in the options window. Exiting script."
    return
}

# --- File Search ---
Write-Host "`nSearching for .mov files..."
try {
    $files = Get-ChildItem -Path $folderPath -Filter "*.mov" -File -Recurse:$recurse -ErrorAction Stop
} catch { Write-Error "Error finding files: $($_.Exception.Message)"; return }
if ($files.Count -eq 0) { Write-Host "No .mov files found in the specified location."; return }
$totalFiles = $files.Count
Write-Host "Found $totalFiles .mov file(s) to convert."

# --- Set Base Encoder Arguments (Quality value might be overridden later) ---
$videoCodec = ""
$baseArgs = "" # Base arguments for the selected encoder and quality level
$crfValue = 23 # Default CRF/CQ (Medium)

switch ($selectedQualityPreset) {
    "Low" { $crfValue = 28 }
    "Medium" { $crfValue = 23 }
    "High" { $crfValue = 18 }
    "Original" { $crfValue = 18 } # Start with High quality base for Original
}

switch ($selectedEncoder) {
    "NVENC" {
        $videoCodec = "h264_nvenc"
        # Use CQ (Constant Quality) mode, -b:v 0 needed for CQ+maxrate
        $baseArgs = "-rc:v vbr -cq:v $crfValue -preset p5 -b:v 0"
        Write-Host "Base NVENC VBR settings (CQ: $crfValue)."
    }
    "Quick Sync" {
        $videoCodec = "h264_qsv"
        # Use global_quality (maps to ICQ)
        $baseArgs = "-global_quality $crfValue -preset medium -look_ahead 1"
         Write-Host "Base Quick Sync ICQ settings (Quality: $crfValue)."
    }
    "AMF" {
        $videoCodec = "h264_amf"
        # Use CQ mode with quality preset
        $baseArgs = "-rc vbr_latency -cq $crfValue -quality quality"
        Write-Host "Base AMF VBR settings (CQ: $crfValue)."
    }
    default { # CPU (libx264)
        $videoCodec = "libx264"
        # Use CRF
        $baseArgs = "-preset medium -crf $crfValue"
        Write-Host "Base libx264 CRF settings (CRF: $crfValue)."
    }
}

# --- Conversion Loop ---
$completedFiles = 0
$conversionErrors = @()

Write-Host "`nStarting conversion process..." -ForegroundColor Green

foreach ($file in $files) {
    $completedFiles++
    $baseName = $file.BaseName
    $directoryName = $file.DirectoryName
    $outputPath = Join-Path -Path $directoryName -ChildPath ($baseName + ".mp4")

    Write-Host "`n($completedFiles/$totalFiles) Converting '$($file.Name)'..."

    if (Test-Path $outputPath) {
        Write-Warning "Output file '$outputPath' already exists and will be overwritten."
    }

    # --- Get Duration and Source Bitrate ---
    $durationSeconds = 0
    $sourceBitrate = 0 # In bps
    $maxRateArgs = ""  # Arguments for maxrate/bufsize

    try {
        # Use ffprobe to get duration and video stream bitrate
        # Note: Using -of default=... instead of ConvertFrom-StringData for wider PowerShell version compatibility
        $durationOutput = ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 "$($file.FullName)"
        $bitrateOutput = ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$($file.FullName)"

        if ($durationOutput -match '(\d+(\.\d+)?)') {
             $durationSeconds = [double]::Parse($matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
        } else { Write-Warning "Could not determine duration for $($file.Name)." }

        if ($bitrateOutput -and $bitrateOutput -ne 'N/A' -and $bitrateOutput -match '^\d+$') {
            $sourceBitrate = [int64]$bitrateOutput
            # **FIX: Use 1000 for kbps calculation**
            Write-Host "Source video bitrate: $([Math]::Round($sourceBitrate / 1000)) kbps"
        } else { Write-Warning "Could not determine source bitrate for $($file.Name)." }

    } catch { Write-Warning "Error running ffprobe for $($file.Name): $($_.Exception.Message)." }

    # --- Add Max Bitrate Cap if "Original" Quality is Selected ---
    $currentEncoderArgs = $baseArgs # Start with base args for the quality level
    if ($selectedQualityPreset -eq "Original" -and $sourceBitrate -gt 0) {
        Write-Host "Applying bitrate cap based on source average bitrate."
        $maxRateValue = $sourceBitrate # Use bps
        $bufferSize = $maxRateValue * 2 # Common rule: bufsize = 2 * maxrate

        # Format maxrate based on encoder specifics
        switch ($selectedEncoder) {
            "AMF" {
                # AMF often expects kbps for maxrate
                $maxRateFormatted = "$([int]($maxRateValue / 1000))k"
                $bufferSizeFormatted = "$([int]($bufferSize / 1000))k" # Assuming bufsize also in kbps if maxrate is
            }
            default {
                # Others generally accept bps
                $maxRateFormatted = "$maxRateValue"
                $bufferSizeFormatted = "$bufferSize"
            }
        }
        $maxRateArgs = "-maxrate:v $maxRateFormatted -bufsize:v $bufferSizeFormatted"
        $currentEncoderArgs += " $maxRateArgs" # Append maxrate/bufsize args
    } elseif ($selectedQualityPreset -eq "Original" -and $sourceBitrate -eq 0) {
         Write-Warning "Cannot apply bitrate cap for '$($file.Name)' as source bitrate was not found. Using standard High quality settings."
    }

    # Construct final ffmpeg arguments
    $arguments = "-hide_banner -y -i `"$($file.FullName)`" -c:v $videoCodec $currentEncoderArgs -c:a aac -b:a 192k -progress pipe:1 -nostats `"$($outputPath)`""
    # Write-Host "[DEBUG] FFmpeg arguments: $arguments" # Uncomment for debugging

    # --- Execute FFmpeg Process ---
    $psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName = "ffmpeg"; $psi.Arguments = $arguments
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process; $proc.StartInfo = $psi
    $errorOutput = ""; $errorEvent = $null

    try {
        $errorAction = { param($sender, $e) if (-not [string]::IsNullOrEmpty($e.Data)) { $script:errorOutput += $e.Data + "`n" } }
        $errorEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action $errorAction
        $proc.Start() | Out-Null
        $proc.BeginErrorReadLine()

        # --- Progress Parsing ---
        while (!$proc.HasExited) {
            while ($proc.StandardOutput.Peek() -ge 0) {
                $line = $proc.StandardOutput.ReadLine()
                if ($line -match "^out_time_ms=(\d+)") {
                    $outTimeMicroseconds = [int64]$matches[1]
                    if ($durationSeconds -gt 0) {
                        $currentTimeSeconds = $outTimeMicroseconds / 1000000.0
                        $progressPercent = ($currentTimeSeconds / $durationSeconds) * 100
                        if ($progressPercent -gt 100) { $progressPercent = 100 }
                        if ($progressPercent -lt 0) { $progressPercent = 0 }
                        # **FIX: Use 1000 for kbps calculation in progress**
                        $statusBitrate = if ($sourceBitrate -gt 0) { " (~$([Math]::Round($sourceBitrate/1000)) kbps src)" } else { "" }
                        Write-Progress -Activity "Converting: $($file.Name)" -Status ("{0:N1} / {1:N1} sec{2}" -f $currentTimeSeconds, $durationSeconds, $statusBitrate) -PercentComplete ([int]$progressPercent) -Id 1
                    }
                }
            }
            $overallProgress = ($completedFiles -1) / $totalFiles * 100
            Write-Progress -Activity "Overall Progress" -Status "$($completedFiles-1) of $totalFiles files converted" -PercentComplete $overallProgress -Id 0
            Start-Sleep -Milliseconds 200
        }
        $proc.WaitForExit(1500)

        if ($proc.ExitCode -ne 0) {
            Write-Error "ffmpeg process exited with error code $($proc.ExitCode) for file '$($file.Name)'."
            Start-Sleep -Milliseconds 200
            Write-Error "Error output: $script:errorOutput"
            $conversionErrors += $file.Name
        } else {
            Write-Host "Successfully converted '$($file.Name)' to '$outputPath'." -ForegroundColor Green
        }
    } catch {
        Write-Error "An error occurred during the conversion of '$($file.Name)': $($_.Exception.Message)"
        Write-Error "FFmpeg stderr: $script:errorOutput"
        $conversionErrors += $file.Name
    } finally {
        if ($errorEvent) { Unregister-Event -SourceIdentifier $errorEvent.Name -ErrorAction SilentlyContinue }
        if ($proc -ne $null -and !$proc.HasExited) { try { $proc.Kill() } catch { Write-Warning "Failed to kill conversion process for $($file.Name)." } }
        if ($proc -ne $null) { $proc.Dispose() }
        Write-Progress -Activity "Converting: $($file.Name)" -Completed -Id 1
    }
}

# --- Final Summary ---
Write-Progress -Activity "Overall Progress" -Completed -Id 0
Write-Host "`n----- Conversion Summary -----" -ForegroundColor Yellow
$successfulConversions = $totalFiles - $conversionErrors.Count
Write-Host "Total files found: $totalFiles"
Write-Host "Successfully converted: $successfulConversions" -ForegroundColor Green
if ($conversionErrors.Count -gt 0) {
    Write-Host "Files with errors: $($conversionErrors.Count)" -ForegroundColor Red
    Write-Host "Files that failed:"
    $conversionErrors | ForEach-Object { Write-Host "- $_" -ForegroundColor Red }
} else { Write-Host "All files converted successfully!" -ForegroundColor Green }
Write-Host "-----------------------------" -ForegroundColor Yellow
if ($Host.Name -eq "ConsoleHost" -and ($MyInvocation.Line -like "*""*" -or $MyInvocation.Line -like "*'.\*'")) { Write-Host "`nPress Enter to exit..."; Read-Host }
