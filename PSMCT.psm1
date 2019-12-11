[Reflection.Assembly]::LoadFile('C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Drawing.dll') | Out-Null

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
3. The date when the file was last modified

.OUTPUTS

Date when the file was taken (DateTime)
#>
function Get-DateTaken {
    param (
        [Parameter(Mandatory=$true)][string] $Path
    )
    $item = Get-ChildItem $Path
    $finalDate = $item.LastWriteTime

    try {
        $image = New-Object System.Drawing.Bitmap -ArgumentList $Path
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
        New-Item $targetDirectory -ItemType Directory
    }

    Copy-Item $Path $targetFilePath
}

Export-ModuleMember -Function Get-MediaFiles
Export-ModuleMember -Function Get-DateTaken
Export-ModuleMember -Function Get-FileDetails
Export-ModuleMember -Function Add-Media
