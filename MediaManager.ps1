Import-Module PSMCT
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName 'System.Windows.Forms'

function New-UIElement {
    [CmdletBinding()]
    [OutputType([System.Windows.UIElement])]
    param (
        [Parameter(Mandatory=$true)][string]$XAMLFileName
    )
    [XML]$XAML = Get-Content $(Join-Path $PSScriptRoot $XAMLFileName)
    $reader = New-Object System.Xml.XmlNodeReader $XAML
    return [Windows.Markup.XamlReader]::Load($reader)
}

$window = New-UIElement "DateSetterWindow.xaml"

[System.Windows.Controls.ListView]$lvMediaFolders = $window.FindName("lvMediaFolders")
[System.Windows.Controls.ListView]$lvMediaFiles = $window.FindName("lvMediaFiles")
[System.Windows.Controls.TextBlock]$statusText = $window.FindName("statusText")
[System.Windows.Controls.ProgressBar]$statusProgress = $window.FindName("statusProgress")
[System.Windows.Controls.Primitives.ToggleButton]$btnMissingDate = $window.FindName("btnMissingDate")
[System.Windows.Controls.StackPanel]$itemDetailsPanel = $window.FindName("itemDetailsPanel")
[System.Windows.Controls.MediaElement]$preview = $window.FindName("preview")
[System.Windows.Controls.ListBox]$lbDuplicates = $window.FindName("lbDuplicates")

$CURSOR_WAIT = [System.Windows.Input.Cursors]::Wait
$CURSOR_ARROW = [System.Windows.Input.Cursors]::Arrow
$VISIBILITY_VISIBLE = [System.Windows.Visibility]::Visible
$VISIBILITY_HIDDEN = [System.Windows.Visibility]::Hidden
$VISIBILITY_COLLAPSED = [System.Windows.Visibility]::Collapsed

function Invoke-UI {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)] [scriptblock] $Action
    )

    $window.Dispatcher.Invoke($Action, [Windows.Threading.DispatcherPriority]::ContextIdle)
}

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

class MediaCollection {
    [System.Collections.ArrayList] $mediaItems
    [array]$hashGroups
    [array]$folderGroups

    MediaCollection() {
        $this.mediaItems = [System.Collections.ArrayList]::new()
    }

    MediaCollection([MediaCollection] $otherCollection) {
        $this.mediaItems = [System.Collections.ArrayList]::new($otherCollection.mediaItems)

        $this.hashGroups = [array]::CreateInstance([System.Object], $otherCollection.hashGroups.Count)
        [array]::Copy($otherCollection.hashGroups, $this.hashGroups, $otherCollection.hashGroups.Count)

        $this.folderGroups = [array]::CreateInstance([System.Object], $otherCollection.folderGroups.Count)
        [array]::Copy($otherCollection.folderGroups, $this.folderGroups, $otherCollection.folderGroups.Count)
    }

    MediaCollection([MediaItem[]] $mediaItems) {
        $this.SetItems($mediaItems)
    }

    [void] UpdateMetadata() {
        Invoke-UI { $statusText.Text = "Calculating folder groups..." }
        
        $this.folderGroups = $this.mediaItems | Group-Object "Directory" | Sort-Object "Name"
        if ($this.folderGroups -isnot [array]) {
            $this.folderGroups = @($this.folderGroups)
        }
        
        Invoke-UI { $statusText.Text = "Calculating hash groups..." }
        $this.hashGroups = $this.mediaItems | Group-Object "Hash"

        Invoke-UI { $statusText.Text = "Calculating duplicates..." }
        $this.hashGroups | ForEach-Object {
            $count = $_.Group.Count
            $_.Group | ForEach-Object {
                $_.InstanceCount = $count
            }
        }
    }
    
    [void] SetItems([MediaItem[]] $mediaItems) {
        $this.mediaItems = [System.Collections.ArrayList]::new($mediaItems)
        $this.UpdateMetadata()
    }
    
    [void] AddItems([MediaItem[]] $mediaItems) {
        $this.mediaItems.AddRange($mediaItems)
        $uniqueItems = $this.mediaItems | Sort-Object "Path" -Unique
        if ($uniqueItems -isnot [array]) {
            $uniqueItems = @($uniqueItems)
        }
        $this.mediaItems = $uniqueItems
    
        $this.UpdateMetadata()
    }

    [void] Import([string] $Path) {
        Invoke-UI {
            $window.Cursor = $CURSOR_WAIT
            $statusText.Text = "Reading and converting $Path..." 
        }

        $importedItems = Get-Content $Path | ConvertFrom-Json

        Invoke-UI { $statusText.Text = "Normalizing items..." }
        $normalizedItems = $importedItems.ForEach({[MediaItem]$_})

        $this.AddItems($normalizedItems)

        Invoke-UI { $window.Cursor = $CURSOR_ARROW }
    }

    [void] Export([string] $Path) {
        $this.mediaItems | ConvertTo-Json > $Path
    }

    [void] AddFolder([string] $Path) {
        Invoke-UI {
            $window.Cursor = $CURSOR_WAIT
            $statusText.Text = "Scanning directory for media files..."
        }
    
        [string[]]$mediaFiles = Get-MediaFiles $Path
    
        Invoke-UI {
            $statusProgress.Visibility = $VISIBILITY_VISIBLE
            $statusProgress.Maximum = $mediaFiles.Length
        }
    
        $items = [System.Collections.ArrayList]::new()
        for ($i = 0; $i -lt $mediaFiles.Length; $i++) {
            Invoke-UI {
                $statusProgress.Value = $i;
                $statusText.Text = "Collecting metadata for {0}..." -f $mediaFiles[$i]
            }
    
            $item = Get-Item $(Join-Path $Path $mediaFiles[$i])
            $hash = Get-FileHash $item.FullName
            $items.Add(
                [MediaItem](@{
                    Directory=$item.DirectoryName
                    FileName=$item.Name
                    Hash=$hash.Hash
                } + $(Get-AllDates $item.FullName))
            )
        }
        $this.AddItems($items)
        
        Invoke-UI {
            $statusProgress.Visibility = $VISIBILITY_HIDDEN
            $window.Cursor = $CURSOR_ARROW
        }
    }

    [void] RemoveItem([MediaItem] $Item, [boolean] $RemoveDuplicates) {
        if ($RemoveDuplicates) {
            $hashGroup = $($this.hashGroups | Where-Object { $_.Name -eq $Item.Hash}).Group
            $hashGroup | ForEach-Object { $this.mediaItems.Remove($_) }
        } else {
            $this.mediaItems.Remove($Item)
        }
        $this.UpdateMetadata()
    }

    [void] SetItemDate([MediaItem] $Item, [datetime] $DateTime , [boolean] $SetDuplicates) {
        if ($SetDuplicates) {
            $hashGroup = $($this.hashGroups | Where-Object { $_.Name -eq $Item.Hash}).Group
            $hashGroup | ForEach-Object {
                $_.DateTaken = $DateTime
                Set-DateTaken -Path $_.Path -DateTime $DateTime
            }
        } else {
            $Item.DateTaken = $DateTime
            Set-DateTaken -Path $_.Path -DateTime $DateTime
        }
    }
}

function Get-DateFromDialog {
    [CmdletBinding()]
    param (
        [Parameter()][datetime] $InitialValue
    )

    [System.Windows.Window]$dateInputDialog = New-UIElement "DateInputDialog.xaml"
    
    [System.Windows.Controls.Button]$btnDialogOk = $dateInputDialog.FindName("btnDialogOk");
    [System.Windows.Controls.DatePicker]$datePicker = $dateInputDialog.FindName("datePicker")
    [System.Windows.Controls.TextBox]$timeInput = $dateInputDialog.FindName("timeInput")

    if ($InitialValue) {
        $datePicker.SelectedDate = $InitialValue
        $timeInput.Text = $InitialValue.ToString("HH:mm:ss")
    }

    $btnDialogOk.add_Click({
        $dateInputDialog.DialogResult = $true;
    });

    if ($dateInputDialog.ShowDialog()) {
        # TODO: better time input validation
        if ($timeInput.Text.Length -eq 8) {
            $time = $timeInput.Text
        } else {
            $time = "00:00:00"
        }
        $datetimeStr = [string]::Join(" ", @($datePicker.SelectedDate.ToString("yyyy-MM-dd"), $time))
        $result = [datetime]::ParseExact($datetimeStr, "yyyy-MM-dd HH:mm:ss", $null)
        return $result
    }
}

function Get-Folder {
    $folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $folderDialog.Description = "Select folder for scanning"
    if ($folderDialog.ShowDialog() -eq "OK") {
        return $folderDialog.SelectedPath
    }
}

function Update-MediaItems {
    if ($btnMissingDate.IsChecked) {
        $items = $mediaCollection.mediaItems | Where-Object { $null -eq $_.DateTaken }
        $filteredCollection = [MediaCollection]::new($items)
    } else {
        $filteredCollection = [MediaCollection]::new($mediaCollection)
    }

    $lvMediaFolders.ItemsSource = $filteredCollection.folderGroups
    $lvMediaFolders.IsEnabled = $true

    $statusText.Text = "{0} items displayed in {1} folders, {2} of them are unique" -f $filteredCollection.mediaItems.Count,$filteredCollection.folderGroups.Count,$filteredCollection.hashGroups.Count
}

$mediaCollection = [MediaCollection]::new()

$lvMediaFiles.add_MouseDoubleClick({
    Invoke-Item $lvMediaFiles.SelectedItem.Path
})

$lvMediaFiles.add_SelectionChanged({
    Invoke-UI {
        if ($lvMediaFiles.SelectedItems.Count -eq 1) {
            $imageUri = [uri]::new($lvMediaFiles.SelectedItem.Path)
            $preview.Source = $imageUri
            $hashGroup = $mediaCollection.hashGroups | Where-Object { $_.Name -eq $lvMediaFiles.SelectedItem.Hash }
            if ($hashGroup.Group.Count -eq 1) {
                $lbDuplicates.Visibility = $VISIBILITY_COLLAPSED
            } else {
                $lbDuplicates.Visibility = $VISIBILITY_VISIBLE
                $lbDuplicates.ItemsSource = $hashGroup.Group | ForEach-Object { $_.Path }
            }
            $itemDetailsPanel.Visibility = $VISIBILITY_VISIBLE
        } else {
            $preview.Source = $null
            $itemDetailsPanel.Visibility = $VISIBILITY_COLLAPSED
        }
    }
})

([System.Windows.Controls.MenuItem]$window.FindName("menuScanDir")).add_Click({
    $targetFolder = Get-Folder
    if ($null -eq $targetFolder) {
        return
    }
    
    Invoke-UI {
        $lvMediaFolders.ItemsSource = @()
        $lvMediaFolders.IsEnabled = $false
        $lvMediaFiles.ItemsSource = @()
        $lvMediaFiles.IsEnabled = $false
    }

    $mediaCollection.AddFolder($targetFolder)
    
    Invoke-UI { Update-MediaItems }
});

([System.Windows.Controls.MenuItem]$window.FindName("menuExport")).add_Click({
    $saveDialog = [Microsoft.Win32.SaveFileDialog]::new()
    $saveDialog.Filter = "JSON file (*.json)|*.json"
    if ($saveDialog.ShowDialog() -eq $true) {
        $mediaCollection.Export($saveDialog.FileName)
    }
})

([System.Windows.Controls.MenuItem]$window.FindName("menuImport")).add_Click({
    $openDialog = [Microsoft.Win32.OpenFileDialog]::new()
    $openDialog.Filter = "JSON file (*.json)|*.json"
    if ($openDialog.ShowDialog() -eq $true) {
        Invoke-UI {
            $lvMediaFolders.ItemsSource = @()
            $lvMediaFolders.IsEnabled = $false
            $lvMediaFiles.ItemsSource = @()
            $lvMediaFiles.IsEnabled = $false
        }

        $mediaCollection.Import($openDialog.FileName)
    
        Invoke-UI { Update-MediaItems }
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
            $mediaCollection.RemoveItem($_, $removeDuplicates)
        }
        Invoke-UI { Update-MediaItems }
    }    
}

([System.Windows.Controls.MenuItem]$window.FindName("menuRemoveItem")).add_Click($removeHandler);
([System.Windows.Controls.MenuItem]$window.FindName("menuRemoveItemAndDups")).add_Click($removeHandler);

$btnMissingDate.add_Click({ Invoke-UI { Update-MediaItems } });

$dateSourceMap = @{
    menuUsePhotoTaken = "GooglePhotoTakenTime"
    menuUseGoogleCreation = "GoogleCreationTime"
    menuUseGoogleModification = "GoogleModificationTime"
    menuUseFileCreation = "FileCreationTime"
    menuUseFileLastWrite = "FileLastWriteTime"
    menuUseCustomDate = $null
}
$dateSourceMap.Keys | ForEach-Object {
    ([System.Windows.Controls.MenuItem]$window.FindName($_)).add_Click({
        [System.Windows.Controls.MenuItem]$menuItem = $this

        $dateSource = $dateSourceMap[$menuItem.Name]

        if ($null -eq $dateSource) {
            $dateTaken = $lvMediaFiles.SelectedItem.DateTaken
            if ($null -ne $dateTaken) {
                $dateFromInput = Get-DateFromDialog -InitialValue $dateTaken
            } else {
                $dateFromInput = Get-DateFromDialog
            }
        }
        $datesToSet = $lvMediaFiles.SelectedItems | ForEach-Object {
            if ($null -eq $dateSource) {
                $dateToSet = $dateFromInput
            } else {
                $dates = Get-AllDates $_.Path
                try {
                    $dateToSet = $dates[$dateSource]
                } catch {
                    $dateToSet = $null
                }
            }
            [PSCustomObject]@{
                Item = $_
                Date = $dateToSet
            }
        }

        $datesToSet | ForEach-Object {
            if ($null -ne $_.Date) {
                $mediaCollection.SetItemDate($_.Item, $_.Date, $true)
            }
        }
        Invoke-UI { 
            [System.ComponentModel.ICollectionView]$cvMediaFiles = [System.Windows.Data.CollectionViewSource]::GetDefaultView($lvMediaFiles.ItemsSource)
            $cvMediaFiles.Refresh()
         }
    });
}

$window.ShowDialog() | Out-Null
