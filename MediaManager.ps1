Import-Module PSMCT
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName 'System.Windows.Forms'

function New-UIElement {
    [CmdletBinding()]
    [OutputType([System.Windows.UIElement])]
    param (
        [Parameter(Mandatory=$true)][string]$XAMLFileName
    )
    [XML]$xaml = Get-Content $(Join-Path $PSScriptRoot $XAMLFileName)
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    return [Windows.Markup.XamlReader]::Load($reader)
}

$window = New-UIElement "MediaManager.xaml"

[System.Windows.Controls.ListView] $lvMediaFolders = $window.FindName("lvMediaFolders")
[System.Windows.Controls.ListView] $lvMediaFiles = $window.FindName("lvMediaFiles")
[System.Windows.Controls.TextBlock] $statusText = $window.FindName("statusText")
[System.Windows.Controls.ProgressBar] $statusProgress = $window.FindName("statusProgress")
[System.Windows.Controls.Primitives.ToggleButton] $btnMissingDate = $window.FindName("btnMissingDate")
[System.Windows.Controls.StackPanel] $itemDetailsPanel = $window.FindName("itemDetailsPanel")
[System.Windows.Controls.MediaElement] $preview = $window.FindName("preview")
[System.Windows.Controls.ListBox] $lbDuplicates = $window.FindName("lbDuplicates")
[System.Windows.Controls.MenuItem] $menuScanDir = $window.FindName("menuScanDir")
[System.Windows.Controls.MenuItem] $menuRemoveItem = $window.FindName("menuRemoveItem")
[System.Windows.Controls.MenuItem] $menuRemoveItemAndDups = $window.FindName("menuRemoveItemAndDups")
[System.Windows.Controls.MenuItem] $menuUsePhotoTaken = $window.FindName("menuUsePhotoTaken")
[System.Windows.Controls.MenuItem] $menuUseGoogleCreation = $window.FindName("menuUseGoogleCreation")
[System.Windows.Controls.MenuItem] $menuUseGoogleModification = $window.FindName("menuUseGoogleModification")
[System.Windows.Controls.MenuItem] $menuUseFileCreation = $window.FindName("menuUseFileCreation")
[System.Windows.Controls.MenuItem] $menuUseFileLastWrite = $window.FindName("menuUseFileLastWrite")
[System.Windows.Controls.MenuItem] $menuUseCustomDate = $window.FindName("menuUseCustomDate")

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
    [System.Collections.ArrayList] $MediaItems
    [array] $HashGroups
    [array] $FolderGroups
    [string] $FileName

    MediaCollection() {
        $this.MediaItems = [System.Collections.ArrayList]::new()
    }

    MediaCollection([MediaCollection] $otherCollection) {
        $this.MediaItems = [System.Collections.ArrayList]::new($otherCollection.MediaItems)

        $this.HashGroups = [array]::CreateInstance([System.Object], $otherCollection.HashGroups.Count)
        [array]::Copy($otherCollection.HashGroups, $this.HashGroups, $otherCollection.HashGroups.Count)

        $this.FolderGroups = [array]::CreateInstance([System.Object], $otherCollection.FolderGroups.Count)
        [array]::Copy($otherCollection.FolderGroups, $this.FolderGroups, $otherCollection.FolderGroups.Count)
    }

    MediaCollection([MediaItem[]] $mediaItems) {
        $this.SetItems($mediaItems)
    }

    [void] UpdateMetadata() {
        if ($this.MediaItems.Count -eq 0) {
            $this.HashGroups = @()
            $this.FolderGroups = @()
            return
        }
        Invoke-UI { $statusText.Text = "Calculating folder groups..." }
        
        $this.FolderGroups = $this.MediaItems | Group-Object "Directory" | Sort-Object "Name"
        if ($this.FolderGroups -isnot [array]) {
            $this.FolderGroups = @($this.FolderGroups)
        }
        
        Invoke-UI { $statusText.Text = "Calculating hash groups..." }
        $this.HashGroups = $this.MediaItems | Group-Object "Hash"

        Invoke-UI { $statusText.Text = "Calculating duplicates..." }
        $this.HashGroups | ForEach-Object {
            $count = $_.Group.Count
            $_.Group | ForEach-Object {
                $_.InstanceCount = $count
            }
        }
    }
    
    [void] SetItems([MediaItem[]] $MediaItems) {
        $this.MediaItems = [System.Collections.ArrayList]::new($MediaItems)
        $this.UpdateMetadata()
    }
    
    [void] AddItems([MediaItem[]] $MediaItems) {
        $this.MediaItems.AddRange($MediaItems)
        $uniqueItems = $this.MediaItems | Sort-Object "Path" -Unique
        if ($uniqueItems -isnot [array]) {
            $uniqueItems = @($uniqueItems)
        }
        $this.MediaItems = $uniqueItems
    
        $this.UpdateMetadata()
    }

    [void] Import([string] $Path) {
        $this.FileName = $Path
        Invoke-UI {
            $window.Cursor = $CURSOR_WAIT
            $statusText.Text = "Reading and converting $Path..." 
        }

        $importedItems = Get-Content $Path | ConvertFrom-Json

        Invoke-UI { $statusText.Text = "Normalizing items..." }
        $normalizedItems = $importedItems.ForEach({[MediaItem]$_})

        $this.SetItems($normalizedItems)

        Invoke-UI { $window.Cursor = $CURSOR_ARROW }
    }

    [void] Export([string] $Path) {
        $this.FileName = $Path
        $this.MediaItems | ConvertTo-Json > $Path
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
            $hashGroup = $($this.HashGroups | Where-Object { $_.Name -eq $Item.Hash}).Group
            $hashGroup | ForEach-Object { $this.MediaItems.Remove($_) }
        } else {
            $this.MediaItems.Remove($Item)
        }
        $this.UpdateMetadata()
    }

    [void] SetItemDate([MediaItem] $Item, [datetime] $DateTime , [boolean] $SetDuplicates) {
        if ($SetDuplicates) {
            $hashGroup = $($this.HashGroups | Where-Object { $_.Name -eq $Item.Hash}).Group
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
        $items = $mediaCollection.MediaItems | Where-Object { $null -eq $_.DateTaken }
        if ($items -is [array]) {
            $filteredCollection = [MediaCollection]::new($items)
        } else {
            $filteredCollection = [MediaCollection]::new()
        }
    } else {
        $filteredCollection = [MediaCollection]::new($mediaCollection)
    }

    $lvMediaFolders.ItemsSource = $filteredCollection.FolderGroups
    $lvMediaFolders.IsEnabled = $true

    $statusText.Text = "{0} items displayed in {1} folders, {2} of them are unique" -f $filteredCollection.MediaItems.Count,$filteredCollection.FolderGroups.Count,$filteredCollection.HashGroups.Count
}

$mediaCollection = [MediaCollection]::new()

$lvMediaFiles.add_MouseDoubleClick({
    if ($OpenMediaCmd.CanExecute($null, $lvMediaFiles)) {
        $OpenMediaCmd.Execute($null, $lvMediaFiles)
    }
})

$lvMediaFiles.add_SelectionChanged({
    Invoke-UI {
        if ($lvMediaFiles.SelectedItems.Count -eq 1) {
            $imageUri = [uri]::new($lvMediaFiles.SelectedItem.Path)
            $preview.Source = $imageUri
            $hashGroup = $mediaCollection.HashGroups | Where-Object { $_.Name -eq $lvMediaFiles.SelectedItem.Hash }
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

$btnMissingDate.add_Click({
    if ($RefreshCmd.CanExecute($null, $lvMediaFiles)) {
        $RefreshCmd.Execute($null, $lvMediaFiles)
    }
});

$window.CommandBindings.Add(
    [System.Windows.Input.CommandBinding]::new(
        [System.Windows.Input.ApplicationCommands]::New, 
        {
            $mediaCollection.SetItems(@())
            Update-MediaItems
        },
        {
            $_.CanExecute = $($mediaCollection.MediaItems.Count -gt 0)
        }
    )
) | Out-Null

$window.CommandBindings.Add(
    [System.Windows.Input.CommandBinding]::new(
        [System.Windows.Input.ApplicationCommands]::Open, 
        {
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
        }
    )
) | Out-Null

$window.CommandBindings.Add(
    [System.Windows.Input.CommandBinding]::new(
        [System.Windows.Input.ApplicationCommands]::SaveAs, 
        {
            $saveDialog = [Microsoft.Win32.SaveFileDialog]::new()
            $saveDialog.Filter = "JSON file (*.json)|*.json"
            if ($saveDialog.ShowDialog() -eq $true) {
                $mediaCollection.Export($saveDialog.FileName)
            }
        },
        { $_.CanExecute = $(($mediaCollection.MediaItems.Count -gt 0) -and ($null -ne $mediaCollection.FileName)) }
    )
) | Out-Null

$window.CommandBindings.Add(
    [System.Windows.Input.CommandBinding]::new(
        [System.Windows.Input.ApplicationCommands]::Save, 
        {
            $fileName = $mediaCollection.FileName
            if ($null -eq $fileName) {
                $saveDialog = [Microsoft.Win32.SaveFileDialog]::new()
                $saveDialog.Filter = "JSON file (*.json)|*.json"
                if ($saveDialog.ShowDialog() -eq $false) {
                    return
                }
                $fileName = $saveDialog.FileName
            }
            $mediaCollection.Export($fileName)
        },
        { $_.CanExecute = $($mediaCollection.MediaItems.Count -gt 0) }
    )
) | Out-Null

$ScanDirCmd = [System.Windows.Input.RoutedUICommand]::new(
    "Scan directory", "scandir", $window.GetType(),
    [System.Windows.Input.InputGestureCollection]::new(
        @(
            [System.Windows.Input.KeyGesture]::new(
                [System.Windows.Input.Key]::D, 
                [System.Windows.Input.ModifierKeys]::Control
            )
        )
    )
)
$window.CommandBindings.Add(
    [System.Windows.Input.CommandBinding]::new(
        $ScanDirCmd, 
        {
            $targetFolder = Get-Folder
            if ($null -eq $targetFolder) {
                return
            }
            
            Invoke-UI {
                $lvMediaFolders.IsEnabled = $false
                $lvMediaFiles.IsEnabled = $false
            }
        
            $mediaCollection.AddFolder($targetFolder)
            
            Invoke-UI { Update-MediaItems }
        }
    )
) | Out-Null
$menuScanDir.Command = $ScanDirCmd

$OpenMediaCmd = [System.Windows.Input.RoutedUICommand]::new(
    "Open Media", "openMedia", $window.GetType()
)
$window.CommandBindings.Add(
    [System.Windows.Input.CommandBinding]::new(
        $OpenMediaCmd,
        { Invoke-Item $lvMediaFiles.SelectedItem.Path },
        { $_.CanExecute = $($null -ne $lvMediaFiles.SelectedItem) }
    )
) | Out-Null
$menuOpenMedia.Command = $OpenMediaCmd

$RemoveMediaCmd = [System.Windows.Input.RoutedUICommand]::new(
    "Remove Media Item", "removeMedia", $window.GetType()
)
$window.CommandBindings.Add(
    [System.Windows.Input.CommandBinding]::new(
        $RemoveMediaCmd, 
        {
            $removeDuplicates = $($_.Parameter -eq $true)

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
        },
        { $_.CanExecute = $($null -ne $lvMediaFiles.SelectedItem) }
    )
) | Out-Null
$menuRemoveItem.Command = $RemoveMediaCmd
$menuRemoveItemAndDups.Command = $RemoveMediaCmd
$menuRemoveItemAndDups.CommandParameter = $true

$SetDateCmd = [System.Windows.Input.RoutedUICommand]::new(
    "Set Date Taken", "setDate", $window.GetType()
)
$window.CommandBindings.Add(
    [System.Windows.Input.CommandBinding]::new(
        $SetDateCmd, 
        {
            $dateSource = $_.Parameter

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
                    try {
                        $dateToSet = $_ | Select-Object -ExpandProperty $dateSource
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
            if ($null -ne $mediaCollection.FileName) {
                # Make sure that the changed dates are saved to the collection
                # otherwise it could contain invalid data on reload
                $mediaCollection.Export($mediaCollection.FileName)
            }
            Invoke-UI { 
                [System.ComponentModel.ICollectionView]$cvMediaFiles = [System.Windows.Data.CollectionViewSource]::GetDefaultView($lvMediaFiles.ItemsSource)
                $cvMediaFiles.Refresh()
             }
    
        },
        { $_.CanExecute = $($null -ne $lvMediaFiles.SelectedItem) }
    )
) | Out-Null
$menuUsePhotoTaken.Command = $SetDateCmd
$menuUsePhotoTaken.CommandParameter = "GooglePhotoTakenTime"
$menuUseGoogleCreation.Command = $SetDateCmd
$menuUseGoogleCreation.CommandParameter = "GoogleCreationTime"
$menuUseGoogleModification.Command = $SetDateCmd
$menuUseGoogleModification.CommandParameter = "GoogleModificationTime"
$menuUseFileCreation.Command = $SetDateCmd
$menuUseFileCreation.CommandParameter = "FileCreationTime"
$menuUseFileLastWrite.Command = $SetDateCmd
$menuUseFileLastWrite.CommandParameter = "FileLastWriteTime"
$menuUseCustomDate.Command = $SetDateCmd

$RefreshCmd = [System.Windows.Input.RoutedUICommand]::new(
    "Refresh Media List", "refresh", $window.GetType()
)
$window.CommandBindings.Add(
    [System.Windows.Input.CommandBinding]::new(
        $RefreshCmd, 
        {
            Invoke-UI { Update-MediaItems }
        },
        { $_.CanExecute = $($mediaCollection.MediaItems.Count -gt 0) }
    )
) | Out-Null
$menuOpenMedia.Command = $RefreshCmd

$window.ShowDialog() | Out-Null
