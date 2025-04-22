# GPX Cleaner and Analyzer (`gpx-clean.ps1`)

## Overview

This PowerShell script provides a graphical user interface (GUI) for cleaning and analyzing GPX (GPS Exchange Format) files. It allows users to filter out unwanted waypoints (`wpt`) or trackpoints (`trkpt`) based on the prefix of their latitude (`lat`) or longitude (`lon`) coordinates. The script performs analysis both before and after cleaning, providing statistics like point counts and time ranges, and generates example PostgreSQL queries based on the analysis.

## Features

* **GUI Driven:** Uses Windows Forms for user interaction (file selection, filter criteria, results display, confirmations).
* **GPX File Selection:** Standard Windows dialog to select the `.gpx` file to process.
* **Coordinate Filtering:**
    * Choose to filter by Latitude (`lat`) or Longitude (`lon`).
    * Specify a prefix value (e.g., `52.`). Points whose chosen coordinate attribute starts with this prefix will be removed.
    * Option to skip filtering by leaving the prefix value empty.
* **In-Memory Cleaning:** Loads the GPX file into memory and removes matching points without modifying the original file initially.
* **Timestamp Analysis:**
    * Determines the first and last timestamps found in the *original* GPX file.
    * Determines the first and last timestamps found in the *potentially cleaned* GPX data.
    * Displays timestamps in both human-readable format (`yyyy-MM-dd HH:mm:ss`) and UTC Unix epoch seconds.
* **Point Statistics:** Counts the remaining waypoints (`wpt`) and trackpoints (`trkpt`) after the cleaning step.
* **SQL Query Generation (PostgreSQL):**
    * Generates an example `SELECT` query to retrieve data from a hypothetical database table within the timestamp range of the *cleaned* GPX data.
    * Generates an example `DELETE` query to remove data from a hypothetical database table that matches the *original* timestamp range *and* the specified coordinate filter criteria. Includes important warnings and notes about placeholders and potential type casting (`::text`).
* **Results Display:** Presents all analysis results, filter settings, and generated SQL queries in a dedicated, read-only GUI window with selectable text.
* **Optional File Overwrite:** If points were removed during the cleaning process, the script prompts the user to confirm whether they want to save the changes and overwrite the original GPX file.

## Dependencies

* **Operating System:** Windows (due to PowerShell and .NET Framework GUI elements).
* **PowerShell:** Version supporting .NET Framework integration (most modern Windows versions include a compatible version).
* **.NET Framework:** Required for the `System.Windows.Forms` and `System.Drawing` assemblies used to create the GUI. The script attempts to load these and will show an error if they are unavailable.

## How to Use

1.  **Save the Script:** Save the code as a `.ps1` file (e.g., `gpx-clean.ps1`).
2.  **Run the Script:**
    * Open PowerShell.
    * Navigate to the directory where you saved the script using the `cd` command.
    * Execute the script by typing `.\gpx-clean.ps1` and pressing Enter.
    * Alternatively, you might be able to right-click the `.ps1` file in Windows Explorer and select "Run with PowerShell" (Execution Policy permitting).
3.  **Select GPX File:** A file dialog window will appear. Browse to and select the GPX file you want to process and click "Open".
4.  **Enter Filter Settings:**
    * A "Filter Settings" window will appear.
    * Choose whether to filter by `Latitude (lat)` or `Longitude (lon)` using the radio buttons.
    * In the text box, enter the *starting prefix* of the coordinate values you want to remove (e.g., `52.` to remove points where latitude starts with "52.").
    * **Important:** Leave the text box *empty* if you do *not* want to remove any points and only want to perform the analysis and generate SQL.
    * Click "OK" to proceed or "Cancel" to exit the script.
5.  **Processing:** The script will perform the following steps (progress messages may appear in the PowerShell console):
    * Load the GPX file.
    * Analyze the original timestamps.
    * If a filter value was provided, search for and remove matching points *in memory*.
    * Analyze the potentially cleaned data (timestamps, point counts).
    * Generate example SQL queries.
6.  **View Results:** A "GPX Processing Results" window will appear, displaying:
    * The processed file path and filter settings used.
    * Original and cleaned timestamp ranges (if found).
    * Number of points removed (if any).
    * Remaining waypoint and trackpoint counts.
    * Example PostgreSQL `SELECT` and `DELETE` queries.
    * You can select and copy text from this window.
    * Click "Close" when finished viewing.
7.  **Save Changes (Conditional):**
    * If points were removed *and* you provided a filter value, a confirmation dialog will ask if you want to overwrite the original GPX file with the cleaned version.
    * Click "Yes" to save the changes (overwrite the original file).
    * Click "No" to discard the changes (the original file remains untouched).
    * If no points were removed or no filter was applied, this step is skipped.
8.  **Script Finish:** The script will indicate completion in the console.

## Functionality Details

1.  **Assembly Loading:** Ensures `System.Windows.Forms` and `System.Drawing` are available for GUI elements.
2.  **File Selection:** Uses `System.Windows.Forms.OpenFileDialog` for standard file selection.
3.  **Filter Input:** The `Get-FilterInput` function creates a custom form for specifying the coordinate type (`lat`/`lon`) and the prefix value. Basic validation checks for potentially unsafe characters (`;'`) in the filter value.
4.  **GPX Parsing:** Loads the GPX file as an XML document (`[xml]`). Uses an `XmlNamespaceManager` to handle the GPX namespace (`http://www.topografix.com/GPX/1/1`).
5.  **Timestamp Extraction (`Get-GpxTimeRange`):** Selects all `time` elements within `wpt` and `trkpt` nodes using XPath. Converts them to `[datetime]` objects, sorts them, and extracts the first and last. It also calculates the corresponding UTC Unix timestamps (seconds since 1970-01-01 00:00:00Z). Handles potential time parsing errors gracefully.
6.  **Cleaning Process:**
    * Constructs an XPath query (`//gpx:wpt[starts-with(@$coordinateType, '$coordinateValue')] | //gpx:trkpt[starts-with(@$coordinateType, '$coordinateValue')]`) to find points matching the filter criteria.
    * Iterates through the found nodes and removes them from their parent node in the in-memory XML document.
7.  **Analysis:** After potential cleaning, it re-analyzes timestamps and counts remaining `wpt` and `trkpt` nodes using XPath (`//gpx:wpt`, `//gpx:trkpt`).
8.  **SQL Generation:**
    * **SELECT:** Uses the *cleaned* first and last timestamps. Assumes a numeric `timestamp_column` storing Unix epoch seconds.
    * **DELETE:** Uses the *original* first and last timestamps and adds an `AND` condition based on the *filter criteria*. It includes a placeholder for the coordinate column (`your_latitude_column` or `your_longitude_column`) and suggests using a `::text` cast for `LIKE` comparisons if the database column is numeric (common in PostgreSQL). **Crucially warns the user about the danger of DELETE statements and the need to verify table/column names.**
9.  **Output Display (`Show-OutputWindow`):** Creates another custom form containing a multi-line, read-only text box to display the collected results and generated queries. Uses a monospaced font (Consolas) for better readability.
10. **Saving:** Uses the `$gpx.Save($gpxFilePath)` method to write the modified XML document back to the original file path if the user confirms. Includes error handling for the save operation.

## Notes and Limitations

* **GPX Version:** The script explicitly uses the namespace for GPX 1.1 (`http://www.topografix.com/GPX/1/1`). It might have issues with other GPX versions if the structure or namespace differs significantly.
* **Performance:** Loading and parsing very large GPX files entirely into memory might be slow or consume significant resources.
* **Filter Value:** The filter works on the *string representation* of the coordinate attribute. Ensure the prefix matches how coordinates are stored in your GPX file (e.g., including the decimal point if necessary).
* **SQL Safety:** While a basic check for `;` and `'` is included in the filter input, the script primarily *generates* SQL, it doesn't execute it. The responsibility for verifying and safely executing the generated SQL lies entirely with the user. The generated `DELETE` query is potentially destructive and requires careful review before execution.
* **Error Handling:** Basic error handling is implemented, but complex or malformed GPX files might cause unexpected issues.

## Disclaimer
The author is not responsible for any data loss or file corruption that may occur as a result of using this script. **Use at your own risk and always back up important data.**
