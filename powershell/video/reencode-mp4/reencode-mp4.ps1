<# .SYNOPSIS
Re-encodes MP4 files to MP4 files with options for quality presets or specific bitrates, subfolder processing, progress display, GPU acceleration selection (VBR/CBR), and optional overwriting of original files. Checks for functional encoders (NVENC/QSV) or hardware+listing (AMF).

.DESCRIPTION
This script allows you to select a folder, search it (and optionally subfolders) for MP4 files, and re-encode them into new MP4 files using ffmpeg.
Before showing options, it tests if NVENC and Quick Sync encoders are functional. For AMF, it checks if an AMD GPU is detected AND if AMF is listed by ffmpeg.
It provides a GUI to select an available encoder, encoding mode (Quality Preset or Specific Bitrate), quality level (Low, Medium, High) or a target bitrate from a list, whether to include subdirectories, and whether to overwrite the original files.
If overwriting is not selected (default), output files will have "_reencoded" appended to their names.
The progress of each conversion and the overall progress will be displayed in the console.

.EXAMPLE
.\reencode-mp4.ps1
# This will launch the folder browser, test/check encoders, and then show the options GUI.

.NOTES
Make sure that ffmpeg and ffprobe are installed and available in the system's PATH.
The script requires .NET Framework for the Windows Forms GUI and WMI/CIM access for the AMF hardware check.
GPU encoding options (NVENC, QSV, AMF) require compatible hardware AND correctly installed/updated drivers.
The script attempts functional tests for NVENC/QSV. For AMF, it checks for compatible hardware via WMI/CIM and if ffmpeg lists the encoder. Ensure drivers are updated if selecting AMF.
Overwriting original files is irreversible. Use with caution.
#>

# Load necessary assembly for Windows Forms
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing # Required for Point, Size, etc.
# System.Collections is usually loaded by default, but explicitly adding doesn't hurt
Add-Type -AssemblyName System.Collections

# --- Function to Test FFmpeg Encoder Functionality (Used for NVENC, QSV) ---
function Test-FfmpegEncoder {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EncoderName
    )

    Write-Host "Testing encoder: $EncoderName..."
    # Use testsrc which generates a standard pattern
    # Use a slightly longer duration and more frames for potentially slower initialization
    $testArguments = "-v quiet -f lavfi -i testsrc=size=64x64:rate=10:duration=0.5 -pix_fmt yuv420p -frames:v 5 -c:v $EncoderName -f null NUL"

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
        # Increased timeout to 10 seconds
        if ($process.WaitForExit(10000)) {
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
            Write-Warning "Encoder '$EncoderName' test timed out after 10 seconds. Assuming unavailable."
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
    # Prefer CIM if available (newer PowerShell versions)
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $videoControllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
    } else {
        $videoControllers = Get-WmiObject -Class Win32_VideoController -ErrorAction Stop
    }

    if ($videoControllers | Where-Object { $_.Name -like '*AMD*' -or $_.Name -like '*Radeon*' }) {
        $amdGpuDetected = $true
        Write-Host "AMD GPU detected." -ForegroundColor Green
    } else {
        Write-Host "No AMD GPU detected."
    }
} catch {
    Write-Warning "Could not query video controllers via WMI/CIM: $($_.Exception.Message)"
}

Write-Host "Checking for AMF encoder listing (using -match)..."
# Use regex for potentially varied output, case-insensitive
$amfListed = $ffmpegEncodersOutput -match '(?im)^\s*V.....\s+h264_amf'
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

# --- Folder Selection ---
$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
$folderBrowser.Description = "Select the folder containing MP4 files to re-encode:"
$folderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer
if ($folderBrowser.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "Folder selection cancelled. Exiting script."
    return
}
$folderPath = $folderBrowser.SelectedPath
Write-Host "Selected folder: $folderPath"

# --- Options Form Creation ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Re-encoding Options"
$form.Size = New-Object System.Drawing.Size(320, 520) # Increased height for new checkbox
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false; $form.MinimizeBox = $false

# --- Encoder Selection GroupBox ---
$encoderGroupBox = New-Object System.Windows.Forms.GroupBox
$encoderGroupBox.Text = "Select Encoder (Available)"
$encoderGroupBox.Location = New-Object System.Drawing.Point(10, 10)
$encoderGroupBox.Size = New-Object System.Drawing.Size(280, 125) # Slightly wider
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

# --- Encoding Settings GroupBox ---
$settingsGroupBox = New-Object System.Windows.Forms.GroupBox
$settingsGroupBox.Text = "Encoding Settings"
$settingsGroupBoxY = [int]($encoderGroupBox.Bottom + 10)
$settingsGroupBox.Location = New-Object System.Drawing.Point(10, $settingsGroupBoxY)
$settingsGroupBox.Size = New-Object System.Drawing.Size(280, 190) # Increased height
$settingsRadioButtons = @(); $yPosSettings = 20

# Quality Presets
$lowQualityRadioButton = New-Object System.Windows.Forms.RadioButton; $lowQualityRadioButton.Text = "Quality: Low (Smaller File, CRF~28)"; $lowQualityRadioButton.Location = New-Object System.Drawing.Point(10, $yPosSettings); $lowQualityRadioButton.AutoSize = $true; $settingsRadioButtons += $lowQualityRadioButton; $yPosSettings += 25
$mediumQualityRadioButton = New-Object System.Windows.Forms.RadioButton; $mediumQualityRadioButton.Text = "Quality: Medium (Balanced, CRF~23)"; $mediumQualityRadioButton.Location = New-Object System.Drawing.Point(10, $yPosSettings); $mediumQualityRadioButton.AutoSize = $true; $mediumQualityRadioButton.Checked = $true; $settingsRadioButtons += $mediumQualityRadioButton; $yPosSettings += 25 # Default selection
$highQualityRadioButton = New-Object System.Windows.Forms.RadioButton; $highQualityRadioButton.Text = "Quality: High (Better Quality, CRF~18)"; $highQualityRadioButton.Location = New-Object System.Drawing.Point(10, $yPosSettings); $highQualityRadioButton.AutoSize = $true; $settingsRadioButtons += $highQualityRadioButton; $yPosSettings += 25

# Specific Bitrate Option
$bitrateRadioButton = New-Object System.Windows.Forms.RadioButton; $bitrateRadioButton.Text = "Specific Bitrate:"; $bitrateRadioButton.Location = New-Object System.Drawing.Point(10, $yPosSettings); $bitrateRadioButton.AutoSize = $true; $settingsRadioButtons += $bitrateRadioButton; $yPosSettings += 30 # Add extra space before ComboBox

# Bitrate ComboBox (Dropdown List)
$bitrateComboBox = New-Object System.Windows.Forms.ComboBox
$bitrateComboBox.Location = New-Object System.Drawing.Point(30, $yPosSettings) # Indent slightly
$bitrateComboBox.Size = New-Object System.Drawing.Size(230, 25) # Slightly wider for longer text
$bitrateComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList # Prevent free text entry
$bitrateComboBox.Enabled = $false # Disabled by default

# Define bitrate options (Hashtables with Display and Value)
$bitrateOptions = @(
    @{ Display = "1000 kbps (Low SD)"; Value = 1000 }
    @{ Display = "2500 kbps (Good SD / Low 720p)"; Value = 2500 }
    @{ Display = "5000 kbps (Good 720p / Low 1080p)"; Value = 5000 }
    @{ Display = "8000 kbps (Good 1080p)"; Value = 8000 }
    @{ Display = "12000 kbps (High 1080p)"; Value = 12000 }
    @{ Display = "20000 kbps (Very High 1080p / Low 4K)"; Value = 20000 }
)

# Populate ComboBox with display text ONLY
foreach ($option in $bitrateOptions) {
    $bitrateComboBox.Items.Add($option.Display)
}
# Set default selection based on index (corresponds to 5000 kbps option)
$bitrateComboBox.SelectedIndex = 2

# Event Handler to enable/disable ComboBox based on RadioButton selection
$bitrateRadioButton.Add_CheckedChanged({
    param($sender, $e)
    $bitrateComboBox.Enabled = $sender.Checked
})
# Also ensure other radio buttons disable the combobox
$lowQualityRadioButton.Add_CheckedChanged({param($sender, $e) if ($sender.Checked) {$bitrateComboBox.Enabled = $false}})
$mediumQualityRadioButton.Add_CheckedChanged({param($sender, $e) if ($sender.Checked) {$bitrateComboBox.Enabled = $false}})
$highQualityRadioButton.Add_CheckedChanged({param($sender, $e) if ($sender.Checked) {$bitrateComboBox.Enabled = $false}})

# Add controls to GroupBox
$settingsGroupBox.Controls.AddRange($settingsRadioButtons)
$settingsGroupBox.Controls.Add($bitrateComboBox)
$form.Controls.Add($settingsGroupBox)

# --- Other Options ---
$otherOptionsY = [int]($settingsGroupBox.Bottom + 10)

# Include Subdirectories Checkbox
$includeSubdirectoriesCheckbox = New-Object System.Windows.Forms.CheckBox
$includeSubdirectoriesCheckbox.Text = "Include Subdirectories"
$includeSubdirectoriesCheckbox.Location = New-Object System.Drawing.Point(15, $otherOptionsY)
$includeSubdirectoriesCheckbox.AutoSize = $true
$form.Controls.Add($includeSubdirectoriesCheckbox)

# *** ADDED: Overwrite Original Files Checkbox ***
$overwriteCheckbox = New-Object System.Windows.Forms.CheckBox
$overwriteCheckbox.Text = "Overwrite Original Files (Use Caution!)"
$overwriteCheckboxY = [int]($includeSubdirectoriesCheckbox.Bottom + 5) # Position below previous checkbox
$overwriteCheckbox.Location = New-Object System.Drawing.Point(15, $overwriteCheckboxY)
$overwriteCheckbox.AutoSize = $true
$overwriteCheckbox.Checked = $false # Default to NOT overwriting
$form.Controls.Add($overwriteCheckbox)


# --- OK Button ---
$okButton = New-Object System.Windows.Forms.Button; $okButton.Text = "Start Re-encoding"; $okButton.Size = New-Object System.Drawing.Size(130, 30) # Wider text
$okButtonX = $form.ClientSize.Width - $okButton.Width - 10; $okButtonY = $form.ClientSize.Height - $okButton.Height - 10
$okButton.Location = New-Object System.Drawing.Point($okButtonX, $okButtonY); $okButton.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.AcceptButton = $okButton; $okButton.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() }); $form.Controls.Add($okButton)

# --- Cancel Button ---
$cancelButton = New-Object System.Windows.Forms.Button; $cancelButton.Text = "Cancel"; $cancelButton.Size = New-Object System.Drawing.Size(80, 30)
$cancelButtonX = $okButton.Left - $cancelButton.Width - 10; $cancelButtonY = $okButton.Top
$cancelButton.Location = New-Object System.Drawing.Point($cancelButtonX, $cancelButtonY); $cancelButton.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.CancelButton = $cancelButton; $cancelButton.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() }); $form.Controls.Add($cancelButton)


# --- Show the Form and Process Results ---
# Make sure form is disposed after use
try {
    $formResult = $form.ShowDialog()

    if ($formResult -eq [System.Windows.Forms.DialogResult]::OK) {
        Write-Host "Options selected. Proceeding with re-encoding..."

        # Get selected encoder
        if ($nvencRadioButton.Checked) { $selectedEncoder = "NVENC" }
        elseif ($qsvRadioButton.Checked) { $selectedEncoder = "Quick Sync" }
        elseif ($amfRadioButton.Checked) { $selectedEncoder = "AMF" }
        else { $selectedEncoder = "CPU" }
        Write-Host "Selected Encoder: $selectedEncoder"

        # Get selected encoding mode and value
        $selectedEncodingMode = "Quality" # Default
        $selectedQualityPreset = "Medium" # Default
        $selectedBitrateKbps = 0 # Default

        if ($lowQualityRadioButton.Checked) { $selectedQualityPreset = "Low"; $selectedEncodingMode = "Quality" }
        elseif ($mediumQualityRadioButton.Checked) { $selectedQualityPreset = "Medium"; $selectedEncodingMode = "Quality" }
        elseif ($highQualityRadioButton.Checked) { $selectedQualityPreset = "High"; $selectedEncodingMode = "Quality" }
        elseif ($bitrateRadioButton.Checked) {
            $selectedEncodingMode = "Bitrate"
            # Retrieve value based on selected display text
            if ($bitrateComboBox.SelectedItem -ne $null) {
                $selectedDisplayText = $bitrateComboBox.SelectedItem.ToString()
                $selectedOption = $bitrateOptions | Where-Object { $_.Display -eq $selectedDisplayText } | Select-Object -First 1
                if ($selectedOption) {
                    $selectedBitrateKbps = $selectedOption.Value
                } else {
                    Write-Warning "Selected bitrate text '$selectedDisplayText' not found in options, defaulting to 5000 kbps."
                    $selectedBitrateKbps = 5000
                }
            } else {
                Write-Warning "No bitrate selected, attempting to use default (5000 kbps)."
                $defaultOption = $bitrateOptions[$bitrateComboBox.SelectedIndex]
                if ($defaultOption) { $selectedBitrateKbps = $defaultOption.Value }
                else { $selectedBitrateKbps = 5000 } # Absolute fallback
            }
            Write-Host "Selected Encoding Mode: Specific Bitrate ($selectedBitrateKbps kbps)"
        }

        if ($selectedEncodingMode -eq "Quality") {
            Write-Host "Selected Encoding Mode: Quality Preset ($selectedQualityPreset)"
        }

        $recurse = $includeSubdirectoriesCheckbox.Checked
        Write-Host "Include Subdirectories: $recurse"

        # *** ADDED: Get Overwrite Option ***
        $overwriteOriginals = $overwriteCheckbox.Checked
        if ($overwriteOriginals) {
            Write-Host "Overwrite Original Files: Enabled" -ForegroundColor Yellow
        } else {
            Write-Host "Overwrite Original Files: Disabled (creating new files with _reencoded suffix)"
        }


    } else {
        Write-Host "Operation cancelled by user in the options window. Exiting script."
        return
    }
} finally {
    # Ensure the form resources are released
    if ($form -ne $null) { $form.Dispose() }
}


# --- File Search ---
Write-Host "`nSearching for .mp4 files..."
try {
    # Change filter to .mp4
    $files = Get-ChildItem -Path $folderPath -Filter "*.mp4" -File -Recurse:$recurse -ErrorAction Stop
} catch { Write-Error "Error finding files: $($_.Exception.Message)"; return }

# *** REMOVED: Exclusion of _reencoded files is no longer needed ***
# $files = $files | Where-Object { $_.Name -notlike '*_reencoded.mp4' }

if ($files.Count -eq 0) { Write-Host "No .mp4 files found in the specified location."; return }
$totalFiles = $files.Count
Write-Host "Found $totalFiles .mp4 file(s) to process."

# --- Set Base Encoder Arguments based on Mode ---
$videoCodec = ""
$baseArgs = ""
$crfValue = 23 # Default CRF/CQ if Quality mode selected

if ($selectedEncodingMode -eq "Quality") {
    # Quality Mode (CRF/CQ)
    switch ($selectedQualityPreset) {
        "Low" { $crfValue = 28 }
        "Medium" { $crfValue = 23 }
        "High" { $crfValue = 18 }
    }

    switch ($selectedEncoder) {
        "NVENC" {
            $videoCodec = "h264_nvenc"
            $baseArgs = "-rc:v vbr -cq:v $crfValue -preset p5"
            Write-Host "Using NVENC VBR settings (CQ: $crfValue)."
        }
        "Quick Sync" {
            $videoCodec = "h264_qsv"
            $baseArgs = "-global_quality $crfValue -preset medium -look_ahead 1"
             Write-Host "Using Quick Sync ICQ settings (Quality: $crfValue)."
        }
        "AMF" {
            $videoCodec = "h264_amf"
            $baseArgs = "-rc vbr_latency -cq $crfValue -quality quality"
            Write-Host "Using AMF VBR settings (CQ: $crfValue)."
        }
        default { # CPU (libx264)
            $videoCodec = "libx264"
            $baseArgs = "-preset medium -crf $crfValue"
            Write-Host "Using libx264 CRF settings (CRF: $crfValue)."
        }
    }
} else {
    # Bitrate Mode
    $targetBitrate = "${selectedBitrateKbps}k"
    $bufferSize = "$(2 * $selectedBitrateKbps)k"

    switch ($selectedEncoder) {
        "NVENC" {
            $videoCodec = "h264_nvenc"
            $baseArgs = "-rc:v vbr -b:v $targetBitrate -maxrate:v $targetBitrate -bufsize:v $bufferSize -preset p5"
            Write-Host "Using NVENC VBR settings (Target: $targetBitrate)."
        }
        "Quick Sync" {
            $videoCodec = "h264_qsv"
            $baseArgs = "-b:v $targetBitrate -maxrate:v $targetBitrate -bufsize:v $bufferSize -preset medium -look_ahead 1"
             Write-Host "Using Quick Sync settings (Target: $targetBitrate)."
        }
        "AMF" {
            $videoCodec = "h264_amf"
            $baseArgs = "-rc cbr -b:v $targetBitrate -maxrate:v $targetBitrate -bufsize:v $bufferSize -quality quality"
            Write-Host "Using AMF CBR settings (Target: $targetBitrate)."
        }
        default { # CPU (libx264) - 1 Pass CBR
            $videoCodec = "libx264"
            $baseArgs = "-b:v $targetBitrate -maxrate $targetBitrate -bufsize $bufferSize -preset medium"
            Write-Host "Using libx264 1-Pass CBR settings (Target: $targetBitrate)."
        }
    }
}


# --- Conversion Loop ---
$completedFiles = 0
$conversionErrors = @()

Write-Host "`nStarting re-encoding process..." -ForegroundColor Green

foreach ($file in $files) {
    $completedFiles++
    $baseName = $file.BaseName
    $directoryName = $file.DirectoryName

    # *** UPDATED: Determine Output Path based on Overwrite Option ***
    $outputPath = ""
    if ($overwriteOriginals) {
        $outputPath = $file.FullName
        Write-Host "`n($completedFiles/$totalFiles) Processing '$($file.Name)' (Overwriting Original)..." -ForegroundColor Yellow
    } else {
        # Append _reencoded before the extension
        $outputBaseName = $baseName + "_reencoded"
        $outputPath = Join-Path -Path $directoryName -ChildPath ($outputBaseName + ".mp4")
        Write-Host "`n($completedFiles/$totalFiles) Processing '$($file.Name)' -> '$($outputBaseName).mp4'..."
    }

    # Warning if the specific target output path already exists
    if (Test-Path $outputPath) {
        Write-Warning "Output file '$outputPath' already exists and will be overwritten by ffmpeg (-y flag is active)."
    }

    # --- Get Duration ---
    $durationSeconds = 0
    try {
        $durationOutput = ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 "$($file.FullName)"
        if ($durationOutput -match '(\d+(\.\d+)?)') {
            $durationSeconds = [double]::Parse($matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
        } else { Write-Warning "Could not determine duration for $($file.Name)." }
    } catch { Write-Warning "Error running ffprobe for duration on $($file.Name): $($_.Exception.Message)." }


    # Construct final ffmpeg arguments
    # -y automatically confirms overwriting the $outputPath if it exists
    $arguments = "-hide_banner -y -i `"$($file.FullName)`" -map 0 -c:v $videoCodec $baseArgs -c:a copy -c:s copy -progress pipe:1 -nostats `"$($outputPath)`""
    # Write-Host "[DEBUG] FFmpeg arguments: $arguments" # Uncomment for debugging

    # --- Execute FFmpeg Process ---
    $psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName = "ffmpeg"; $psi.Arguments = $arguments
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process; $proc.StartInfo = $psi
    $script:errorOutput = ""; # Use script scope for error variable in event handler
    $errorEvent = $null

    try {
        $errorAction = { param($sender, $e) if (-not [string]::IsNullOrEmpty($e.Data)) { $script:errorOutput += $e.Data + "`n" } }
        $eventIdentifier = "ffmpegError_$($PID)_$($completedFiles)"
        $errorEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action $errorAction -SourceIdentifier $eventIdentifier

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
                        $progressPercent = [Math]::Min(100, [Math]::Max(0, ($currentTimeSeconds / $durationSeconds) * 100))
                        $statusText = "{0:N1} / {1:N1} sec" -f $currentTimeSeconds, $durationSeconds
                        $activityText = if ($overwriteOriginals) { "Overwriting: $($file.Name)" } else { "Re-encoding: $($file.Name)" }
                        Write-Progress -Activity $activityText -Status $statusText -PercentComplete ([int]$progressPercent) -Id 1
                    }
                }
            }
            $overallProgress = ($completedFiles -1) / $totalFiles * 100
            Write-Progress -Activity "Overall Progress" -Status "$($completedFiles-1) of $totalFiles files processed" -PercentComplete $overallProgress -Id 0
            Start-Sleep -Milliseconds 250
        }
        $proc.WaitForExit(2000)

    } catch {
        Write-Error "An error occurred launching or monitoring ffmpeg for '$($file.Name)': $($_.Exception.Message)"
        $conversionErrors += $file.Name
        if ($proc -ne $null -and !$proc.HasExited) { try { $proc.Kill() } catch { Write-Warning "Failed to kill process after exception for $($file.Name)." } }
    } finally {
        # --- Final Check and Cleanup ---
        if ($proc -ne $null) {
             Start-Sleep -Milliseconds 100
            if ($proc.ExitCode -ne 0) {
                if ($conversionErrors -notcontains $file.Name) {
                    Write-Error "ffmpeg process exited with error code $($proc.ExitCode) for file '$($file.Name)'."
                    if (![string]::IsNullOrWhiteSpace($script:errorOutput)) { Write-Error "Error output: $($script:errorOutput)" }
                    else { Write-Warning "No specific error output captured via stderr stream, check ffmpeg logs if enabled elsewhere." }
                    $conversionErrors += $file.Name
                }
            } elseif ($conversionErrors -notcontains $file.Name) {
                 $successMessage = if ($overwriteOriginals) { "Successfully overwrote '$($file.Name)'." } else { "Successfully re-encoded '$($file.Name)' to '$outputPath'." }
                 Write-Host $successMessage -ForegroundColor Green
            }
        }

        if ($errorEvent) { Unregister-Event -SourceIdentifier $eventIdentifier -ErrorAction SilentlyContinue }
        if ($proc -ne $null) { $proc.Dispose() }
        $activityText = if ($overwriteOriginals) { "Overwriting: $($file.Name)" } else { "Re-encoding: $($file.Name)" }
        Write-Progress -Activity $activityText -Completed -Id 1
    }
}

# --- Final Summary ---
Write-Progress -Activity "Overall Progress" -Completed -Id 0
Write-Host "`n----- Re-encoding Summary -----" -ForegroundColor Yellow
$successfulConversions = $totalFiles - $conversionErrors.Count
$summaryAction = if ($overwriteOriginals) { "processed (overwritten)" } else { "re-encoded" }
Write-Host "Total files found: $totalFiles"
Write-Host "Successfully $summaryAction: $successfulConversions" -ForegroundColor Green
if ($conversionErrors.Count -gt 0) {
    Write-Host "Files with errors: $($conversionErrors.Count)" -ForegroundColor Red
    Write-Host "Files that failed:"
    $conversionErrors | ForEach-Object { Write-Host "- $_" -ForegroundColor Red }
} else { Write-Host "All files processed successfully!" -ForegroundColor Green }
Write-Host "-----------------------------" -ForegroundColor Yellow

# Pause if script was run directly by double-clicking or drag-and-drop
if ($Host.Name -eq "ConsoleHost" -and ($MyInvocation.Line -like "*""*" -or $MyInvocation.Line -like "*'.\*'")) { Write-Host "`nPress Enter to exit..."; $null = Read-Host }