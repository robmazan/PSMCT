Import-Module PSMCT
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName 'System.Windows.Forms'

class MediaItem {
    [ValidateNotNullOrEmpty()][string]$Directory
    [ValidateNotNullOrEmpty()][string]$FileName
    [string]$Path
    [nullable[datetime]]$DateTaken
    [nullable[datetime]]$FileCreationTime
    [nullable[datetime]]$FileLastWriteTime
    [nullable[datetime]]$GooglePhotoTakenTime
    [nullable[datetime]]$GoogleCreationTime
    [nullable[datetime]]$GoogleModificationTime
    [ValidateNotNullOrEmpty()][string]$Hash
}

function New-UIElement {
    [CmdletBinding()]
    [OutputType([System.Windows.UIElement])]
    param (
        [Parameter(Mandatory=$true)][XML]$XAML
    )
    $reader = New-Object System.Xml.XmlNodeReader $XAML
    return [Windows.Markup.XamlReader]::Load($reader)
}

function Get-DateFromDialog {
    [XML]$dateInputDialogXaml = Get-Content $(Join-Path $PSScriptRoot "DateInputDialog.xaml")
    [System.Windows.Window]$dateInputDialog = New-UIElement $dateInputDialogXaml
    [System.Windows.Controls.Button]$btnDialogOk = $dateInputDialog.FindName("btnDialogOk");
    $btnDialogOk.add_Click({
        $dateInputDialog.DialogResult = $true;
    });
    if ($dateInputDialog.ShowDialog()) {
        [System.Windows.Controls.DatePicker]$datePicker = $dateInputDialog.FindName("datePicker")
        return $datePicker.SelectedDate
    }
}

function Get-Folder {
    $folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $folderDialog.Description = "Select folder for scanning"
    if ($folderDialog.ShowDialog() -eq "OK") {
        return $folderDialog.SelectedPath
    }
}

[XML]$mediaListViewXaml = Get-Content $(Join-Path $PSScriptRoot "DateSetterWindow.xaml")
$window = New-UIElement $mediaListViewXaml

[System.Windows.Controls.ListView]$lvMediaFiles = $window.FindName("lvMediaFiles")

function Set-MediaItems {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [MediaItem[]]
        $mediaItems
    )
    $lvMediaFiles.ItemsSource = $mediaItems
    [System.ComponentModel.ICollectionView]$cvMediaFiles = [System.Windows.Data.CollectionViewSource]::GetDefaultView($lvMediaFiles.ItemsSource)
    $groupByDir = New-Object System.Windows.Data.PropertyGroupDescription "Directory"
    $cvMediaFiles.GroupDescriptions.Add($groupByDir)
}

([System.Windows.Controls.MenuItem]$window.FindName("menuScanDir")).add_Click({
    $targetFolder = Get-Folder
    Write-Host $targetFolder
    if ($null -eq $targetFolder) {
        return
    }
    $window.Cursor = [System.Windows.Input.Cursors]::WaitCursor
    $mediaItems = Get-MediaFiles $targetFolder | ForEach-Object {
        $item = Get-Item $(Join-Path $targetFolder $_)
        $hash = Get-FileHash $item.FullName
        return [MediaItem](@{
            Directory=$item.DirectoryName
            FileName=$item.Name
            Hash=$hash.Hash
        } + $(Get-AllDates $item.FullName))
    }
    Set-MediaItems $mediaItems
    $window.Cursor = [System.Windows.Input.Cursors]::Arrow
});

([System.Windows.Controls.MenuItem]$window.FindName("menuUsePhotoTaken")).add_Click({Write-Host $lvMediaFiles.SelectedItems});
([System.Windows.Controls.MenuItem]$window.FindName("menuUseCustomDate")).add_Click({Get-DateFromDialog});

$window.ShowDialog() | Out-Null
