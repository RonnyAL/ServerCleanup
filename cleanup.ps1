$MaxAgeUpdates = 30
$MaxAgeLogs = 14

class ActionLogger {
    [System.Collections.Generic.List[object]]$ActionLog = @()
    [int]$maxLines = 5

    ShowLog() {
        if ($this.ActionLog.Count -lt 1) {Return}
        Write-Host `n"=================== Log ===================" -ForegroundColor Yellow
        if ($this.ActionLog.Count -gt $this.maxLines) {Write-Host "···"}
        foreach ($Action in $this.ActionLog | Select-Object -Last $this.maxLines) {
            Write-Host $Action.TimeStamp "" -NoNewLine
            Write-Host $Action.Text -ForegroundColor $Action.ForegroundColor
        }
    }

    [void]LogSuccess([string]$Text) {
        $this.LogAction($Text, 'Green')
    }

    [void]LogError([string]$Text) {
        $this.LogAction($Text, 'Red')
    }

    [void]LogNeutral([string]$Text) {
        $this.LogAction($Text, 'White')
    }

    [void]LogWarning([string]$Text) {
        $this.LogAction($Text, 'Yellow')
    }

    [void]LogAction([string]$Text,[string]$Color) {
        If (-not ($Color -in [enum]::GetValues([System.ConsoleColor]))) { $Color = 'White' }

        $This.ActionLog.Add([PSCustomObject]@{
            Text = $Text
            ForegroundColor = $Color
            TimeStamp = (Get-Date -Format '[yyyy-MM-dd HH:mm:ss]')
        })
    }
}

$ActionLogger = [ActionLogger]::new()


Function Get-FriendlySize() {
    Param(
        [Parameter(Mandatory=$true)]
        [int64]
        $ByteSize
    )
    
    Switch ($ByteSize) {
        {$_ -ge 1TB} {"{0:N2} TB" -f ($_/1TB); break}
        {$_ -ge 1GB} {"{0:N2} GB" -f ($_/1GB); break}
        {$_ -ge 1MB} {"{0:N2} MB" -f ($_/1MB); break}
        {$_ -ge 1KB} {"{0:N2} KB" -f ($_/1KB); break}
        Default {"{0:N2} bytes" -f $_}
    }
}

Function Get-FolderSize() {
    Param(
        [Parameter(Mandatory=$true)]
        [String]
        $Path,
        [Parameter(Mandatory=$false)]
        [Switch]
        $Friendly,
        [Parameter(Mandatory=$false)]
        [String[]]
        $Attributes
    )

    $Size = 0

    $GCI_Params = @{
        LiteralPath = $Path
        Recurse = $true
        Force = $true
        Attributes = $Attributes
        ErrorAction = 'SilentlyContinue'
    }
    
    foreach ($item in Get-ChildItem @GCI_Params | Where-Object { ! $_.PSIsContainer }) {
        $Size += ($item | Measure-Object -Sum Length -ErrorAction Stop).Sum
    }
    If ($Friendly.IsPresent) { Get-FriendlySize -ByteSize $Size } Else { $Size }
}

class DiskAnalyzer {
    [int64] $RecBinSize = -1
    [int64] $SDDSize = -1
    [int64] $LogFilesSize = -1
    [int64] $ntUninstallSize = -1
    [int64] $tempFilesSize = -1
    $sysDrive
    $WMI_OS
    [String] $RecBinDir
    [String] $osDisk
    [int64] $BeforeFreeSpace
    [String[]] $tempFolderPaths

    DiskAnalyzer() {
        $this.sysDrive = Get-WMIObject Win32_Logicaldisk -Filter "deviceid='$env:SystemDrive'"
        $this.BeforeFreeSpace = $this.sysDrive.FreeSpace
        $this.WMI_OS = Get-WmiObject -Class Win32_OperatingSystem
        $this.osDisk = $this.sysDrive.DeviceID
        $this.tempFolderPaths = @($env:temp, ($this.osDisk + "\temp"), "$env:SYSTEMROOT\temp")

        Switch ($this.WMI_OS.BuildNumber) 
        { 
            {[int]$_ -le 3790} {$this.RecBinDir = "RECYCLER"} 
            {[int]$_ -ge 6000} {$this.RecBinDir = "`$Recycle.Bin"} 
        }
    }

    [String] getOsDisk() {
        return $this.osDisk
    }

    [int64] getBeforeFreeSpace() {
        return $this.BeforeFreeSpace
    }

    [int64] getFreeSpace() {
        $this.sysDrive = Get-WMIObject Win32_Logicaldisk -Filter "deviceid='$env:SystemDrive'"
        return $this.sysDrive.FreeSpace
    }

    [int64] getDiskSize() {
        return $this.sysDrive.Size
    }

    [int64] getRecBinSize() {
        if ($this.RecBinSize -eq -1) {
            $this.updateRecBinSize()
        }
        return $this.RecBinSize
    }

    [int64] getSDDSize() {
        if ($this.SDDSize -eq -1) {
            $this.updateSDDSize()
        }
        return $this.SDDSize
    }

    [int64] getLogFilesSize() {
        if ($this.LogFilesSize -eq -1) {
            $this.updateLogFilesSize()
        }
        return $this.LogFilesSize
    }

    [int64] getNtUninstallSize() {
        if ($this.ntUninstallSize -eq -1) {
            $this.updateNtUninstallSize()
        }
        return $this.ntUninstallSize
    }

    [int64] getTempFilesSize() {
        if ($this.tempFilesSize -eq -1) {
            $this.updateTempFilesSize()
        }
        return $this.tempFilesSize
    }

    [int64] getTotalSize() {
        return $this.getRecBinSize() + 
               $this.getSDDSize() + 
               $this.getLogFilesSize() + 
               $this.getNtUninstallSize() + 
               $this.getTempFilesSize()
    }

    [String[]] getTempFolderPaths() {
        return $this.tempFolderPaths
    }

    [String] getRecBinDir() {
        return $this.RecBinDir
    }


    [void]updateRecBinSize() {
        $this.RecBinSize = (Get-FolderSize -Path ("{0}\{1}" -f $this.osDisk, $this.RecBinDir) -Attributes !Hidden, !System)
    }

    [void] updateSDDSize() {
        $this.SDDSize = Get-FolderSize -Path "$env:SYSTEMROOT\SoftwareDistribution\Download" -Attributes !System, !Hidden
    }

    [void] updateLogFilesSize() {
        $this.LogFilesSize = Get-FolderSize -Path "$env:SYSTEMROOT\system32\LogFiles" -Attributes !System, !Hidden
    }

    [void] updateNtUninstallSize() {
        $ntUnInstallFolders = (Get-ChildItem -Path $env:SYSTEMROOT -Directory -Filter "`$NtUninstall*$")
        $totalNtSize = 0
        $this.ntUninstallSize = 0

        foreach ($dir in $ntUnInstallFolders) {
            $totalNtSize += Get-FolderSize -Path $dir.FullName
        }

        if ($totalNtSize -gt 0) {
            foreach ($dir in $ntUnInstallFolders | Where-Object {($_.LastWriteTime -lt (Get-Date).AddDays(-$MaxAgeUpdates))}) {
                $this.ntUninstallSize += Get-FolderSize -Path $dir.FullName
            }
        }
    }

    [void] updateTempFilesSize() {
        $Size = 0
        foreach ($Folder in $this.tempFolderPaths) {
            $Size += Get-FolderSize -Path $Folder
        }
        $this.tempFilesSize = $size
    }

}

$DiskAnalyzer = [DiskAnalyzer]::new()


Function Clear-OSDiskRecycleBin()  {

    $Text = 'Empty Recycle Bin: '
    try {
        $recBinSize = $DiskAnalyzer.getRecBinSize()
        Remove-Item -Path ("{0}\{1}\*" -f $DiskAnalyzer.getOsDisk(), $DiskAnalyzer.getRecBinDir()) -Recurse -Force
        $DiskAnalyzer.updateRecBinSize()
        $FreedSpace = ($recBinSize - $DiskAnalyzer.getRecBinSize())

        if ($FreedSpace -eq 0) {
            $Text += 'Already empty!'
            $ActionLogger.LogWarning($Text)
        } Else {
            $FreedSpaceFriendly = (Get-FriendlySize $FreedSpace)
            $Text += "Reclaimed $FreedSpaceFriendly."
            $ActionLogger.LogSuccess($Text)    
        }
    } catch {
        $Text += $_.Exception.Message
        $ActionLogger.LogError($Text)
    }
}

Function Remove-LogFiles() {
    try {
        $InitialSize = $DataAnalyzer.getLogFilesSize()
        Get-ChildItem -Path "$env:SYSTEMROOT\system32\LogFiles" | Where-Object {($_.LastWriteTime -lt (Get-Date).AddDays(-$MaxAgeLogs))} | Remove-Item -ErrorAction SilentlyContinue -Recurse -Force
        $DataAnalyzer.updateLogFilesSize()
        $FreedSpace = ($InitialSize - $DataAnalyzer.getLogFilesSize())

        If ($FreedSpace -eq 0) {
            $Text += 'Nothing was deleted.'
            $ActionLogger.LogWarning($Text)
        } Else {
            $FreedSpaceFriendly = (Get-FriendlySize $FreedSpace)
            $Text += "Reclaimed $FreedSpaceFriendly."
            $ActionLogger.LogSuccess($Text)
        }
    } catch {
        $Text += $_.Exception.Message
        $ActionLogger.LogSuccess($Text)
    }
}

Function Remove-NtUninstallFiles() {
    $Text = '$NtUninstall*$ cleanup: '
    try {
        $InitialSize = $DiskAnalyzer.getNtUninstallSize()
        foreach ($dir in (Get-ChildItem -Path $env:SYSTEMROOT -Directory -Filter "$NtUpdate*$") | Where-Object {($_.LastWriteTime -lt (Get-Date).AddDays(-$MaxAgeUpdates))}) {
            Remove-Item -Path $dir.FullName -Force -ErrorAction SilentlyContinue
        }
        $DiskAnalyzer.updateNtUninstallSize()
        $FreedSpace = ($InitialSize - $DiskAnalyzer.getNtUninstallSize())

        if ($FreedSpace -eq 0) {
            $Text += 'No folders were deleted.'
            $ActionLogger.LogWarning($Text)
        } Else {
            $FreedSpaceFriendly = (Get-FriendlySize $FreedSpace)
            $Text += "Reclaimed $FreedSpaceFriendly."
            $ActionLogger.LogSuccess($Text)    
        }
    } catch {
        $Text += $_.Exception.Message
        $ActionLogger.LogError($Text)
    }
}

Function Remove-SDDFiles() {
    $Text = 'SoftwareDistribution\Download cleanup: '
    try {
        $InitialSize = $DiskAnalyzer.getSDDSize()
        Remove-Item "$env:SYSTEMROOT\SoftwareDistribution\Download" -Recurse -Force
        $DiskAnalyzer.updateSDDSize()
        $FreedSpace = ($InitialSize - $DiskAnalyzer.getSDDSize())

        if ($FreedSpace -eq 0) {
            $Text += 'No files were deleted.'
            $ActionLogger.LogWarning($Text)
        } Else {
            $FreedSpaceFriendly = (Get-FriendlySize $FreedSpace)
            $Text += "Reclaimed $FreedSpaceFriendly."
            $ActionLogger.LogSuccess($Text)    
        }
    } catch {
        $Text += $_.Exception.Message
        $ActionLogger.LogError($Text)
    }
}

Function Remove-TempFiles() {
    $Text = 'Temp file removal: '
    try {
        $TempFolders = $DiskAnalyzer.getTempFolderPaths()
        $SizeBefore = 0
        $SizeAfter = 0

        foreach ($Folder in $TempFolders) {
            $SizeBefore += Get-FolderSize -Path $Folder
            foreach ($file in (Get-ChildItem -Path $Folder -Recurse | Where-Object { ! $_.PSIsContainer })) {
                $Size = $_.Length
                try {
                    Remove-Item -Path $file.FullName
                    $total += $size
                } Catch {}
            }
        }
    
        foreach ($Folder in $TempFolders) {
            $SizeAfter += Get-FolderSize -Path $Folder
        }
        

        $FreedSpace = ($SizeBefore-$SizeAfter)
        if ($FreedSpace -gt 0) {
            $Text += "Reclaimed {0}" -f (Get-FriendlySize $FreedSpace)
            $ActionLogger.LogSuccess($Text)
        } else {
            $Text += 'No files were removed.'
            $ActionLogger.LogWarning($Text)
        }
    } catch {
        $Text += $_.Exception.Message
        $ActionLogger.LogError($Text)
    }

}

Function Invoke-AllActions() {
    Clear-OSDiskRecycleBin
    Remove-LogFiles
    Remove-NtUninstallFiles
    Remove-SDDFiles
    Remove-TempFiles
}

Function Show-ActionMenu {
    Write-Host `n"================ Actions ================"`n -ForegroundColor Yellow
    Write-Host ('1. Empty Recycle Bin ({0})' -f (Get-FriendlySize -ByteSize $DiskAnalyzer.getRecBinSize()))
    Write-Host ("2. Delete old (>= $MaxAgeLogs days) log files ({0})" -f (Get-FriendlySize -ByteSize $DiskAnalyzer.getLogFilesSize()))
    Write-Host ("3. Delete old (>= $MaxAgeUpdates dager) `$NtUninstall*`$-files ({0})" -f (Get-FriendlySize -ByteSize $DiskAnalyzer.getNtUninstallSize()))
    Write-Host ("4. Empty folder SoftwareDistribution\Download ({0})" -f (Get-FriendlySize -ByteSize $DiskAnalyzer.getSDDSize()))
    Write-Host ("5. Delete temp files ({0})" -f (Get-FriendlySize $DiskAnalyzer.getTempFilesSize()))
    Write-Host ("6. Perform all actions ({0})" -f (Get-FriendlySize $DiskAnalyzer.getTotalSize()))`n
    Write-Host Press Enter to quit.`n
}

Do {
    Clear-Host
    $ActionLogger.ShowLog()
    Show-ActionMenu
    $Choice = Read-Host "Your choice"
    
    Switch($Choice) {
        '1' { Clear-OSDiskRecycleBin }
        '2' { Remove-LogFiles }
        '3' { Remove-NtUninstallFiles }
        '4' { Remove-SDDFiles }
        '5' { Remove-TempFiles }
        '6' { Invoke-AllActions }
    }

} Until ($Choice -eq '')

Clear-Host
$ActionLogger.ShowLog()
$BeforeFreeSpace = $DiskAnalyzer.getBeforeFreeSpace()
$AfterFreeSpace = $DiskAnalyzer.getFreeSpace()
$DiskSize = $DiskAnalyzer.getDiskSize()
$PctBefore = ($BeforeFreeSpace / $DiskSize)*100
$PctAfter = ($AfterFreeSpace / $DiskSize)*100


Write-Host `n"================ Summary ================" -ForegroundColor Yellow
Write-Host `n • Free space before:`t (Get-FriendlySize $BeforeFreeSpace)/(Get-FriendlySize $DiskAnalyzer.getDiskSize()) ("({0:N1}%)" -f $PctBefore)
Write-Host `n • Free space after:`t (Get-FriendlySize $AfterFreeSpace)/(Get-FriendlySize $DiskSize) ("({0:N1}%)" -f $PctAfter)
Write-Host `n • Reclaimed space:`t`t (Get-FriendlySize ([math]::max(($AfterFreeSpace-$BeforeFreeSpace), 0)))


If ([System.IO.File]::Exists("$env:SYSTEMROOT\system32\cleanmgr.exe")) {
    $RunCleanMgr = Read-Host "`nRun Disk Cleaner? (Y/N)"
    if ($RunCleanMgr.ToLower() -eq 'y') { cleanmgr.exe }
}