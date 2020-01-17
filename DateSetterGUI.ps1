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
    [int]$InstanceCount
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
function Update-MediaItems {
    if ($btnMissingDate.IsChecked) {
        $items = $mediaItems | Where-Object { $null -eq $_.DateTaken }
    } else {
        $items = $mediaItems
    }
    $folderGroups = $items | Group-Object "Directory" | Sort-Object "Name"
    if ($folderGroups -isnot [array]) {
        $folderGroups = @($folderGroups)
    }
    $lvMediaFolders.ItemsSource = $folderGroups
    $lvMediaFolders.IsEnabled = $true

    Set-Variable -Name "hashGroups" -Value $($items | Group-Object "Hash") -Scope Script
    $statusText.Text = "{0} items displayed in {1} folders, {2} of them are unique" -f $items.Count,$folderGroups.Count,$hashGroups.Count

    $mediaItems | ForEach-Object {
        $hash = $_.Hash
        $_.InstanceCount = $($hashGroups | Where-Object {$_.Name -eq $hash}).Group.Count
    }
}

function Remove-MediaItem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][MediaItem]$Item,
        [switch]$RemoveDuplicates
    )
    if ($RemoveDuplicates) {
        $hashGroup = $($hashGroups | Where-Object { $_.Name -eq $Item.Hash}).Group
        $hashGroup | ForEach-Object { $mediaItems.Remove($_) }
    } else {
        $mediaItems.Remove($Item)
    }
}

[XML]$mediaListViewXaml = Get-Content $(Join-Path $PSScriptRoot "DateSetterWindow.xaml")
$window = New-UIElement $mediaListViewXaml

[System.Windows.Controls.ListView]$lvMediaFolders = $window.FindName("lvMediaFolders")
[System.Windows.Controls.ListView]$lvMediaFiles = $window.FindName("lvMediaFiles")
[System.Windows.Controls.TextBlock]$statusText = $window.FindName("statusText")
[System.Windows.Controls.ProgressBar]$statusProgress = $window.FindName("statusProgress")
$mediaItems = [System.Collections.ArrayList]::new()
$hashGroups = @()
[System.Windows.Controls.Primitives.ToggleButton]$btnMissingDate = $window.FindName("btnMissingDate")

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
        $lvMediaFolders.ItemsSource = @()
        $lvMediaFolders.IsEnabled = $false
        $lvMediaFiles.ItemsSource = @()
        $lvMediaFiles.IsEnabled = $false
    }

    [string[]]$mediaFiles = Get-MediaFiles $targetFolder

    Invoke-UI {
        $statusProgress.Visibility = [System.Windows.Visibility]::Visible
        $statusProgress.Maximum = $mediaFiles.Length
    }

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
    $uniqueItems = $mediaItems | Sort-Object "Path" -Unique
    if ($uniqueItems -isnot [array]) {
        $uniqueItems = @($uniqueItems)
    }
    $mediaItems = [System.Collections.ArrayList]::new($uniqueItems)
    
    Invoke-UI {
        Update-MediaItems
        $statusProgress.Visibility = [System.Windows.Visibility]::Hidden
        $window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }

});

([System.Windows.Controls.MenuItem]$window.FindName("menuExport")).add_Click({
    $saveDialog = [Microsoft.Win32.SaveFileDialog]::new()
    $saveDialog.Filter = "JSON file (*.json)|*.json"
    if ($saveDialog.ShowDialog() -eq $true) {
        $mediaItems | ConvertTo-Json > $($saveDialog.FileName)
    }
})

([System.Windows.Controls.MenuItem]$window.FindName("menuImport")).add_Click({
    $openDialog = [Microsoft.Win32.OpenFileDialog]::new()
    $openDialog.Filter = "JSON file (*.json)|*.json"
    if ($openDialog.ShowDialog() -eq $true) {
        Invoke-UI {
            $window.Cursor = [System.Windows.Input.Cursors]::Wait
            $statusText.Text = "Importing media list..."
            $lvMediaFolders.ItemsSource = @()
            $lvMediaFolders.IsEnabled = $false
            $lvMediaFiles.ItemsSource = @()
            $lvMediaFiles.IsEnabled = $false
        }
    
        $importedItems = Get-Content $($openDialog.FileName) | ConvertFrom-Json
        $mediaItems.AddRange($importedItems)
        $uniqueItems = $mediaItems | Sort-Object "Path" -Unique
        if ($uniqueItems -isnot [array]) {
            $uniqueItems = @($uniqueItems)
        }
        $mediaItems = [System.Collections.ArrayList]::new($uniqueItems)
    
        Invoke-UI {
            Update-MediaItems
            $window.Cursor = [System.Windows.Input.Cursors]::Arrow
        }
    }
})

$lvMediaFolders.add_SelectionChanged({
    $selectedMediaItems = $lvMediaFolders.SelectedItems | Select-Object -ExpandProperty "Group"
    if ($selectedMediaItems -isnot [System.Collections.IEnumerable]) {
        $selectedMediaItems = @($selectedMediaItems)
    }

    $lvMediaFiles.ItemsSource = $selectedMediaItems
    [System.ComponentModel.ICollectionView]$cvMediaFiles = [System.Windows.Data.CollectionViewSource]::GetDefaultView($lvMediaFiles.ItemsSource)
    $groupByDir = New-Object System.Windows.Data.PropertyGroupDescription "Directory"
    $cvMediaFiles.GroupDescriptions.Add($groupByDir)
    $lvMediaFiles.IsEnabled = $true
})

$removeHandler = {
    $menuItem = [System.Windows.Controls.MenuItem]$this
    $removeDuplicates = $menuItem.Header.ToString().Contains("duplicates")

    if ($lvMediaFiles.SelectedItems.Count -eq 1) {
        $message = "Do you want to remove {0} from the media list?"  -f $lvMediaFiles.SelectedItems[0].FileName
        $message += [System.Environment]::NewLine + "(this doesn't affect the original file)"
    } else {
        $message = "Do you want to remove these {0} items from the media list?"  -f $lvMediaFiles.SelectedItems.Count
        $message += [System.Environment]::NewLine + "(this doesn't affect the original files)"
    }
    if ($removeDuplicates) {
        $message += [System.Environment]::NewLine + [System.Environment]::NewLine
        $message += "Duplicates of this file will also be removed from the list too, if there are any."
    }
    [System.Windows.MessageBoxResult]$result = [System.Windows.MessageBox]::Show(
        $message, 
        "Remove item from media list", 
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Exclamation,
        [System.Windows.MessageBoxResult]::No
    )
    if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
        $lvMediaFiles.SelectedItems | ForEach-Object {
            if ($removeDuplicates) {
                Remove-MediaItem -Item $_ -RemoveDuplicates
            } else {
                Remove-MediaItem -Item $_
            }
        }
        Invoke-UI { Update-MediaItems }
    }    
}

([System.Windows.Controls.MenuItem]$window.FindName("menuRemoveItem")).add_Click($removeHandler);
([System.Windows.Controls.MenuItem]$window.FindName("menuRemoveItemAndDups")).add_Click($removeHandler);

$btnMissingDate.add_Click({ Invoke-UI { Update-MediaItems } });
([System.Windows.Controls.MenuItem]$window.FindName("menuUsePhotoTaken")).add_Click({Write-Host $lvMediaFiles.SelectedItems});
([System.Windows.Controls.MenuItem]$window.FindName("menuUseCustomDate")).add_Click({Get-DateFromDialog});

$window.ShowDialog() | Out-Null
