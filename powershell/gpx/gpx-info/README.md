# GPX Parser PowerShell Script (`gpx-info.ps1`)

## Overview

This PowerShell script parses a GPX (GPS Exchange Format) file to extract key information, including the number of waypoints and track points, as well as the timestamps of the first and last recorded points (either waypoint or track point). It also generates a sample PostgreSQL query based on these timestamps.

## Features

* Counts the total number of waypoints (`<wpt>`) in the GPX file.
* Counts the total number of track points (`<trkpt>`) within all tracks and segments.
* Identifies the earliest timestamp found in any `<time>` tag within waypoints or track points.
* Identifies the latest timestamp found in any `<time>` tag within waypoints or track points.
* Outputs the counts and timestamps (formatted date/time and Unix epoch format).
* Provides a sample PostgreSQL query to select data between the first and last timestamps.
* Includes basic error handling for file not found and XML parsing issues.
* Uses XML namespaces for more reliable parsing of standard GPX files.

## Prerequisites

* **PowerShell:** Version 3.0 or later (due to the use of the `[xml]` type accelerator and the `-Raw` parameter for `Get-Content`). You can check your PowerShell version by running `$PSVersionTable.PSVersion`.

## How to Use

1.  **Save the Script:** Save the script code to a file, for example, `gpx-info.ps1`.
2.  **Run from PowerShell:** Open a PowerShell console and navigate to the directory where you saved the script.

### Syntax

```powershell
.\gpx-info.ps1 [-gpxFilePath] <String>