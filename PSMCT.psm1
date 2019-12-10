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
    Get-ChildItem -Path "$Path" -Name -File -Recurse -Include *.jpg,*.jpeg,*.mov,*.avi,*.mp4
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

        if ($null -ne $details."Media created") {
            $createdDate = ($details."Media created").Replace([char]8206, ' ').Replace([char]8207, ' ')
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

Export-ModuleMember -Function Get-MediaFiles
Export-ModuleMember -Function Get-DateTaken
Export-ModuleMember -Function Get-FileDetails
