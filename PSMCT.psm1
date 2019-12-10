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

Export-ModuleMember -Function Get-MediaFiles
