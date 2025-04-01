# gpx-scripts
A collection of Powershellscripts to work with GPX Files. Main Goal is to reduce clutter due to gps inaccuracy or other sources of location tracking. This mainly started as some cleanup tools for Trips in my [Dawarich App](https://dawarich.app/ "Dawarich App")

Usage:

1. Export your trip from Dawarich as GPX- File (other file formats are not supported)
2. Identify your legitimate GPS Points and Points you regard as "Noise"
3. Determine the best way to differentiate between these. These could be by latitude or bei longitude
4. make a copy of your gpx file just in case, because the original file with overwritten
5. run gpx-clean.ps1 in a powershell terminal with 
`./gpx-clean.ps1`

You will be prompted to 
- Enter the Path of your gpx file 
- Wether you want to clean bei Longitude or Latitude (enter lat or lon accordingly)
- The Value your GPS Coordinate, you want to clean up with, starts with. Like if you want every latitude cleaned up, thats starts with 52. simply put in 52. you can add more digits after the decimal point to filter more granular

If you have several Filters you want to apply, just rerun the script with your other coordinates

6. run gpx-info.ps1 with
`./gpx-info.ps1`
Enter the Path of your gpx file. 
The Script will output the timestamp of the first and last Waypoint of your trip and generates an SQL Query to filter between these Dates. 
You can use that to use in either [HeidiSQL](https://www.heidisql.com/ "HeidiSQL") or [pgAdmin](https://www.pgadmin.org/ "pgAdmin") to show you the exact trip inside the Database. 
For now you need to delete the wrong points from the Database manually, but using these Databasepoints make it a fairly easy job to do, since you can Order and Group by longitude or latitude, 
which makes it easy to identify the Noise Values in your Database
