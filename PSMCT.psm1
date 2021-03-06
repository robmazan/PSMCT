Add-Type -AssemblyName 'System.Drawing'

<#
.SYNOPSIS

Get all media files recursively.

.DESCRIPTION

Lists all media files under given or current directory if Path parameter is omitted.
Primary focus is to retrieve personal photos, videos, so only the following extensions are
collected:

- *.jpg
- *.jpeg
- *.mov
- *.avi
- *.mp4

.OUTPUTS

Names of matching files.
#>
function Get-MediaFiles {
    param (
        [string] $Path = "."
    )
    Get-ChildItem -Path "$Path" -Name -File -Recurse -Include *.jpg,*.jpeg,*.mov,*.avi,*.mp4,*.3gp
}

<#
.SYNOPSIS

Get details about a file.

.DESCRIPTION

Retrieves the same details that can be accessed by right-clicking a file, and examining
the Details tab.

.OUTPUTS

HashMap of the file details attributes (exact structure depends on the file type).
#>
function Get-FileDetails {
    param (
        [Parameter(Mandatory=$true)][string] $Path
    )
    $item = Get-ChildItem $Path
    $shell = New-Object -ComObject Shell.Application
    $folder = $shell.NameSpace($item.DirectoryName)
    $file = $folder.ParseName($item.Name)
    $meta = New-Object psobject
    for ($attrIdx = 0; $attrIdx -le 266; $attrIdx++) {
        if ($folder.GetDetailsOf($file, $attrIdx)) {
            $hash += @{
                $($folder.GetDetailsOf($folder.items, $attrIdx)) = $($folder.GetDetailsOf($file, $attrIdx)) 
            }
            $meta | Add-Member $hash
        }
        $hash.Clear()
    }
    return $meta
}

<#
.SYNOPSIS

Extract the date from a media file when it was taken.

.DESCRIPTION

Evaluates data in following order:

1. EXIF information
2. "Media created" metadata

.OUTPUTS

Date when the file was taken (DateTime), or $null if the file
has no such metadata attached.
#>
function Get-DateTaken {
    param (
        [Parameter(Mandatory=$true)][string] $Path
    )
    $finalDate = $null

    try {
        $image = [System.Drawing.Image]::FromFile($Path)
        [byte[]] $exifDTOrig = $image.GetPropertyItem(0x9003).Value
        $takenDate = [System.Text.Encoding]::Default.GetString($exifDTOrig, 0, $exifDTOrig.Length - 1)
        $finalDate = [DateTime]::ParseExact($takenDate, 'yyyy:MM:dd HH:mm:ss', $null)
    } catch {
        $details = Get-FileDetails -Path $Path

        if ($null -ne $details."Date taken") {
            $detailsDate = ($details."Date taken").Replace([char]8206, ' ').Replace([char]8207, ' ')
            $finalDate = [DateTime]::ParseExact($detailsDate, ' M/ d/ yyyy   h:mm tt', $null)
        }

        if ($null -ne $details."Media created") {
            $detailsDate = $details."Media created"
            $createdDate = $detailsDate.Replace([char]8206, ' ').Replace([char]8207, ' ')
            if ($null -ne ($createdDate -as [DateTime])) {
                $finalDate = [DateTime]::Parse($createdDate)
            }
        }
    } finally {
        if ($image) {
            $image.Dispose()
        }
    }

    return $finalDate
}
<#
.SYNOPSIS

Adds the date taken EXIF data to an image file
#>
function Set-DateTaken {
    param (
        # Source image file
        [Parameter(Mandatory=$true)][string] $Path,
        # The DateTime to set as "Date Taken"
        [Parameter(Mandatory=$true)][datetime] $DateTime
    )
    
    [System.Drawing.Image] $image = [System.Drawing.Image]::FromFile($Path)
    $exifDateProp = $image.GetPropertyItem(0x9003)
    $dateStr = $DateTime.ToString('yyyy:MM:dd HH:mm:ss')
    
    $exifDateProp.Value = $dateStr.ToCharArray()
    $image.SetPropertyItem($exifDateProp)
    
    $resultStream = [System.IO.MemoryStream]::new()
    # Cannot save directly to $image, first it has to be disposed, so saving contents 
    # to a memory stream, disposing, and writing from the memory stream
    $image.Save($resultStream, $image.RawFormat)
    $image.Dispose()

    $fileStream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Create)
    $resultStream.WriteTo($fileStream)

    $fileStream.Flush()
    $fileStream.Close()
    $fileStream.Dispose()

    $resultStream.Close()
    $resultStream.Dispose()
}

enum GoogleImageDateField {
    CreationTime
    ModificationTime
    PhotoTakenTime
    All
}
function Get-GoogleDate {
    param (
        [Parameter(Mandatory=$true)][string] $Path,
        [Parameter(Mandatory=$true)][GoogleImageDateField] $DateField
    )
    $metadataFile = "$Path.json"
    if (Test-Path $metadataFile) {
        $metadata = Get-Content $metadataFile | ConvertFrom-Json
    } else {
        $metadata = @{}
    }
    [datetime]$epoch = [datetime]::Parse('1970-01-01')
    switch ($DateField) {
        CreationTime {  
            if ($null -eq $metadata.creationTime) {
                Write-Error "No creationTime metadata found!"
                return
            }
            $date = $epoch.AddSeconds($metadata.creationTime.timestamp)
        }
        ModificationTime {
            if ($null -eq $metadata.modificationTime) {
                Write-Error "No modificationTime metadata found!"
                return
            }                
            $date = $epoch.AddSeconds($metadata.modificationTime.timestamp)
        }
        PhotoTakenTime {
            if ($null -eq $metadata.photoTakenTime) {
                Write-Error "No photoTakenTime metadata found!"
                return
            }
            $date = $epoch.AddSeconds($metadata.photoTakenTime.timestamp)
        }
        All {
            $date = @{
                GoogleCreationTime = $(if ($null -ne $metadata.creationTime) {$epoch.AddSeconds($metadata.creationTime.timestamp)} else {$null})
                GoogleModificationTime = $(if ($null -ne $metadata.modificationTime) {$epoch.AddSeconds($metadata.modificationTime.timestamp)} else {$null})
                GooglePhotoTakenTime = $(if ($null -ne $metadata.PhotoTakenTime) {$epoch.AddSeconds($metadata.PhotoTakenTime.timestamp)} else {$null})
            }
        }
    }

    return $date
}
function Get-AllDates {
    param (
        [Parameter(Mandatory=$true)][string] $Path
    )
    $item = Get-Item $Path
    
    $dates = @{
        Path = $Path
        DateTaken = (Get-DateTaken -Path $Path)
        FileLastWriteTime = $item.LastWriteTime
        FileCreationTime = $item.CreationTime
    }

    $googleDates = Get-GoogleDate -Path $Path -DateField All
    if ($null -eq $googleDates) {
        $googleDates = @{
            GoogleCreationTime = $null
            GoogleModificationTime = $null
            GooglePhotoTakenTime = $null
        }
    }

    return ($dates + $googleDates)
}
function IsSameFile($path1, $path2) {
    $f1 = Get-ChildItem $path1
    $f2 = Get-ChildItem $path2

    if ($f1.Length -ne $f2.Length) {
        return $false
    }

    $h1 = Get-FileHash $f1
    $h2 = Get-FileHash $f2

    return ($h1.Hash -eq $h2.Hash)
}
<#
.SYNOPSIS

Add media files to a media library with a specified path and filename format
#>
function Add-Media {
    param (
        # Media file to be added
        [Parameter(Mandatory=$true)][string] $Path,
        # Media library folder path
        [Parameter(Mandatory=$true)][string] $MediaLibraryPath,
        # Path format string within media library
        # Receives the media taken date as {0} and the original filename as {1}
        [string] $DirectoryNameFormat = '{0:yyyy}\{0:MM}',
        # Filename format string within media library
        # Receives the media taken date as {0} and the original filename as {1}
        [string] $FileNameFormat = '{0:yy}-{0:MM}-{0:dd} {0:HH}-{0:mm}-{0:ss}'
    )
    $item = Get-ChildItem $Path
    if ($null -eq $item) {
        return
    }
    $mediaLibrary = Get-Item $MediaLibraryPath
    if ($null -eq $mediaLibrary) {
        return
    }
    if ($mediaLibrary -isnot [System.IO.DirectoryInfo]) {
        Write-Error "$MediaLibraryPath is not a directory!"
        return
    }
    $dateTaken = Get-DateTaken -Path $Path
    if ($null -eq $dateTaken) {
        $dateTaken = $item.LastWriteTime
    }
    $targetDirectory = Join-Path -Path $MediaLibraryPath -ChildPath $($DirectoryNameFormat -f $dateTaken,$item.Name)
    $targetFileBase = $FileNameFormat -f $dateTaken,$item.Name

    $extCounter = 1
    $targetFilePath = Join-Path -Path $targetDirectory -ChildPath $($targetFileBase + (" {0:d4}" -f $extCounter) + $item.Extension)
    while ([System.IO.File]::Exists($targetFilePath)) {
        if (IsSameFile $Path $targetFilePath) {
            Write-Debug "$Path has been added already to the media library."
            return
        }
        $extCounter++;
        $targetFilePath = Join-Path -Path $targetDirectory -ChildPath $($targetFileBase + (" {0:d4}" -f $extCounter) + $item.Extension)
    }

    if (-not (Test-Path $targetDirectory -PathType Container)) {
        New-Item $targetDirectory -ItemType Directory | Out-Null
    }

    Copy-Item $Path $targetFilePath
    return $targetFilePath
}
<#
.SYNOPSIS

Add a set of media files to the media library

.DESCRIPTION

Typical use case:

1. Collect the media files into a file with:

    PS > Get-MediaFiles > mediafiles.txt

2. Edit the "mediafiles.txt" and remove the files from it that you don't want to add

3. Load the file list to a variable:

    PS > $files = Get-Content mediafiles.txt

4. Add files to the media library and keep a list of the original location of the files:

    PS > Add-BulkMedia -Paths $files -MediaLibraryPath C:\MyMediaLibrary\ | ConvertTo-Csv > C:\MyMediaLibrary\import.csv


.OUTPUTS

A list of objects with "From" and "To" properties, where "From" is the original file location and "To"
is the new location. Note: "To" may be empty if the file was already existing in the media library folder.
#>
function Add-BulkMedia {
    param (
        # Media file paths to be added to the media library
        [Parameter(Mandatory=$true)][string[]] $Paths,
        # Media library folder path
        [Parameter(Mandatory=$true)][string] $MediaLibraryPath,
        # Path format string within media library
        # See Add-Media for details
        [string] $DirectoryNameFormat = '{0:yyyy}\{0:MM}',
        # Filename format string within media library
        # See Add-Media for details
        [string] $FileNameFormat = '{0:yy}-{0:MM}-{0:dd} {0:HH}-{0:mm}-{0:ss}'
    )
    for ($i = 0; $i -lt $Paths.Length; $i++) {
        $Path = $Paths[$i];

        Write-Progress "Adding files to media library" -Status $Path -PercentComplete $($i*100/$Paths.Length)
        $targetFile = Add-Media -Path $Path -MediaLibraryPath $MediaLibraryPath -DirectoryNameFormat $DirectoryNameFormat -FileNameFormat $FileNameFormat
        [PSCustomObject]@{
            From = $Path
            To = $targetFile            
        }        
    }
}

Export-ModuleMember -Function Get-MediaFiles
Export-ModuleMember -Function Get-DateTaken
Export-ModuleMember -Function Get-FileDetails
Export-ModuleMember -Function Add-Media
Export-ModuleMember -Function Add-BulkMedia
Export-ModuleMember -Function Get-GoogleDate
Export-ModuleMember -Function Set-DateTaken
Export-ModuleMember -Function Get-AllDates
