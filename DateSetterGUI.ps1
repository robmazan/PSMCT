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

function Invoke-UI {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [scriptblock]
        $Action
    )

    $window.Dispatcher.Invoke($Action, [Windows.Threading.DispatcherPriority]::ContextIdle)
}
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

[XML]$mediaListViewXaml = Get-Content $(Join-Path $PSScriptRoot "DateSetterWindow.xaml")
$window = New-UIElement $mediaListViewXaml

[System.Windows.Controls.ListView]$lvMediaFiles = $window.FindName("lvMediaFiles")
[System.Windows.Controls.TextBlock]$statusText = $window.FindName("statusText")
[System.Windows.Controls.ProgressBar]$statusProgress = $window.FindName("statusProgress")

$lvMediaFiles.add_MouseDoubleClick({
    Invoke-Item $lvMediaFiles.SelectedItem.Path
})

([System.Windows.Controls.MenuItem]$window.FindName("menuScanDir")).add_Click({
    $targetFolder = Get-Folder
    if ($null -eq $targetFolder) {
        return
    }
    
    Invoke-UI {
        $window.Cursor = [System.Windows.Input.Cursors]::Wait
        $statusText.Text = "Scanning directory for media files..."
        $lvMediaFiles.ItemsSource = @()
        $lvMediaFiles.IsEnabled = $false
    }

    [string[]]$mediaFiles = Get-MediaFiles $targetFolder

    Invoke-UI {
        $statusProgress.Visibility = [System.Windows.Visibility]::Visible
        $statusProgress.Maximum = $mediaFiles.Length
    }


    $mediaItems = [System.Collections.ArrayList]::new()
    for ($i = 0; $i -lt $mediaFiles.Length; $i++) {
        Invoke-UI {
            $statusProgress.Value = $i;
            $statusText.Text = "Collecting metadata for {0}..." -f $mediaFiles[$i]
        }

        $item = Get-Item $(Join-Path $targetFolder $mediaFiles[$i])
        $hash = Get-FileHash $item.FullName
        $mediaItem = [MediaItem](@{
            Directory=$item.DirectoryName
            FileName=$item.Name
            Hash=$hash.Hash
        } + $(Get-AllDates $item.FullName))
        $mediaItems.Add($mediaItem)
    }
    
    Invoke-UI {
        Set-MediaItems $mediaItems
        $statusProgress.Visibility = [System.Windows.Visibility]::Hidden
        $statusText.Text = ""
        $lvMediaFiles.IsEnabled = $true
        $window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }

});

([System.Windows.Controls.MenuItem]$window.FindName("menuUsePhotoTaken")).add_Click({Write-Host $lvMediaFiles.SelectedItems});
([System.Windows.Controls.MenuItem]$window.FindName("menuUseCustomDate")).add_Click({Get-DateFromDialog});

$window.ShowDialog() | Out-Null
