<#
.SYNOPSIS
    GCS Bucket Mounting Tool
.DESCRIPTION
    A lightweight WPF tool to manage and auto-mount multiple GCS buckets.
    - FETCH FIX: Intercepts blank Project IDs during Fetch and prompts the user, preventing GCS API rejection errors.
    - AUTH FIX: Direct execution of rclone via Start-Process ensures browser launch.
    - PORT FIX: 'Zombie Killer' terminates stuck rclone processes holding port 53682.
    - PERSISTENCE: Auto-resumes auth state on boot so users only log in once.
    - PERFORMANCE: Adds configurable rclone concurrency, buffering, read-ahead, and chunked read tuning.
    - DELETE CLEANUP: Prunes empty Cloud Console folder records after mounted-drive file and folder deletes.
    - UI FIX: Updated button texts to "New" and "Delete", and heading to "Connection Settings". Removed (Gold) from title.
    - VALIDATION: Strict gatekeeper checks bucket access before attempting to mount.
    - ENCODING FIX: Compiler-safe strings (no emojis).
#>
param (
    [switch]$AutoMount
)

# --- 1. Load Assemblies ---
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing 

# --- 2. Silent Process Wrapper (Prevents .EXE Compiler Popups) ---
function Invoke-SilentProcess {
    param([string]$ExePath, [string]$ArgList)
    
    $tOut = [System.IO.Path]::GetTempFileName()
    $tErr = [System.IO.Path]::GetTempFileName()
    
    $proc = Start-Process -FilePath $ExePath -ArgumentList $ArgList -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $tOut -RedirectStandardError $tErr
    
    Start-Sleep -Milliseconds 100
    
    $outText = Get-Content $tOut -Raw -ErrorAction SilentlyContinue
    $errText = Get-Content $tErr -Raw -ErrorAction SilentlyContinue
    
    Remove-Item $tOut, $tErr -Force -ErrorAction SilentlyContinue
    
    return [PSCustomObject]@{ ExitCode = $proc.ExitCode; Output = $outText; Error = $errText }
}

# --- 3. Configuration Management ---
$configPath = "$env:APPDATA\GCSMountApp"
$configFile = "$configPath\settings_multi.json"
$global:logPath = "$configPath\rclone.log"
$startupFolder = [Environment]::GetFolderPath('Startup')
$shortcutPath = "$startupFolder\GCSMultiMount.lnk"
$global:IsAuthenticated = $false
$global:FolderDeleteWatchers = @{}
$global:ConsoleRootReconcileIntervalMs = 15000

if (-not (Test-Path $configPath)) { New-Item -ItemType Directory -Path $configPath | Out-Null }

function Get-DefaultGlobalConfig {
    return [ordered]@{
        RclonePath = ""
        WinFspPath = ""
        CacheDir = "C:\RcloneCache"
        CacheMaxSize = "20"
        CacheMaxAge = "1"
        TransferCount = "8"
        CheckerCount = "16"
        BufferSizeMb = "64"
        ReadAheadMb = "256"
        MultiThreadStreams = "4"
        ChunkSizeMb = "64"
    }
}

function New-DefaultAppConfig {
    $globalDefaults = Get-DefaultGlobalConfig
    return [PSCustomObject]@{ Global = [PSCustomObject]$globalDefaults; Mounts = @() }
}

function Ensure-ConfigDefaults($Config) {
    if (-not $Config) { return New-DefaultAppConfig }

    $globalDefaults = Get-DefaultGlobalConfig
    if ($null -eq $Config.Global) {
        $Config | Add-Member -NotePropertyName Global -NotePropertyValue ([PSCustomObject]$globalDefaults) -Force
    }

    foreach ($key in $globalDefaults.Keys) {
        if ($null -eq $Config.Global.PSObject.Properties[$key]) {
            $Config.Global | Add-Member -NotePropertyName $key -NotePropertyValue $globalDefaults[$key]
        } elseif ([string]::IsNullOrWhiteSpace([string]$Config.Global.$key) -and -not [string]::IsNullOrWhiteSpace([string]$globalDefaults[$key])) {
            $Config.Global.$key = $globalDefaults[$key]
        }
    }

    if ($null -eq $Config.Mounts) { $Config | Add-Member -NotePropertyName Mounts -NotePropertyValue @() -Force }
    $Config.Mounts = @($Config.Mounts)
    return $Config
}

function Get-GlobalConfigValue($Name) {
    $globalDefaults = Get-DefaultGlobalConfig
    $value = $global:appConfig.Global.$Name
    if ([string]::IsNullOrWhiteSpace([string]$value)) { return [string]$globalDefaults[$Name] }
    return [string]$value
}

function Set-GlobalConfigValue($Name, $Value) {
    if ($null -eq $global:appConfig.Global.PSObject.Properties[$Name]) {
        $global:appConfig.Global | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $global:appConfig.Global.$Name = $Value
    }
}

function Convert-ToPositiveIntegerText {
    param(
        [object]$Value,
        [string]$Default,
        [int]$Minimum = 1,
        [int]$Maximum = 1024
    )

    $text = ([string]$Value).Trim()
    [int]$parsed = 0
    if ([int]::TryParse($text, [ref]$parsed) -and $parsed -ge $Minimum) {
        if ($parsed -gt $Maximum) { $parsed = $Maximum }
        return [string]$parsed
    }

    return $Default
}

function Load-Config {
    if (Test-Path $configFile) {
        try {
            $json = Get-Content $configFile -Raw | ConvertFrom-Json
            if ($null -eq $json.Mounts) { return New-DefaultAppConfig }
            return Ensure-ConfigDefaults $json
        } catch { }
    }
    return New-DefaultAppConfig
}

function Save-Config {
    $global:appConfig | ConvertTo-Json -Depth 4 | Set-Content $configFile
}

$global:appConfig = Load-Config
$global:CurrentEditId = "NEW"

# --- 4. Core System Functions ---
function Get-MountLogPath($DriveLetter) {
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return $global:logPath }
    $letter = $DriveLetter.Trim().TrimEnd(':').ToUpperInvariant()
    return "$configPath\rclone_$letter.log"
}

function Get-RcloneExe {
    $rExe = $global:appConfig.Global.RclonePath
    $envPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ($rExe) { $envPath += ";$rExe" }
    $env:Path = $envPath

    $rCmd = if (Get-Command "rclone.exe" -ErrorAction SilentlyContinue) { (Get-Command "rclone.exe").Source } elseif (Test-Path "$rExe\rclone.exe") { "$rExe\rclone.exe" } else { $null }
    return $rCmd
}

function Get-MountPID($DriveLetter) {
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return $null }
    $procs = Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($p in $procs) {
            if ($p.CommandLine -match "(?i)\s$DriveLetter\s") { return $p.ProcessId }
        }
    }
    return $null
}

function Get-RcloneRcPort($DriveLetter) {
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return 5572 }
    $letter = $DriveLetter.Trim().TrimEnd(':').ToUpperInvariant()
    if ($letter.Length -ne 1) { return 5572 }
    return 5572 + ([int][char]$letter - [int][char]'A')
}

function Get-GcloudExe {
    $gCmd = Get-Command "gcloud.cmd" -ErrorAction SilentlyContinue
    if ($gCmd) { return $gCmd.Source }

    $gPs = Get-Command "gcloud.ps1" -ErrorAction SilentlyContinue
    if ($gPs) { return $gPs.Source }

    return $null
}

function Normalize-GcsFolderPath($PathText) {
    if ([string]::IsNullOrWhiteSpace($PathText)) { return "" }

    $path = $PathText.Trim().Replace('\', '/')
    $path = $path -replace '^gs://[^/]+/', ''
    $path = $path.Trim('/')

    if ([string]::IsNullOrWhiteSpace($path)) { return "" }
    return "$path/"
}

function Get-GcsParentFolderPath($PathText) {
    if ([string]::IsNullOrWhiteSpace($PathText)) { return "" }

    $path = $PathText.Trim().Replace('\', '/')
    $path = $path -replace '^gs://[^/]+/', ''
    $path = $path.Trim('/')
    if ([string]::IsNullOrWhiteSpace($path)) { return "" }

    $lastSlash = $path.LastIndexOf('/')
    if ($lastSlash -lt 0) { return "" }

    return Normalize-GcsFolderPath $path.Substring(0, $lastSlash)
}

function Get-GcsCompatibilityArgs {
    return "--gcs-bucket-policy-only --gcs-directory-markers --gcs-object-acl="
}

function Convert-MountPathToBucketRelativePath($MountConfig, $SelectedPath) {
    if (-not $MountConfig -or [string]::IsNullOrWhiteSpace($SelectedPath)) {
        return [PSCustomObject]@{ Success = $false; Path = ""; Message = "No folder was selected." }
    }

    $driveRoot = "$($MountConfig.DriveLetter.TrimEnd(':')):\"
    $selectedFullPath = [System.IO.Path]::GetFullPath($SelectedPath)
    $driveFullPath = [System.IO.Path]::GetFullPath($driveRoot)

    if (-not $selectedFullPath.StartsWith($driveFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{ Success = $false; Path = ""; Message = "Select a folder from the mounted drive $($MountConfig.DriveLetter)." }
    }

    $relativePath = $selectedFullPath.Substring($driveFullPath.Length).Trim('\', '/')
    $relativePath = $relativePath.Replace('\', '/')
    return [PSCustomObject]@{ Success = $true; Path = $relativePath; Message = "" }
}

function Select-RefreshParentFolder($MountConfig) {
    if (-not $MountConfig -or [string]::IsNullOrWhiteSpace($MountConfig.DriveLetter)) {
        return [PSCustomObject]@{ Success = $false; Cancelled = $false; Path = ""; Message = "No mounted drive was selected." }
    }

    $driveRoot = "$($MountConfig.DriveLetter.TrimEnd(':')):\"
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select the parent folder to scan for Google Console folders that are missing from File Explorer."
    $dialog.ShowNewFolderButton = $false
    $dialog.RootFolder = [System.Environment+SpecialFolder]::MyComputer
    if (Test-Path $driveRoot) { $dialog.SelectedPath = $driveRoot }

    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return [PSCustomObject]@{ Success = $false; Cancelled = $true; Path = ""; Message = "" }
    }

    $converted = Convert-MountPathToBucketRelativePath $MountConfig $dialog.SelectedPath
    return [PSCustomObject]@{ Success = $converted.Success; Cancelled = $false; Path = $converted.Path; Message = $converted.Message }
}

function Stop-ConsoleFolderDeleteWatcher($DriveLetter) {
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return }
    $key = $DriveLetter.Trim().ToUpperInvariant()
    if (-not $global:FolderDeleteWatchers.ContainsKey($key)) { return }

    $entry = $global:FolderDeleteWatchers[$key]
    try {
        foreach ($subscription in @($entry.Subscription, $entry.DriveSubscription, $entry.LogSubscription, $entry.RootReconcileSubscription)) {
            if ($subscription) {
                Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
                Remove-Job -Id $subscription.Id -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }

    try {
        foreach ($watcher in @($entry.Watcher, $entry.DriveWatcher, $entry.LogWatcher, $entry.RootReconcileTimer)) {
            if ($watcher) {
                if ($watcher -is [System.Windows.Threading.DispatcherTimer]) {
                    $watcher.Stop()
                } elseif ($watcher -is [System.Threading.Timer]) {
                    $watcher.Dispose()
                } elseif ($watcher -is [System.Timers.Timer]) {
                    $watcher.Stop()
                    $watcher.Dispose()
                } else {
                    $watcher.EnableRaisingEvents = $false
                    $watcher.Dispose()
                }
            }
        }
    } catch { }

    try {
        if ($entry.RootReconcileProcess -and -not $entry.RootReconcileProcess.HasExited) {
            Stop-Process -Id $entry.RootReconcileProcess.Id -Force -ErrorAction SilentlyContinue
        }
    } catch { }

    $global:FolderDeleteWatchers.Remove($key)
}

function Stop-AllConsoleFolderDeleteWatchers {
    foreach ($key in @($global:FolderDeleteWatchers.Keys)) {
        Stop-ConsoleFolderDeleteWatcher $key
    }
}

function Ensure-ConsoleFolderCleanupWorker {
    $workerPath = Join-Path $configPath "console_folder_cleanup_worker.ps1"
    $workerScript = @'
param(
    [Parameter(Mandatory=$true)][ValidateSet("Folder","File","ReconcileRoot")][string]$Mode,
    [Parameter(Mandatory=$true)][string]$GcloudPath,
    [Parameter(Mandatory=$true)][string]$BucketName,
    [string]$ProjectId = "",
    [Parameter(Mandatory=$true)][string]$LogPath,
    [string]$RelativePath = "",
    [string]$DriveRoot = ""
)

function Write-CleanupLog($Level, $Message) {
    Add-Content -Path $LogPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') $Level : $Message" -ErrorAction SilentlyContinue
}

function Normalize-GcsFolderPath($PathText) {
    if ([string]::IsNullOrWhiteSpace($PathText)) { return "" }
    $path = $PathText.Trim().Replace('\', '/')
    $path = $path -replace '^gs://[^/]+/', ''
    $path = $path.Trim('/')
    if ([string]::IsNullOrWhiteSpace($path)) { return "" }
    return "$path/"
}

function Get-GcsParentFolderPath($PathText) {
    if ([string]::IsNullOrWhiteSpace($PathText)) { return "" }
    $path = $PathText.Trim().Replace('\', '/')
    $path = $path -replace '^gs://[^/]+/', ''
    $path = $path.Trim('/')
    if ([string]::IsNullOrWhiteSpace($path)) { return "" }
    $lastSlash = $path.LastIndexOf('/')
    if ($lastSlash -lt 0) { return "" }
    return Normalize-GcsFolderPath $path.Substring(0, $lastSlash)
}

function Invoke-GcloudStorageCommandWithRetry {
    param(
        [string]$StepName,
        [string]$CommandArgs,
        [bool]$LogFailure = $true
    )

    $notFoundPattern = "(?i)(not found|matched no|no urls matched|does not exist|404)"
    $combinedText = ""

    foreach ($attempt in 1..3) {
        $tmpOut = [System.IO.Path]::GetTempFileName()
        $tmpErr = [System.IO.Path]::GetTempFileName()
        try {
            $proc = Start-Process -FilePath $GcloudPath -ArgumentList $CommandArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
            if (-not $proc.WaitForExit(60000)) {
                try { $proc.Kill() } catch { }
                $combinedText = "Timed out after 60 seconds while running: $CommandArgs"
                if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
                continue
            }

            $outText = Get-Content $tmpOut -Raw -ErrorAction SilentlyContinue
            $errText = Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue
            $combinedText = "$errText`n$outText"

            if ($proc.ExitCode -eq 0) {
                return [PSCustomObject]@{ Success = $true; NotFound = $false; Output = $outText; Error = $errText; Text = $combinedText }
            }

            if ($combinedText -match $notFoundPattern) {
                return [PSCustomObject]@{ Success = $true; NotFound = $true; Output = $outText; Error = $errText; Text = $combinedText }
            }

            if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
        } catch {
            $combinedText = "$_"
            if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
        } finally {
            Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
        }
    }

    if ($LogFailure) { Write-CleanupLog "WARN " "Failed $StepName : $combinedText" }
    return [PSCustomObject]@{ Success = $false; NotFound = $false; Output = ""; Error = $combinedText; Text = $combinedText }
}

function Get-ConsoleFolderChildren($FolderPath) {
    $folderPath = Normalize-GcsFolderPath $FolderPath
    if ([string]::IsNullOrWhiteSpace($folderPath)) { return @() }

    $folderUrl = "gs://$BucketName/$folderPath"
    $projectArg = if ([string]::IsNullOrWhiteSpace($ProjectId)) { "" } else { " --project `"$ProjectId`"" }
    $res = Invoke-GcloudStorageCommandWithRetry "listing Console child folders for $folderUrl" "storage folders list `"$folderUrl`" --format `"value(uri())`" --quiet$projectArg" $false
    if (-not $res.Success -or $res.NotFound) { return @() }

    $children = @()
    foreach ($line in ($res.Output -split "\r?\n")) {
        $folder = Normalize-GcsFolderPath $line
        if ([string]::IsNullOrWhiteSpace($folder) -or $folder -eq $folderPath) { continue }
        $children += $folder
    }
    return @($children | Sort-Object -Unique)
}

function Get-ConsoleRootFolderRecords {
    $projectArg = if ([string]::IsNullOrWhiteSpace($ProjectId)) { "" } else { " --project `"$ProjectId`"" }
    $bucketRootUrl = "gs://$BucketName/"
    $rootFolders = @()

    $res = Invoke-GcloudStorageCommandWithRetry "listing Console root folders for $bucketRootUrl" "storage ls `"$bucketRootUrl`" --quiet$projectArg" $false
    $listingText = "$($res.Output)`n$($res.Error)"
    if ([string]::IsNullOrWhiteSpace($listingText)) { $listingText = $res.Text }

    foreach ($line in ($listingText -split "\r?\n")) {
        $entry = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($entry) -or $entry -notmatch '^gs://' -or -not $entry.EndsWith('/')) { continue }

        $folder = Normalize-GcsFolderPath $entry
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }

        $folderName = $folder.TrimEnd('/')
        if ($folderName.Contains('/')) { continue }
        $rootFolders += $folder
    }

    if ($rootFolders.Count -gt 0) {
        return @($rootFolders | Sort-Object -Unique)
    }

    if (-not $res.Success) {
        $detail = (($res.Text -replace "\s+", " ").Trim())
        if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) }
        Write-CleanupLog "WARN " "Root folder reconcile could not list Console root for $bucketRootUrl : $detail"
        return @()
    }

    if ($res.NotFound) { return @() }

    return @($rootFolders | Sort-Object -Unique)
}

function Test-ConsoleFolderHasCloudChildren($FolderPath) {
    $folderPath = Normalize-GcsFolderPath $FolderPath
    if ([string]::IsNullOrWhiteSpace($folderPath)) { return $true }

    $folderUrl = "gs://$BucketName/$folderPath"
    $folderKey = $folderUrl.TrimEnd('/')
    $projectArg = if ([string]::IsNullOrWhiteSpace($ProjectId)) { "" } else { " --project `"$ProjectId`"" }
    $res = Invoke-GcloudStorageCommandWithRetry "checking folder contents for $folderUrl" "storage ls `"$folderUrl**`" --quiet$projectArg"

    if (-not $res.Success) { return $true }
    if ($res.NotFound) { return $false }

    foreach ($line in ($res.Output -split "\r?\n")) {
        $entry = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($entry) -or $entry -notmatch '^gs://') { continue }
        if ($entry.TrimEnd('/') -eq $folderKey) { continue }
        return $true
    }
    return $false
}

function Invoke-ConsoleFolderDeleteCleanup {
    param(
        [string]$FolderPath,
        [bool]$DeleteContents = $true
    )

    $folderPath = Normalize-GcsFolderPath $FolderPath
    if ([string]::IsNullOrWhiteSpace($folderPath)) { return $false }

    $folderUrl = "gs://$BucketName/$folderPath"
    $projectArg = if ([string]::IsNullOrWhiteSpace($ProjectId)) { "" } else { " --project `"$ProjectId`"" }
    $allStepsComplete = $true

    if ($DeleteContents) {
        $contentRes = Invoke-GcloudStorageCommandWithRetry "deleting remaining folder contents for $folderUrl" "storage rm `"$folderUrl**`" --recursive --continue-on-error --quiet$projectArg"
        if (-not $contentRes.Success) { $allStepsComplete = $false }

        foreach ($childFolder in @(Get-ConsoleFolderChildren $folderPath)) {
            Invoke-ConsoleFolderDeleteCleanup $childFolder $false | Out-Null
        }
    }

    foreach ($command in @(
        [PSCustomObject]@{ Name = "folder marker"; Args = "storage rm `"$folderUrl`" --quiet$projectArg" },
        [PSCustomObject]@{ Name = "Console folder record"; Args = "storage folders delete `"$folderUrl`" --quiet$projectArg" }
    )) {
        $res = Invoke-GcloudStorageCommandWithRetry "deleting $($command.Name) for $folderUrl" $command.Args
        if (-not $res.Success) { $allStepsComplete = $false }
    }

    Write-CleanupLog "INFO " "Console folder delete checked: $folderUrl"
    return $allStepsComplete
}

function Invoke-ConsoleFolderPruneEmptyParents($FolderPath) {
    $folderPath = Normalize-GcsFolderPath $FolderPath
    while (-not [string]::IsNullOrWhiteSpace($folderPath)) {
        if (Test-ConsoleFolderHasCloudChildren $folderPath) {
            Write-CleanupLog "INFO " "Console folder prune stopped at non-empty folder: gs://$BucketName/$folderPath"
            break
        }

        $deleted = Invoke-ConsoleFolderDeleteCleanup $folderPath $false
        if (-not $deleted) { break }

        Write-CleanupLog "INFO " "Empty Console folder pruned: gs://$BucketName/$folderPath"
        $folderPath = Get-GcsParentFolderPath $folderPath
    }
}

function Invoke-ConsoleRootFolderReconcile {
    if ([string]::IsNullOrWhiteSpace($DriveRoot) -or -not (Test-Path $DriveRoot)) {
        Write-CleanupLog "WARN " "Root folder reconcile skipped because mounted drive is unavailable: $DriveRoot"
        return
    }

    $mountedRootFolders = @{}
    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $DriveRoot -Directory -Force -ErrorAction Stop)) {
            $mountedRootFolders[$item.Name] = $true
        }
    } catch {
        Write-CleanupLog "WARN " "Root folder reconcile could not read mounted drive $DriveRoot : $_"
        return
    }

    $checked = 0
    $deleted = 0
    $consoleRootFolders = @(Get-ConsoleRootFolderRecords)
    foreach ($folder in $consoleRootFolders) {
        $name = $folder.TrimEnd('/')
        if ($mountedRootFolders.ContainsKey($name)) { continue }

        $checked++
        if (Test-ConsoleFolderHasCloudChildren $folder) {
            Write-CleanupLog "INFO " "Root reconcile kept non-empty Console-only folder: gs://$BucketName/$folder"
            continue
        }

        if (Invoke-ConsoleFolderDeleteCleanup $folder $true) {
            $deleted++
            Write-CleanupLog "INFO " "Root reconcile pruned Console-only empty folder: gs://$BucketName/$folder"
        }
    }

    Write-CleanupLog "INFO " "Root folder reconcile completed for gs://$BucketName/ (console=$($consoleRootFolders.Count), mounted=$($mountedRootFolders.Count), checked=$checked, deleted=$deleted)"
}

Start-Sleep -Seconds 3
if ($Mode -eq "ReconcileRoot") {
    Invoke-ConsoleRootFolderReconcile
} elseif ($Mode -eq "Folder") {
    $folderPath = Normalize-GcsFolderPath $RelativePath
    if (-not [string]::IsNullOrWhiteSpace($folderPath)) {
        Invoke-ConsoleFolderDeleteCleanup $folderPath $true | Out-Null
        Invoke-ConsoleFolderPruneEmptyParents (Get-GcsParentFolderPath $folderPath)
    }
} else {
    Invoke-ConsoleFolderPruneEmptyParents (Get-GcsParentFolderPath $RelativePath)
}
'@

    Set-Content -LiteralPath $workerPath -Value $workerScript -Encoding UTF8
    return $workerPath
}

function Ensure-ConsoleFolderRootReconcileScheduler {
    $schedulerPath = Join-Path $configPath "console_folder_root_reconcile_scheduler.ps1"
    $schedulerScript = @'
param(
    [Parameter(Mandatory=$true)][string]$WorkerPath,
    [Parameter(Mandatory=$true)][string]$GcloudPath,
    [Parameter(Mandatory=$true)][string]$BucketName,
    [string]$ProjectId = "",
    [Parameter(Mandatory=$true)][string]$LogPath,
    [Parameter(Mandatory=$true)][string]$DriveRoot,
    [int]$IntervalMs = 15000
)

while ($true) {
    Start-Sleep -Milliseconds $IntervalMs
    try {
        & $WorkerPath -Mode ReconcileRoot -GcloudPath $GcloudPath -BucketName $BucketName -ProjectId $ProjectId -LogPath $LogPath -DriveRoot $DriveRoot
    } catch {
        Add-Content -Path $LogPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') WARN  : Root folder reconcile scheduler failed for gs://$BucketName/ : $_" -ErrorAction SilentlyContinue
    }
}
'@

    Set-Content -LiteralPath $schedulerPath -Value $schedulerScript -Encoding UTF8
    return $schedulerPath
}

function Start-ConsoleFolderCleanupProcess($EventData, $RelativePath, $Mode) {
    if (-not $EventData -or [string]::IsNullOrWhiteSpace($RelativePath) -or [string]::IsNullOrWhiteSpace($Mode)) { return }

    $workerPath = $EventData.WorkerPath
    if ([string]::IsNullOrWhiteSpace($workerPath) -or -not (Test-Path $workerPath)) { return }

    $powerShellExe = (Get-Command "powershell.exe" -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($powerShellExe)) { return }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$workerPath`"",
        "-Mode", $Mode,
        "-GcloudPath", "`"$($EventData.GcloudPath)`"",
        "-BucketName", "`"$($EventData.BucketName)`"",
        "-ProjectId", "`"$($EventData.ProjectId)`"",
        "-LogPath", "`"$($EventData.LogPath)`"",
        "-RelativePath", "`"$RelativePath`""
    ) -join " "

    try {
        Start-Process -FilePath $powerShellExe -ArgumentList $arguments -WindowStyle Hidden | Out-Null
        Add-Content -Path $EventData.LogPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') INFO  : Console folder cleanup queued ($Mode): gs://$($EventData.BucketName)/$RelativePath" -ErrorAction SilentlyContinue
    } catch {
        Add-Content -Path $EventData.LogPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') WARN  : Failed to queue Console folder cleanup for $RelativePath : $_" -ErrorAction SilentlyContinue
    }
}

function Start-ConsoleFolderRootReconcileProcess($EventData) {
    if (-not $EventData) { return }

    $workerPath = $EventData.WorkerPath
    if ([string]::IsNullOrWhiteSpace($workerPath) -or -not (Test-Path $workerPath)) { return }

    $powerShellExe = (Get-Command "powershell.exe" -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($powerShellExe)) { return }

    # Use forward slashes so a drive root like Q:\ does not escape the closing quote
    # when passed through Start-Process ArgumentList.
    $driveRootArg = ([string]$EventData.DriveRoot).Replace('\', '/')

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$workerPath`"",
        "-Mode", "ReconcileRoot",
        "-GcloudPath", "`"$($EventData.GcloudPath)`"",
        "-BucketName", "`"$($EventData.BucketName)`"",
        "-ProjectId", "`"$($EventData.ProjectId)`"",
        "-LogPath", "`"$($EventData.LogPath)`"",
        "-DriveRoot", "`"$driveRootArg`""
    ) -join " "

    try {
        Start-Process -FilePath $powerShellExe -ArgumentList $arguments -WindowStyle Hidden | Out-Null
        Add-Content -Path $EventData.LogPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') INFO  : Console root folder reconcile queued: gs://$($EventData.BucketName)/" -ErrorAction SilentlyContinue
    } catch {
        Add-Content -Path $EventData.LogPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') WARN  : Failed to queue Console root folder reconcile for $($EventData.BucketName) : $_" -ErrorAction SilentlyContinue
    }
}

function Invoke-GcloudStorageCommandWithRetry {
    param(
        [object]$EventData,
        [string]$StepName,
        [string]$CommandArgs,
        [bool]$LogFailure = $true
    )

    $notFoundPattern = "(?i)(not found|matched no|no urls matched|does not exist|404)"
    $combinedText = ""

    foreach ($attempt in 1..3) {
        $tmpOut = [System.IO.Path]::GetTempFileName()
        $tmpErr = [System.IO.Path]::GetTempFileName()
        try {
            $proc = Start-Process -FilePath $EventData.GcloudPath -ArgumentList $CommandArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
            if (-not $proc.WaitForExit(60000)) {
                try { $proc.Kill() } catch { }
                $combinedText = "Timed out after 60 seconds while running: $CommandArgs"
                if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
                continue
            }

            $outText = Get-Content $tmpOut -Raw -ErrorAction SilentlyContinue
            $errText = Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue
            $combinedText = "$errText`n$outText"

            if ($proc.ExitCode -eq 0) {
                return [PSCustomObject]@{ Success = $true; NotFound = $false; Output = $outText; Error = $errText; Text = $combinedText }
            }

            if ($combinedText -match $notFoundPattern) {
                return [PSCustomObject]@{ Success = $true; NotFound = $true; Output = $outText; Error = $errText; Text = $combinedText }
            }

            if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
        } catch {
            $combinedText = "$_"
            if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
        } finally {
            Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
        }
    }

    if ($LogFailure) {
        Add-Content -Path $EventData.LogPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') WARN  : Failed $StepName : $combinedText" -ErrorAction SilentlyContinue
    }
    return [PSCustomObject]@{ Success = $false; NotFound = $false; Output = ""; Error = $combinedText; Text = $combinedText }
}

function Get-ConsoleFolderChildren($EventData, $RelativePath) {
    if (-not $EventData -or [string]::IsNullOrWhiteSpace($RelativePath)) { return @() }

    $relativePath = Normalize-GcsFolderPath $RelativePath
    if ([string]::IsNullOrWhiteSpace($relativePath)) { return @() }

    $folderUrl = "gs://$($EventData.BucketName)/$relativePath"
    $projectArg = if ([string]::IsNullOrWhiteSpace($EventData.ProjectId)) { "" } else { " --project `"$($EventData.ProjectId)`"" }
    $res = Invoke-GcloudStorageCommandWithRetry $EventData "listing Console child folders for $folderUrl" "storage folders list `"$folderUrl`" --format `"value(uri())`" --quiet$projectArg" $false
    if (-not $res.Success -or $res.NotFound) { return @() }

    $children = @()
    foreach ($line in ($res.Output -split "\r?\n")) {
        $folder = Normalize-GcsFolderPath $line
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        if ($folder -eq $relativePath) { continue }
        $children += $folder
    }

    return @($children | Sort-Object -Unique)
}

function Invoke-ConsoleChildFolderRecordDelete($EventData, $RelativePath) {
    if (-not $EventData -or [string]::IsNullOrWhiteSpace($RelativePath)) { return }

    $relativePath = Normalize-GcsFolderPath $RelativePath
    if ([string]::IsNullOrWhiteSpace($relativePath)) { return }

    foreach ($childFolder in @(Get-ConsoleFolderChildren $EventData $relativePath)) {
        Invoke-ConsoleChildFolderRecordDelete $EventData $childFolder
        Invoke-ConsoleFolderDeleteCleanup $EventData $childFolder $false | Out-Null
    }
}

function Test-ConsoleFolderHasCloudChildren($EventData, $RelativePath) {
    if (-not $EventData -or [string]::IsNullOrWhiteSpace($RelativePath)) { return $true }

    $relativePath = Normalize-GcsFolderPath $RelativePath
    if ([string]::IsNullOrWhiteSpace($relativePath)) { return $true }

    $folderUrl = "gs://$($EventData.BucketName)/$relativePath"
    $folderKey = $folderUrl.TrimEnd('/')
    $projectArg = if ([string]::IsNullOrWhiteSpace($EventData.ProjectId)) { "" } else { " --project `"$($EventData.ProjectId)`"" }
    $res = Invoke-GcloudStorageCommandWithRetry $EventData "checking folder contents for $folderUrl" "storage ls `"$folderUrl**`" --quiet$projectArg"

    if (-not $res.Success) { return $true }
    if ($res.NotFound) { return $false }

    foreach ($line in ($res.Output -split "\r?\n")) {
        $entry = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($entry) -or $entry -notmatch '^gs://') { continue }
        if ($entry.TrimEnd('/') -eq $folderKey) { continue }
        return $true
    }

    return $false
}

function Invoke-ConsoleFolderDeleteCleanup {
    param(
        [object]$EventData,
        [string]$RelativePath,
        [bool]$DeleteContents = $true
    )

    if (-not $EventData -or [string]::IsNullOrWhiteSpace($RelativePath)) { return }

    $relativePath = $RelativePath.Trim('\', '/').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relativePath)) { return }

    $folderUrl = "gs://$($EventData.BucketName)/$relativePath/"
    $projectArg = if ([string]::IsNullOrWhiteSpace($EventData.ProjectId)) { "" } else { " --project `"$($EventData.ProjectId)`"" }
    $allStepsComplete = $true

    if ($DeleteContents) {
        $contentRes = Invoke-GcloudStorageCommandWithRetry $EventData "deleting remaining folder contents for $folderUrl" "storage rm `"$folderUrl**`" --recursive --continue-on-error --quiet$projectArg"
        if (-not $contentRes.Success) { $allStepsComplete = $false }

        Invoke-ConsoleChildFolderRecordDelete $EventData $relativePath
    }

    $deleteSteps = @(
        [PSCustomObject]@{ Name = "folder marker"; Args = "storage rm `"$folderUrl`" --quiet$projectArg" },
        [PSCustomObject]@{ Name = "Console folder record"; Args = "storage folders delete `"$folderUrl`" --quiet$projectArg" }
    )

    foreach ($step in $deleteSteps) {
        $res = Invoke-GcloudStorageCommandWithRetry $EventData "deleting $($step.Name) for $folderUrl" $step.Args
        if (-not $res.Success) {
            $allStepsComplete = $false
        }
    }

    Add-Content -Path $EventData.LogPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') INFO  : Console folder delete checked: $folderUrl" -ErrorAction SilentlyContinue
    return $allStepsComplete
}

function Invoke-ConsoleFolderPruneEmptyParents($EventData, $RelativePath) {
    if (-not $EventData -or [string]::IsNullOrWhiteSpace($RelativePath)) { return }

    $folderPath = Normalize-GcsFolderPath $RelativePath
    while (-not [string]::IsNullOrWhiteSpace($folderPath)) {
        if (Test-ConsoleFolderHasCloudChildren $EventData $folderPath) {
            Add-Content -Path $EventData.LogPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') INFO  : Console folder prune stopped at non-empty folder: gs://$($EventData.BucketName)/$folderPath" -ErrorAction SilentlyContinue
            break
        }

        $deleted = Invoke-ConsoleFolderDeleteCleanup $EventData $folderPath $false
        if (-not $deleted) { break }

        Add-Content -Path $EventData.LogPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') INFO  : Empty Console folder pruned: gs://$($EventData.BucketName)/$folderPath" -ErrorAction SilentlyContinue
        $folderPath = Get-GcsParentFolderPath $folderPath
    }
}

function Invoke-ConsoleDeletedFolderCleanup($EventData, $RelativePath) {
    if (-not $EventData -or [string]::IsNullOrWhiteSpace($RelativePath)) { return }

    $folderPath = Normalize-GcsFolderPath $RelativePath
    if ([string]::IsNullOrWhiteSpace($folderPath)) { return }

    Invoke-ConsoleFolderDeleteCleanup $EventData $folderPath $true | Out-Null
    Invoke-ConsoleFolderPruneEmptyParents $EventData (Get-GcsParentFolderPath $folderPath)
}

function Invoke-ConsoleDeletedFileCleanup($EventData, $RelativePath) {
    if (-not $EventData -or [string]::IsNullOrWhiteSpace($RelativePath)) { return }

    $parentPath = Get-GcsParentFolderPath $RelativePath
    if ([string]::IsNullOrWhiteSpace($parentPath)) { return }

    Invoke-ConsoleFolderPruneEmptyParents $EventData $parentPath
}

function Start-ConsoleFolderDeleteWatcher($MountConfig) {
    if (-not $MountConfig -or [string]::IsNullOrWhiteSpace($MountConfig.DriveLetter) -or [string]::IsNullOrWhiteSpace($MountConfig.BucketName)) { return }

    $gCmd = Get-GcloudExe
    if (-not $gCmd) { return }

    $driveRoot = "$($MountConfig.DriveLetter.TrimEnd(':')):\"
    for ($i = 0; $i -lt 20 -and -not (Test-Path $driveRoot); $i++) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path $driveRoot)) { return }

    Stop-ConsoleFolderDeleteWatcher $MountConfig.DriveLetter
    $cleanupWorkerPath = Ensure-ConsoleFolderCleanupWorker

    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $driveRoot
    $watcher.IncludeSubdirectories = $true
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::DirectoryName
    $watcher.EnableRaisingEvents = $true

    $eventName = "GCSMountConsoleFolderDeleted_$($MountConfig.DriveLetter.TrimEnd(':'))"
    $data = [PSCustomObject]@{
        GcloudPath = $gCmd
        BucketName = $MountConfig.BucketName
        DriveRoot = ([System.IO.Path]::GetFullPath($driveRoot))
        ProjectId = $MountConfig.ProjectId
        LogPath = $global:logPath
        WorkerPath = $cleanupWorkerPath
    }

    $driveSubscription = Register-ObjectEvent -InputObject $watcher -EventName Deleted -SourceIdentifier $eventName -MessageData $data -Action {
        $fullPath = $Event.SourceEventArgs.FullPath
        $eventData = $Event.MessageData
        $driveRoot = $eventData.DriveRoot

        if ([string]::IsNullOrWhiteSpace($fullPath) -or -not $fullPath.StartsWith($driveRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return }

        $relativePath = $fullPath.Substring($driveRoot.Length).Trim('\', '/')
        if ([string]::IsNullOrWhiteSpace($relativePath)) { return }

        $relativePath = $relativePath.Replace('\', '/')
        Start-ConsoleFolderCleanupProcess $eventData $relativePath "Folder"
    }

    $rcloneLogPath = Get-MountLogPath $MountConfig.DriveLetter
    if (-not (Test-Path $rcloneLogPath)) { New-Item -ItemType File -Path $rcloneLogPath -Force | Out-Null }

    $logWatcher = New-Object System.IO.FileSystemWatcher
    $logWatcher.Path = [System.IO.Path]::GetDirectoryName($rcloneLogPath)
    $logWatcher.Filter = [System.IO.Path]::GetFileName($rcloneLogPath)
    $logWatcher.NotifyFilter = [System.IO.NotifyFilters]'LastWrite, Size, FileName'
    $logWatcher.EnableRaisingEvents = $true

    $logData = [PSCustomObject]@{
        GcloudPath = $gCmd
        BucketName = $MountConfig.BucketName
        ProjectId = $MountConfig.ProjectId
        LogPath = $global:logPath
        RcloneLogPath = $rcloneLogPath
        WorkerPath = $cleanupWorkerPath
        Offset = (Get-Item $rcloneLogPath).Length
        PartialLine = ""
    }

    $logSubscription = Register-ObjectEvent -InputObject $logWatcher -EventName Changed -SourceIdentifier "$($eventName)_RcloneLog" -MessageData $logData -Action {
        Start-Sleep -Milliseconds 250

        $eventData = $Event.MessageData
        if (-not (Test-Path $eventData.RcloneLogPath)) { return }

        $file = Get-Item $eventData.RcloneLogPath -ErrorAction SilentlyContinue
        if (-not $file) { return }
        if ($file.Length -lt $eventData.Offset) {
            $eventData.Offset = 0
            $eventData.PartialLine = ""
        }
        if ($file.Length -eq $eventData.Offset) { return }

        $stream = $null
        $reader = $null
        try {
            $stream = [System.IO.File]::Open($eventData.RcloneLogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $stream.Seek([int64]$eventData.Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $reader = New-Object System.IO.StreamReader($stream)
            $newText = $reader.ReadToEnd()
            $eventData.Offset = $stream.Position
        } catch {
            return
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($stream) { $stream.Dispose() }
        }

        if ([string]::IsNullOrWhiteSpace($newText)) { return }

        $text = "$($eventData.PartialLine)$newText"
        $endsWithNewLine = $text.EndsWith("`n") -or $text.EndsWith("`r")
        $lines = @($text -split "\r?\n")

        if (-not $endsWithNewLine -and $lines.Count -gt 0) {
            $eventData.PartialLine = $lines[-1]
            if ($lines.Count -gt 1) {
                $lines = $lines[0..($lines.Count - 2)]
            } else {
                $lines = @()
            }
        } else {
            $eventData.PartialLine = ""
        }

        foreach ($line in $lines) {
            if ($line -match '^\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+INFO\s+:\s+(?<folder>.+):\s+Removing directory\s*$') {
                Start-ConsoleFolderCleanupProcess $eventData $matches.folder "Folder"
            } elseif ($line -match '^\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+INFO\s+:\s+(?<file>.+):\s+vfs cache:\s+removed cache file as file deleted\s*$') {
                Start-ConsoleFolderCleanupProcess $eventData $matches.file "File"
            }
        }
    }

    Add-Content -Path $global:logPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') INFO  : Console folder delete watcher started for $($MountConfig.DriveLetter)" -ErrorAction SilentlyContinue

    $rootReconcileProcess = $null
    $schedulerPath = Ensure-ConsoleFolderRootReconcileScheduler
    $powerShellExe = (Get-Command "powershell.exe" -ErrorAction SilentlyContinue).Source
    if ($powerShellExe -and (Test-Path $schedulerPath)) {
        $driveRootArg = ([string]$data.DriveRoot).Replace('\', '/')
        $schedulerArguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$schedulerPath`"",
            "-WorkerPath", "`"$cleanupWorkerPath`"",
            "-GcloudPath", "`"$($data.GcloudPath)`"",
            "-BucketName", "`"$($data.BucketName)`"",
            "-ProjectId", "`"$($data.ProjectId)`"",
            "-LogPath", "`"$($data.LogPath)`"",
            "-DriveRoot", "`"$driveRootArg`"",
            "-IntervalMs", ([string]$global:ConsoleRootReconcileIntervalMs)
        ) -join " "

        try {
            $rootReconcileProcess = Start-Process -FilePath $powerShellExe -ArgumentList $schedulerArguments -WindowStyle Hidden -PassThru
            Add-Content -Path $global:logPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') INFO  : Console root folder reconcile scheduler started for $($MountConfig.DriveLetter)" -ErrorAction SilentlyContinue
        } catch {
            Add-Content -Path $global:logPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') WARN  : Failed to start Console root folder reconcile scheduler for $($MountConfig.DriveLetter) : $_" -ErrorAction SilentlyContinue
        }
    }

    $global:FolderDeleteWatchers[$MountConfig.DriveLetter.Trim().ToUpperInvariant()] = [PSCustomObject]@{
        DriveWatcher = $watcher
        DriveSubscription = $driveSubscription
        LogWatcher = $logWatcher
        LogSubscription = $logSubscription
        RootReconcileTimer = $null
        RootReconcileSubscription = $null
        RootReconcileProcess = $rootReconcileProcess
    }

    Start-ConsoleFolderRootReconcileProcess $data
}

function Get-RcloneFoldersUnderPath($MountConfig, $ParentPath) {
    $rCmd = Get-RcloneExe
    if (-not $rCmd) { return [PSCustomObject]@{ Success = $false; Folders = @(); Message = "Rclone not found." } }

    $bucketName = $MountConfig.BucketName
    $parent = Normalize-GcsFolderPath $ParentPath
    $remotePath = if ([string]::IsNullOrWhiteSpace($parent)) { "gcs_base:$bucketName" } else { "gcs_base:$bucketName/$parent" }
    $projFlag = if ([string]::IsNullOrWhiteSpace($MountConfig.ProjectId)) { "" } else { "--gcs-project-number `"$($MountConfig.ProjectId)`"" }

    $gcsCompatArgs = Get-GcsCompatibilityArgs
    $res = Invoke-SilentProcess $rCmd "lsf `"$remotePath`" --dirs-only --format p $gcsCompatArgs $projFlag"
    if ($res.ExitCode -ne 0) { return [PSCustomObject]@{ Success = $false; Folders = @(); Message = $res.Error } }

    $folders = @()
    foreach ($line in ($res.Output -split "\r?\n")) {
        $name = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '/$') { continue }
        $folders += (Normalize-GcsFolderPath "$parent$name")
    }

    return [PSCustomObject]@{ Success = $true; Folders = @($folders); Message = "" }
}

function Get-MountedDriveFoldersUnderPath($MountConfig, $ParentPath) {
    if (-not $MountConfig -or [string]::IsNullOrWhiteSpace($MountConfig.DriveLetter)) {
        return [PSCustomObject]@{ Success = $false; Folders = @(); Message = "No mounted drive was selected." }
    }

    $driveRoot = "$($MountConfig.DriveLetter.TrimEnd(':')):\"
    if (-not (Test-Path $driveRoot)) {
        return [PSCustomObject]@{ Success = $false; Folders = @(); Message = "Mounted drive $($MountConfig.DriveLetter) is not available." }
    }

    $parent = Normalize-GcsFolderPath $ParentPath
    $parentLocalPath = if ([string]::IsNullOrWhiteSpace($parent)) {
        $driveRoot
    } else {
        Join-Path $driveRoot ($parent.TrimEnd('/').Replace('/', '\'))
    }

    if (-not (Test-Path $parentLocalPath)) {
        return [PSCustomObject]@{ Success = $false; Folders = @(); Message = "The selected parent folder is not visible in the mounted drive. Select its nearest visible parent folder and refresh again." }
    }

    $folders = @()
    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $parentLocalPath -Directory -Force -ErrorAction Stop)) {
            $childPath = if ([string]::IsNullOrWhiteSpace($parent)) { "$($item.Name)/" } else { "$parent$($item.Name)/" }
            $folders += (Normalize-GcsFolderPath $childPath)
        }
    } catch {
        return [PSCustomObject]@{ Success = $false; Folders = @(); Message = "Unable to read folders from the mounted drive.`n`n$_" }
    }

    return [PSCustomObject]@{ Success = $true; Folders = @($folders); Message = "" }
}

function Get-GcloudFoldersUnderPath($MountConfig, $ParentPath) {
    $gCmd = Get-GcloudExe
    if (-not $gCmd) { return [PSCustomObject]@{ Success = $false; Folders = @(); Message = "Google Cloud CLI was not found. Install gcloud to scan Google Console folders." } }

    $bucketName = $MountConfig.BucketName
    $parent = Normalize-GcsFolderPath $ParentPath
    $url = "gs://$bucketName/$parent"

    $res = Invoke-SilentProcess $gCmd "storage ls `"$url`""
    if ($res.ExitCode -ne 0) { return [PSCustomObject]@{ Success = $false; Folders = @(); Message = $res.Error } }

    $folders = @()
    foreach ($line in ($res.Output -split "\r?\n")) {
        $urlLine = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($urlLine) -or $urlLine -notmatch '/$' -or $urlLine -notlike "gs://$bucketName/*") { continue }
        $folder = Normalize-GcsFolderPath $urlLine
        if (-not [string]::IsNullOrWhiteSpace($folder) -and $folder -ne $parent) { $folders += $folder }
    }

    return [PSCustomObject]@{ Success = $true; Folders = @($folders | Sort-Object -Unique); Message = "" }
}

function Find-MissingConsoleFolders($MountConfig, $ParentPath) {
    $console = Get-GcloudFoldersUnderPath $MountConfig $ParentPath
    if (-not $console.Success) { return [PSCustomObject]@{ Success = $false; Missing = @(); Message = $console.Message } }

    $mounted = Get-MountedDriveFoldersUnderPath $MountConfig $ParentPath
    if (-not $mounted.Success) { return [PSCustomObject]@{ Success = $false; Missing = @(); Message = $mounted.Message } }

    $mountedLookup = @{}
    foreach ($folder in $mounted.Folders) { $mountedLookup[$folder] = $true }

    $missing = @()
    foreach ($folder in $console.Folders) {
        if (-not $mountedLookup.ContainsKey($folder)) { $missing += $folder }
    }

    return [PSCustomObject]@{ Success = $true; Missing = @($missing | Sort-Object -Unique); Message = "" }
}

function Show-RefreshFolderSelectionDialog($MissingFolders) {
    $dialog = New-Object System.Windows.Window
    $dialog.Title = "Refresh Folder"
    $dialog.Width = 760
    $dialog.Height = 580
    $dialog.MinWidth = 620
    $dialog.MinHeight = 460
    $dialog.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dialog.ResizeMode = [System.Windows.ResizeMode]::CanResize
    $dialog.Background = "#FFFFFF"
    $dialog.FontFamily = "Segoe UI"
    try { if ($window) { $dialog.Owner = $window } } catch { }

    $root = New-Object System.Windows.Controls.DockPanel
    $root.Margin = New-Object System.Windows.Thickness 18
    $dialog.Content = $root

    $buttonPanel = New-Object System.Windows.Controls.StackPanel
    $buttonPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttonPanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $buttonPanel.Margin = New-Object System.Windows.Thickness 0,14,0,0
    [System.Windows.Controls.DockPanel]::SetDock($buttonPanel, [System.Windows.Controls.Dock]::Bottom)
    $root.Children.Add($buttonPanel) | Out-Null

    $contentPanel = New-Object System.Windows.Controls.StackPanel
    $root.Children.Add($contentPanel) | Out-Null

    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = "Refresh Folder found $($MissingFolders.Count) folder(s) that Google Cloud Console shows but this mounted drive cannot currently list."
    $header.FontSize = 15
    $header.FontWeight = [System.Windows.FontWeights]::Bold
    $header.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $header.Margin = New-Object System.Windows.Thickness 0,0,0,10
    $contentPanel.Children.Add($header) | Out-Null

    $explanation = New-Object System.Windows.Controls.TextBlock
    $explanation.Text = "Why this happens:`nEmpty folders created in Google Cloud Console can exist only as Google Cloud folder records, without any files or standard folder markers inside them. The mounted drive uses rclone, which needs either a real file under the folder or a zero-byte folder marker to display it.`n`nSelect the folders to refresh. Refresh Folder will create zero-byte compatibility markers for the selected folders. These markers represent folders by using the folder path ending in `"/`", not .placeholder files, and they do not change existing files."
    $explanation.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $explanation.Foreground = "#374151"
    $explanation.Margin = New-Object System.Windows.Thickness 0,0,0,12
    $contentPanel.Children.Add($explanation) | Out-Null

    $listLabel = New-Object System.Windows.Controls.TextBlock
    $listLabel.Text = "Folders to refresh:"
    $listLabel.FontWeight = [System.Windows.FontWeights]::SemiBold
    $listLabel.Margin = New-Object System.Windows.Thickness 0,0,0,6
    $contentPanel.Children.Add($listLabel) | Out-Null

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $scroll.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $scroll.Height = 240

    $listPanel = New-Object System.Windows.Controls.StackPanel
    $scroll.Content = $listPanel

    $listBorder = New-Object System.Windows.Controls.Border
    $listBorder.BorderBrush = "#D1D5DB"
    $listBorder.BorderThickness = New-Object System.Windows.Thickness 1
    $listBorder.Padding = New-Object System.Windows.Thickness 8
    $listBorder.Child = $scroll
    $contentPanel.Children.Add($listBorder) | Out-Null

    $checks = New-Object System.Collections.ArrayList
    foreach ($folder in $MissingFolders) {
        $check = New-Object System.Windows.Controls.CheckBox
        $check.Content = $folder
        $check.IsChecked = $true
        $check.Margin = New-Object System.Windows.Thickness 0,2,0,6
        $check.Foreground = "#111827"
        $listPanel.Children.Add($check) | Out-Null
        $checks.Add($check) | Out-Null
    }

    $note = New-Object System.Windows.Controls.TextBlock
    $note.Text = "This will modify the bucket by adding small zero-byte folder marker records for selected folders, then refresh the mounted drive cache."
    $note.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $note.Foreground = "#6B7280"
    $note.Margin = New-Object System.Windows.Thickness 0,10,0,0
    $contentPanel.Children.Add($note) | Out-Null

    $result = @{ Confirmed = $false; Selected = @() }

    $selectAll = New-Object System.Windows.Controls.Button
    $selectAll.Content = "Select All"
    $selectAll.Width = 90
    $selectAll.Height = 30
    $selectAll.Margin = New-Object System.Windows.Thickness 0,0,8,0
    $selectAll.Add_Click({ foreach ($check in $checks) { $check.IsChecked = $true } })
    $buttonPanel.Children.Add($selectAll) | Out-Null

    $clearAll = New-Object System.Windows.Controls.Button
    $clearAll.Content = "Clear"
    $clearAll.Width = 80
    $clearAll.Height = 30
    $clearAll.Margin = New-Object System.Windows.Thickness 0,0,16,0
    $clearAll.Add_Click({ foreach ($check in $checks) { $check.IsChecked = $false } })
    $buttonPanel.Children.Add($clearAll) | Out-Null

    $cancel = New-Object System.Windows.Controls.Button
    $cancel.Content = "Cancel"
    $cancel.Width = 90
    $cancel.Height = 30
    $cancel.Margin = New-Object System.Windows.Thickness 0,0,8,0
    $cancel.Add_Click({ $dialog.DialogResult = $false; $dialog.Close() })
    $buttonPanel.Children.Add($cancel) | Out-Null

    $create = New-Object System.Windows.Controls.Button
    $create.Content = "Refresh Selected"
    $create.Width = 130
    $create.Height = 30
    $create.Add_Click({
        $selected = @()
        foreach ($check in $checks) {
            if ($check.IsChecked -eq $true) { $selected += [string]$check.Content }
        }
        if ($selected.Count -eq 0) {
            [System.Windows.MessageBox]::Show("Select at least one folder to refresh.", "Refresh Folder", 0, 48) | Out-Null
            return
        }
        $result.Confirmed = $true
        $result.Selected = @($selected)
        $dialog.DialogResult = $true
        $dialog.Close()
    })
    $buttonPanel.Children.Add($create) | Out-Null

    $dialog.ShowDialog() | Out-Null
    return [PSCustomObject]@{ Confirmed = [bool]$result.Confirmed; Selected = @($result.Selected) }
}

function Stop-MountJob($DriveLetter) {
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return }
    Stop-ConsoleFolderDeleteWatcher $DriveLetter

    $pidToKill = Get-MountPID $DriveLetter
    if ($pidToKill) { Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue }
    
    Invoke-SilentProcess "cmd.exe" "/c net use $DriveLetter /delete /y" | Out-Null
    Invoke-SilentProcess "cmd.exe" "/c subst $DriveLetter /d" | Out-Null
    Start-Sleep -Seconds 1
}

function Refresh-MountDirectoryCache($MountConfig) {
    if (-not $MountConfig -or [string]::IsNullOrWhiteSpace($MountConfig.DriveLetter)) { return $false }
    if (-not (Get-MountPID $MountConfig.DriveLetter)) { return $false }

    $rCmd = Get-RcloneExe
    if (-not $rCmd) { return $false }

    $rcAddr = "127.0.0.1:$(Get-RcloneRcPort $MountConfig.DriveLetter)"
    $forgetRes = Invoke-SilentProcess $rCmd "--rc-addr $rcAddr rc vfs/forget"
    if ($forgetRes.ExitCode -ne 0) { return $false }

    $refreshRes = Invoke-SilentProcess $rCmd "--rc-addr $rcAddr rc vfs/refresh recursive=true _async=true"
    return ($refreshRes.ExitCode -eq 0)
}

function Repair-GcsFolderMarkers($MountConfig, $FolderPath) {
    if (-not $MountConfig) { return [PSCustomObject]@{ Success = $false; Message = "No mount selected."; Count = 0 } }

    $rCmd = Get-RcloneExe
    if (-not $rCmd) { return [PSCustomObject]@{ Success = $false; Message = "Rclone not found."; Count = 0 } }

    $gCmd = Get-GcloudExe
    if (-not $gCmd) { return [PSCustomObject]@{ Success = $false; Message = "Google Cloud CLI was not found. Install gcloud or create the folder through the mounted drive."; Count = 0 } }

    $rootPath = Normalize-GcsFolderPath $FolderPath
    if ([string]::IsNullOrWhiteSpace($rootPath)) {
        return [PSCustomObject]@{ Success = $false; Message = "Enter a folder path relative to the bucket, such as Survey.Acoustics/Projects & Analysis/Anaconda3."; Count = 0 }
    }

    $projFlag = if ([string]::IsNullOrWhiteSpace($MountConfig.ProjectId)) { "" } else { "--gcs-project-number `"$($MountConfig.ProjectId)`"" }
    $bucketName = $MountConfig.BucketName
    $queue = New-Object System.Collections.Queue
    $seen = @{}
    $created = 0
    $maxFolders = 500

    $queue.Enqueue($rootPath)
    while ($queue.Count -gt 0 -and $seen.Count -lt $maxFolders) {
        $relativePath = [string]$queue.Dequeue()
        if ($seen.ContainsKey($relativePath)) { continue }
        $seen[$relativePath] = $true

        $gcsCompatArgs = Get-GcsCompatibilityArgs
        $mkdirRes = Invoke-SilentProcess $rCmd "mkdir `"gcs_base:$bucketName/$relativePath`" $gcsCompatArgs $projFlag"
        if ($mkdirRes.ExitCode -ne 0) {
            return [PSCustomObject]@{ Success = $false; Message = "Failed to create marker for '$relativePath'.`n`n$($mkdirRes.Error)"; Count = $created }
        }
        $created++

        $listRes = Invoke-SilentProcess $gCmd "storage ls `"gs://$bucketName/$relativePath`""
        if ($listRes.ExitCode -ne 0) { continue }

        $childUrls = $listRes.Output -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '/$' -and $_ -like "gs://$bucketName/*" }
        foreach ($url in $childUrls) {
            $childPath = Normalize-GcsFolderPath $url
            if (-not [string]::IsNullOrWhiteSpace($childPath) -and -not $seen.ContainsKey($childPath)) {
                $queue.Enqueue($childPath)
            }
        }
    }

    if ($seen.Count -ge $maxFolders) {
        return [PSCustomObject]@{ Success = $true; Message = "Created markers for the first $created folders. Run repair again on deeper folders if needed."; Count = $created }
    }

    return [PSCustomObject]@{ Success = $true; Message = "Created rclone-visible markers for $created folder(s)."; Count = $created }
}

function Start-MountJob($MountConfig) {
    $rCmd = Get-RcloneExe
    if (-not $rCmd) {
        if (-not $AutoMount) { [System.Windows.MessageBox]::Show("Rclone not found. Please set the path in Settings.", "Error", 0, 16) }
        return $false
    }

    $projFlag = if ([string]::IsNullOrWhiteSpace($MountConfig.ProjectId)) { "" } else { "--gcs-project-number `"$($MountConfig.ProjectId)`"" }

    # VALIDATION GATEKEEPER
    $valRes = Invoke-SilentProcess $rCmd "lsf `"gcs_base:$($MountConfig.BucketName)`" --max-depth 1 $projFlag"
    
    if ($valRes.ExitCode -ne 0) {
        if (-not $AutoMount) {
            [System.Windows.MessageBox]::Show("Validation Failed! Cannot access bucket '$($MountConfig.BucketName)'.`n`nPlease verify the exact name and your permissions.`n`nRclone Details:`n$($valRes.Error)", "Access Denied", 0, 16)
        }
        return $false
    }

    Stop-MountJob $MountConfig.DriveLetter

    Ensure-ConfigDefaults $global:appConfig | Out-Null

    $cDir = Get-GlobalConfigValue "CacheDir"
    $cSize = Convert-ToPositiveIntegerText (Get-GlobalConfigValue "CacheMaxSize") "20" 1 1048576
    $cAge = Convert-ToPositiveIntegerText (Get-GlobalConfigValue "CacheMaxAge") "1" 1 8760
    $transferCount = Convert-ToPositiveIntegerText (Get-GlobalConfigValue "TransferCount") "8" 1 128
    $checkerCount = Convert-ToPositiveIntegerText (Get-GlobalConfigValue "CheckerCount") "16" 1 256
    $bufferSizeMb = Convert-ToPositiveIntegerText (Get-GlobalConfigValue "BufferSizeMb") "64" 1 4096
    $readAheadMb = Convert-ToPositiveIntegerText (Get-GlobalConfigValue "ReadAheadMb") "256" 0 65536
    $multiThreadStreams = Convert-ToPositiveIntegerText (Get-GlobalConfigValue "MultiThreadStreams") "4" 1 64
    $chunkSizeMb = Convert-ToPositiveIntegerText (Get-GlobalConfigValue "ChunkSizeMb") "64" 1 4096

    # GCS has no native folder objects or change polling, so preserve directory markers
    # and keep the VFS directory cache short enough for Explorer refreshes to see changes.
    $rcPort = Get-RcloneRcPort $MountConfig.DriveLetter
    $cacheArgs = "--vfs-cache-mode full --cache-dir `"$cDir`" --vfs-cache-max-size $($cSize)G --vfs-cache-max-age $($cAge)h --dir-cache-time 15s --poll-interval 0 --buffer-size $($bufferSizeMb)M --vfs-read-ahead $($readAheadMb)M --vfs-read-chunk-size $($chunkSizeMb)M --vfs-read-chunk-streams $multiThreadStreams"
    $performanceArgs = "--transfers $transferCount --checkers $checkerCount --multi-thread-streams $multiThreadStreams --multi-thread-cutoff 64M --multi-thread-chunk-size $($chunkSizeMb)M"
    $rcArgs = "--rc --rc-addr 127.0.0.1:$rcPort --rc-no-auth"
    $gcsArgs = Get-GcsCompatibilityArgs
    $mountLogPath = Get-MountLogPath $MountConfig.DriveLetter
    $mountArgs = "mount `"gcs_base:$($MountConfig.BucketName)`" $($MountConfig.DriveLetter) --volname `"$($MountConfig.BucketName)`" $cacheArgs $performanceArgs $gcsArgs $rcArgs --links --log-level INFO --log-file `"$mountLogPath`" $projFlag"
    
    if ($AutoMount) {
        Start-Process -FilePath $rCmd -ArgumentList $mountArgs -WindowStyle Hidden
    } else {
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c title GCS: $($MountConfig.BucketName) && `"$rCmd`" $mountArgs" -WindowStyle Hidden
    }

    Start-ConsoleFolderDeleteWatcher $MountConfig
    return $true
}

# --- 5. Main GUI Definition ---
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="GCS Bucket Mounting Tool v2.0" Width="750" MinWidth="750" SizeToContent="Height" MinHeight="450" Background="#F3F4F6" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" ResizeMode="CanMinimize">
    <Window.Resources>
        <Style TargetType="Label"><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="#374151"/><Setter Property="Margin" Value="0,8,0,2"/><Setter Property="FontSize" Value="13"/></Style>
        <Style TargetType="TextBox"><Setter Property="Padding" Value="6,4"/><Setter Property="BorderBrush" Value="#D1D5DB"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Background" Value="White"/><Setter Property="Height" Value="28"/><Setter Property="FontSize" Value="13"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style>
        <Style TargetType="Button">
            <Setter Property="Foreground" Value="White"/><Setter Property="BorderThickness" Value="0"/><Setter Property="FontSize" Value="13"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="4"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Setter.Value></Setter>
        </Style>
    </Window.Resources>
    
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="230"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border Grid.Column="0" Background="#1F2937" Padding="10">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Text="Configured Drives" Foreground="White" FontWeight="Bold" FontSize="15" Margin="0,0,0,2" Grid.Row="0"/>
                <TextBlock Text="(Double-click to edit)" Foreground="#9CA3AF" FontSize="11" Margin="0,0,0,10" Grid.Row="1"/>
                <ListBox Name="lstMounts" Grid.Row="2" Background="Transparent" BorderThickness="0" Foreground="White" FontSize="14" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                    <ListBox.ItemTemplate>
                        <DataTemplate>
                            <Border Padding="5" BorderBrush="#374151" BorderThickness="0,0,0,1" Width="200" Cursor="Hand" Background="Transparent">
                                <StackPanel>
                                    <TextBlock Text="{Binding DisplayName}" FontWeight="Bold"/>
                                    <TextBlock Text="{Binding Status}" FontSize="11" Foreground="#9CA3AF"/>
                                </StackPanel>
                            </Border>
                        </DataTemplate>
                    </ListBox.ItemTemplate>
                </ListBox>
                <StackPanel Grid.Row="3" Margin="0,15,0,0">
                    <Button Name="btnConnect" Content="Connect Drive" Height="35" Background="#10B981" Margin="0,0,0,10" IsEnabled="False"/>
                    <Button Name="btnDisconnect" Content="Disconnect Drive" Height="35" Background="#F59E0B" Margin="0,0,0,10" IsEnabled="False"/>
                    <Button Name="btnGlobalSet" Content="Settings" Height="30" Background="#4B5563"/>
                </StackPanel>
            </Grid>
        </Border>

        <Border Grid.Column="1" Padding="25" Background="#FFFFFF">
            <StackPanel Name="pnlEditor" IsEnabled="True">
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Name="txtEditorTitle" Text="Connection Settings" FontSize="20" FontWeight="Bold" Foreground="#111827"/>
                    <Button Name="btnResetForm" Grid.Column="1" Content="New" Background="#6B7280" Width="80" Height="30" Margin="0,0,10,0"/>
                    <Button Name="btnDelete" Grid.Column="2" Content="Delete" Background="#EF4444" Width="80" Height="30" IsEnabled="False"/>
                </Grid>
                
                <Separator Margin="0,10,0,15"/>

                <Border Background="#F9FAFB" BorderBrush="#E5E7EB" BorderThickness="1" CornerRadius="4" Padding="15" Margin="0,0,0,15">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Button Name="btnSignIn" Grid.Column="0" Content="Sign In to Google Cloud" Background="#3B82F6" Width="170" Height="32"/>
                        <TextBlock Name="txtAuthStatus" Grid.Column="1" Text="[LOCKED] Form locked. Please sign in first." Foreground="#EF4444" FontWeight="SemiBold" VerticalAlignment="Center" Margin="15,0,0,0" TextWrapping="Wrap"/>
                    </Grid>
                </Border>

                <StackPanel Name="pnlMountDetails" IsEnabled="False">
                    <Label Content="Project ID (Optional)"/>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="120"/>
                        </Grid.ColumnDefinitions>
                        <TextBox Name="txtProject" Grid.Column="0" ToolTip="Required if you want to Fetch a list of buckets. Optional if manually typing bucket name." />
                        <Button Name="btnFetchBuckets" Grid.Column="1" Content="Fetch Buckets" Height="28" Background="#3B82F6" Margin="10,0,0,0"/>
                    </Grid>

                    <Grid Margin="0,10,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0">
                            <Label Content="Bucket Name (Required)"/>
                            <ComboBox Name="cmbBucket" Height="28" FontSize="13" VerticalContentAlignment="Center" IsEditable="True"/>
                        </StackPanel>
                        <StackPanel Grid.Column="2">
                            <Label Content="Drive Letter"/>
                            <ComboBox Name="cmbDrive" Height="28" FontSize="13" VerticalContentAlignment="Center"/>
                        </StackPanel>
                    </Grid>

                    <CheckBox Name="chkAutoMount" Content="Auto-mount this drive at Windows login" FontSize="13" Foreground="#374151" FontWeight="SemiBold" Margin="0,20,0,20"/>

                    <Button Name="btnSaveMount" Content="Save and Mount" Height="40" Background="#10B981" Margin="0,10,0,0"/>
                </StackPanel>
            </StackPanel>
        </Border>
    </Grid>
</Window>
"@

# --- 6. Global Settings XAML ---
[string]$globalSetXamlString = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Settings" Width="600" SizeToContent="Height" MinHeight="350" Background="#F9FAFB" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" ResizeMode="NoResize">
    <Border Padding="20"><StackPanel>
        
        <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="#6B7280" FontWeight="Bold" Margin="0,0,0,15">
            Note: Rclone and WinFSP folder paths are optional if you already have them configured in your system environment PATH. Hover over Cache settings for details.
        </TextBlock>

        <Label Content="Rclone Folder Path" />
        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/></Grid.ColumnDefinitions>
            <TextBox Name="txtRc" Grid.Column="0" Height="28" />
            <Button Name="btnBrowseRc" Grid.Column="1" Content="Browse" Margin="5,0,0,0" Height="28" Background="#D1D5DB" Foreground="#111827"/>
        </Grid>
        
        <Label Content="WinFSP Bin Path" Margin="0,10,0,2" />
        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/></Grid.ColumnDefinitions>
            <TextBox Name="txtWf" Grid.Column="0" Height="28" />
            <Button Name="btnBrowseWf" Grid.Column="1" Content="Browse" Margin="5,0,0,0" Height="28" Background="#D1D5DB" Foreground="#111827"/>
        </Grid>
        
        <Separator Margin="0,20,0,10" Background="#D1D5DB"/>
        <TextBlock Text="Global Cache Settings" FontWeight="Bold" FontSize="15" Foreground="#111827" Margin="0,0,0,5"/>
        
        <Label Content="Cache Directory" ToolTip="The local folder where files are temporarily stored during transfers. A drive with plenty of free space is recommended." />
        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions>
            <TextBox Name="txtCacheDir" Grid.Column="0" Height="28" ToolTip="The local folder where files are temporarily stored during transfers. A drive with plenty of free space is recommended." />
            <Button Name="btnBrowseCache" Grid.Column="1" Content="Browse" Margin="5,0,0,0" Height="28" Background="#D1D5DB" Foreground="#111827"/>
        </Grid>

        <Grid Margin="0,10,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="15"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <Label Content="Max Cache Storage Size (GB)" ToolTip="The maximum amount of local disk space Rclone will use for caching files. When this limit is reached, older cached files are deleted to make room." />
                <TextBox Name="txtCacheSize" Height="28" ToolTip="The maximum amount of local disk space Rclone will use for caching files. When this limit is reached, older cached files are deleted to make room." />
            </StackPanel>
            <StackPanel Grid.Column="2">
                <Label Content="Cache TTL (Hours)" ToolTip="Time To Live. How long (in hours) an inactive file stays in the local cache before being deleted. Higher = faster reopening. Lower = saves disk space." />
                <TextBox Name="txtCacheAge" Height="28" ToolTip="Time To Live. How long (in hours) an inactive file stays in the local cache before being deleted. Higher = faster reopening. Lower = saves disk space." />
            </StackPanel>
        </Grid>

        <Separator Margin="0,20,0,10" Background="#D1D5DB"/>
        <TextBlock Text="Transfer Performance" FontWeight="Bold" FontSize="15" Foreground="#111827" Margin="0,0,0,5"/>

        <Grid Margin="0,0,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="15"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <Label Content="Parallel Transfers" ToolTip="Number of file transfers rclone can run at the same time. Higher can improve throughput on fast networks." />
                <TextBox Name="txtTransfers" Height="28" ToolTip="Number of file transfers rclone can run at the same time. Higher can improve throughput on fast networks." />
            </StackPanel>
            <StackPanel Grid.Column="2">
                <Label Content="Metadata Checkers" ToolTip="Number of parallel metadata/listing checks. Higher can improve large folder scans." />
                <TextBox Name="txtCheckers" Height="28" ToolTip="Number of parallel metadata/listing checks. Higher can improve large folder scans." />
            </StackPanel>
        </Grid>

        <Grid Margin="0,10,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="15"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <Label Content="Buffer per Open File (MB)" ToolTip="RAM buffer rclone uses for each open file. Higher can improve streaming reads and writes." />
                <TextBox Name="txtBufferMb" Height="28" ToolTip="RAM buffer rclone uses for each open file. Higher can improve streaming reads and writes." />
            </StackPanel>
            <StackPanel Grid.Column="2">
                <Label Content="Read Ahead (MB)" ToolTip="Extra sequential read-ahead used with the full VFS cache. Higher can improve large file reads." />
                <TextBox Name="txtReadAheadMb" Height="28" ToolTip="Extra sequential read-ahead used with the full VFS cache. Higher can improve large file reads." />
            </StackPanel>
        </Grid>

        <Grid Margin="0,10,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="15"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <Label Content="Multi-thread Streams" ToolTip="Parallel streams rclone can use for larger downloads." />
                <TextBox Name="txtMtStreams" Height="28" ToolTip="Parallel streams rclone can use for larger downloads." />
            </StackPanel>
            <StackPanel Grid.Column="2">
                <Label Content="Read Chunk Size (MB)" ToolTip="Chunk size for VFS and multi-thread downloads. Larger chunks can improve high-bandwidth reads but use more memory." />
                <TextBox Name="txtChunkMb" Height="28" ToolTip="Chunk size for VFS and multi-thread downloads. Larger chunks can improve high-bandwidth reads but use more memory." />
            </StackPanel>
        </Grid>

        <Button Name="btnSaveGlobal" Content="Save Settings" Margin="0,20,0,0" HorizontalAlignment="Right" Width="110" Height="35" Background="#3B82F6" Foreground="White" FontWeight="Bold" />
    </StackPanel></Border>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$global:WindowClosed = $false

# --- 7. Element Binding ---
$lstMounts = $window.FindName("lstMounts")
$txtEditorTitle = $window.FindName("txtEditorTitle")
$cmbBucket = $window.FindName("cmbBucket"); $txtProject = $window.FindName("txtProject"); $cmbDrive = $window.FindName("cmbDrive")
$chkAutoMount = $window.FindName("chkAutoMount")
$btnGlobalSet = $window.FindName("btnGlobalSet"); $btnDelete = $window.FindName("btnDelete")
$btnResetForm = $window.FindName("btnResetForm"); $btnFetchBuckets = $window.FindName("btnFetchBuckets")
$btnConnect = $window.FindName("btnConnect"); $btnDisconnect = $window.FindName("btnDisconnect"); $btnSaveMount = $window.FindName("btnSaveMount")

$btnSignIn = $window.FindName("btnSignIn")
$txtAuthStatus = $window.FindName("txtAuthStatus")
$pnlMountDetails = $window.FindName("pnlMountDetails")

# --- 8. System Tray Setup ---
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
if ($MyInvocation.MyCommand.Path -match "\.exe$") {
    $notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($MyInvocation.MyCommand.Path)
} else {
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
}
$notifyIcon.Text = "GCS Bucket Mounting Tool"
$notifyIcon.Visible = $false

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuOpen = $contextMenu.Items.Add("Open Configuration")
$menuExit = $contextMenu.Items.Add("Exit Application")

$menuOpen.Add_Click({
    if ($global:WindowClosed) { return }
    $window.ShowInTaskbar = $true
    $window.WindowState = [System.Windows.WindowState]::Normal
    $notifyIcon.Visible = $false
})

$menuExit.Add_Click({
    $notifyIcon.Visible = $false
    if (-not $global:WindowClosed) { $window.Close() }
})
$notifyIcon.ContextMenuStrip = $contextMenu
$notifyIcon.Add_DoubleClick({
    if ($global:WindowClosed) { return }
    $window.ShowInTaskbar = $true
    $window.WindowState = [System.Windows.WindowState]::Normal
    $notifyIcon.Visible = $false
})
$window.Add_StateChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
        $window.ShowInTaskbar = $false
        $notifyIcon.Visible = $true
    }
})
$window.Add_Closed({
    $global:WindowClosed = $true
    Stop-AllConsoleFolderDeleteWatchers
    try {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    } catch { }
})

# --- 9. UI Functions ---
function Update-StartupShortcut {
    $hasAuto = $false
    foreach ($m in $global:appConfig.Mounts) { if ($m.AutoMount -eq $true) { $hasAuto = $true; break } }
    
    if ($hasAuto) {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($shortcutPath)
        
        $exeName = [System.IO.Path]::GetFileName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        if ($exeName -match "(?i)powershell") { $exeName = "GCS_Manager.exe" }
        
        $Shortcut.TargetPath = "C:\gcs-mount\$exeName"
        $Shortcut.Arguments = "-AutoMount"
        $Shortcut.WorkingDirectory = "C:\gcs-mount"
        
        $Shortcut.Save()
    } else {
        if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force }
    }
}

function Refresh-Sidebar {
    $listData = @()
    foreach ($m in $global:appConfig.Mounts) {
        $isRunning = $null -ne (Get-MountPID $m.DriveLetter)
        $statusText = if ($isRunning) { "Active" } else { "Disconnected" }
        if ($m.AutoMount) { $statusText += " (Auto)" }

        $listData += [PSCustomObject]@{ Id = $m.Id; DisplayName = "$($m.DriveLetter) $($m.BucketName)"; Status = $statusText }
    }
    $lstMounts.ItemsSource = $listData
    $lstMounts.Items.Refresh()
}

function Reset-Editor {
    $global:CurrentEditId = "NEW"
    $txtEditorTitle.Text = "Connection Settings"
    $txtProject.Text = ""
    $cmbBucket.Text = ""
    $cmbBucket.ItemsSource = $null
    $chkAutoMount.IsChecked = $false
    
    $pnlMountDetails.IsEnabled = $global:IsAuthenticated
    
    $lstMounts.SelectedItem = $null
    $btnConnect.IsEnabled = $false
    $btnDisconnect.IsEnabled = $false
    $btnDelete.IsEnabled = $false
    $btnSaveMount.Content = "Save and Mount"

    $existingDrives = (Get-CimInstance Win32_LogicalDisk).DeviceID
    $appDrives = $global:appConfig.Mounts.DriveLetter
    $freeLetter = "X:"
    foreach ($ascii in 90..68) {
        $l = [char]$ascii + ":"
        if ($existingDrives -notcontains $l -and $appDrives -notcontains $l) { $freeLetter = $l; break }
    }
    
    $driveOptions = @()
    foreach ($ascii in 68..90) {
        $letter = [char]$ascii + ":"
        if ($existingDrives -notcontains $letter -and $appDrives -notcontains $letter) { $driveOptions += $letter }
    }
    if ($driveOptions -notcontains $freeLetter) { $driveOptions += $freeLetter }
    $cmbDrive.ItemsSource = $driveOptions | Sort-Object
    $cmbDrive.SelectedItem = $freeLetter
}

function Load-IntoEditor($MountId) {
    if (-not $MountId -or $MountId -eq "NEW") { 
        Reset-Editor
        return 
    }
    
    $m = $global:appConfig.Mounts | Where-Object { $_.Id -eq $MountId }
    if (-not $m) { return }

    $global:CurrentEditId = $m.Id
    $txtEditorTitle.Text = "Connection Settings - $($m.DriveLetter)"
    $btnDelete.IsEnabled = $true
    
    $cmbBucket.ItemsSource = $null
    $cmbBucket.Text = $m.BucketName; $txtProject.Text = $m.ProjectId; $chkAutoMount.IsChecked = [bool]$m.AutoMount

    $existingDrives = Get-CimInstance Win32_LogicalDisk
    $driveOptions = @()
    foreach ($ascii in 68..90) {
        $letter = [char]$ascii + ":"
        $inUseByOS = $existingDrives | Where-Object DeviceID -eq $letter
        $inUseByApp = $global:appConfig.Mounts | Where-Object { $_.DriveLetter -eq $letter -and $_.Id -ne $m.Id }
        
        if (-not $inUseByOS -and -not $inUseByApp) { $driveOptions += $letter }
        elseif ($letter -eq $m.DriveLetter) { $driveOptions += $letter }
    }
    $cmbDrive.ItemsSource = $driveOptions
    $cmbDrive.SelectedItem = $m.DriveLetter

    if (Get-MountPID $m.DriveLetter) {
        $btnSaveMount.Content = "Update and Restart Mount"
    } else {
        $btnSaveMount.Content = "Update and Mount"
    }
}

function Update-UIAuthState {
    $rCmd = Get-RcloneExe
    if (-not $rCmd) { return }
    
    $res = Invoke-SilentProcess $rCmd "listremotes"
    if ($res.Output -match "gcs_base:") {
        $global:IsAuthenticated = $true
        
        try {
            $dumpRes = Invoke-SilentProcess $rCmd "config dump"
            $confJson = $dumpRes.Output | ConvertFrom-Json
            $tokenJson = $confJson.gcs_base.token | ConvertFrom-Json
            
            $userInfo = Invoke-RestMethod -Uri "https://www.googleapis.com/oauth2/v1/userinfo?access_token=$($tokenJson.access_token)" -ErrorAction Stop
            $txtAuthStatus.Text = "[OK] Signed in as: $($userInfo.email)"
        } catch {
            $txtAuthStatus.Text = "[OK] Authenticated Successfully"
        }
        
        $txtAuthStatus.Foreground = "#10B981"
        $pnlMountDetails.IsEnabled = $true
        $btnSignIn.Content = "Re-Authenticate"
    }
}

# --- 10. Event Listeners ---

$btnSignIn.Add_Click({
    $btnSignIn.IsEnabled = $false
    $btnSignIn.Content = "Waiting for browser..."
    $txtAuthStatus.Text = "Please complete sign-in in your web browser."
    $txtAuthStatus.Foreground = "#F59E0B"
    [System.Windows.Forms.Application]::DoEvents()

    $rCmd = Get-RcloneExe
    if (-not $rCmd) {
        [System.Windows.MessageBox]::Show("Rclone not found. Please set the path in Settings.", "Error", 0, 16)
        $btnSignIn.IsEnabled = $true; $btnSignIn.Content = "Sign In to Google Cloud"
        $txtAuthStatus.Text = "[LOCKED] Form locked. Please sign in first."; $txtAuthStatus.Foreground = "#EF4444"
        return
    }

    # THE ZOMBIE KILLER: Terminate any stuck background rclone config processes holding port 53682
    $zombies = Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "config" }
    if ($zombies) {
        foreach ($z in $zombies) { Stop-Process -Id $z.ProcessId -Force -ErrorAction SilentlyContinue }
    }

    Invoke-SilentProcess $rCmd "config delete gcs_base" | Out-Null

    $authLogPath = "$configPath\auth_debug.log"
    if (Test-Path $authLogPath) { Remove-Item $authLogPath -Force -ErrorAction SilentlyContinue }

    # Launch natively. Because the zombie killer freed port 53682, the browser will launch perfectly.
    $authArgs = "config create gcs_base `"google cloud storage`" config_is_local true --log-level DEBUG --log-file `"$authLogPath`""
    Start-Process -FilePath $rCmd -ArgumentList $authArgs -WindowStyle Normal -Wait

    Update-UIAuthState
    
    if (-not $global:IsAuthenticated) {
        $txtAuthStatus.Text = "[FAILED] Auth failed. Opening log file..."
        $txtAuthStatus.Foreground = "#EF4444"
        $btnSignIn.Content = "Sign In to Google Cloud"
        
        if (Test-Path $authLogPath) { Start-Process "notepad.exe" $authLogPath }
    }
    
    $btnSignIn.IsEnabled = $true
})


$lstMounts.Add_SelectionChanged({
    if ($lstMounts.SelectedItem) {
        $mId = $lstMounts.SelectedItem.Id
        $m = $global:appConfig.Mounts | Where-Object { $_.Id -eq $mId }
        
        if (Get-MountPID $m.DriveLetter) {
            $btnConnect.IsEnabled = $false
            $btnDisconnect.IsEnabled = $true
        } else {
            $btnConnect.IsEnabled = $true
            $btnDisconnect.IsEnabled = $false
        }
    } else {
        $btnConnect.IsEnabled = $false
        $btnDisconnect.IsEnabled = $false
    }
})

$lstMounts.Add_MouseDoubleClick({
    if ($lstMounts.SelectedItem) { Load-IntoEditor $lstMounts.SelectedItem.Id }
})

$btnResetForm.Add_Click({ Reset-Editor })

$btnFetchBuckets.Add_Click({
    $projId = $txtProject.Text.Trim()
    
    # SMART INTERCEPTOR: Prevent Google Cloud API rejection for missing Project ID
    if ([string]::IsNullOrWhiteSpace($projId)) {
        [System.Windows.MessageBox]::Show("A Project ID is required to fetch a list of buckets from Google Cloud.`n`nPlease enter your Project ID above, or manually type your exact Bucket Name below to skip fetching.", "Project ID Required", 0, 48)
        return
    }

    $btnFetchBuckets.IsEnabled = $false
    $btnFetchBuckets.Content = "Fetching..."
    [System.Windows.Forms.Application]::DoEvents()

    $rCmd = Get-RcloneExe
    if (-not $rCmd) {
        [System.Windows.MessageBox]::Show("Rclone not found. Please set the path in Settings.", "Error", 0, 16)
        $btnFetchBuckets.IsEnabled = $true
        $btnFetchBuckets.Content = "Fetch Buckets"
        return
    }

    $projFlag = "--gcs-project-number `"$projId`""

    $fetchRes = Invoke-SilentProcess $rCmd "lsf gcs_base: --dirs-only $projFlag"
    
    if ($fetchRes.ExitCode -eq 0) {
        $buckets = $fetchRes.Output -split "\r?\n" | ForEach-Object { $_.Trim() -replace '/$', '' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        if ($buckets) {
            $cmbBucket.ItemsSource = @($buckets)
            $cmbBucket.IsDropDownOpen = $true
        } else {
            [System.Windows.MessageBox]::Show("No buckets found or accessible using these credentials.", "Info", 0, 64)
        }
    } else {
        [System.Windows.MessageBox]::Show("Failed to fetch buckets. Check permissions.`n`nError details:`n$($fetchRes.Error)", "Fetch Error", 0, 16)
    }

    $btnFetchBuckets.IsEnabled = $true
    $btnFetchBuckets.Content = "Fetch Buckets"
})

$btnGlobalSet.Add_Click({
    [xml]$setXamlXml = $globalSetXamlString
    $setReader = (New-Object System.Xml.XmlNodeReader $setXamlXml)
    $setWindow = [Windows.Markup.XamlReader]::Load($setReader)
    $setWindow.Owner = $window

    $txtRc = $setWindow.FindName("txtRc"); $txtWf = $setWindow.FindName("txtWf")
    $txtCacheDir = $setWindow.FindName("txtCacheDir"); $txtCacheSize = $setWindow.FindName("txtCacheSize"); $txtCacheAge = $setWindow.FindName("txtCacheAge")
    $txtTransfers = $setWindow.FindName("txtTransfers"); $txtCheckers = $setWindow.FindName("txtCheckers")
    $txtBufferMb = $setWindow.FindName("txtBufferMb"); $txtReadAheadMb = $setWindow.FindName("txtReadAheadMb")
    $txtMtStreams = $setWindow.FindName("txtMtStreams"); $txtChunkMb = $setWindow.FindName("txtChunkMb")
    $btnBrowseRc = $setWindow.FindName("btnBrowseRc"); $btnBrowseWf = $setWindow.FindName("btnBrowseWf"); $btnBrowseCache = $setWindow.FindName("btnBrowseCache")
    $btnSaveGlobal = $setWindow.FindName("btnSaveGlobal")

    Ensure-ConfigDefaults $global:appConfig | Out-Null
    $txtRc.Text = $global:appConfig.Global.RclonePath
    $txtWf.Text = $global:appConfig.Global.WinFspPath
    $txtCacheDir.Text = Get-GlobalConfigValue "CacheDir"
    $txtCacheSize.Text = Get-GlobalConfigValue "CacheMaxSize"
    $txtCacheAge.Text = Get-GlobalConfigValue "CacheMaxAge"
    $txtTransfers.Text = Get-GlobalConfigValue "TransferCount"
    $txtCheckers.Text = Get-GlobalConfigValue "CheckerCount"
    $txtBufferMb.Text = Get-GlobalConfigValue "BufferSizeMb"
    $txtReadAheadMb.Text = Get-GlobalConfigValue "ReadAheadMb"
    $txtMtStreams.Text = Get-GlobalConfigValue "MultiThreadStreams"
    $txtChunkMb.Text = Get-GlobalConfigValue "ChunkSizeMb"

    $btnBrowseRc.Add_Click({ $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $txtRc.Text = $d.SelectedPath } })
    $btnBrowseWf.Add_Click({ $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $txtWf.Text = $d.SelectedPath } })
    $btnBrowseCache.Add_Click({ $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $txtCacheDir.Text = $d.SelectedPath } })

    $btnSaveGlobal.Add_Click({
        $global:appConfig.Global.RclonePath = $txtRc.Text.Trim()
        $global:appConfig.Global.WinFspPath = $txtWf.Text.Trim()
        $cacheDir = if ($txtCacheDir.Text) { $txtCacheDir.Text.Trim() } else { "C:\RcloneCache" }
        Set-GlobalConfigValue "CacheDir" $cacheDir
        Set-GlobalConfigValue "CacheMaxSize" (Convert-ToPositiveIntegerText $txtCacheSize.Text "20" 1 1048576)
        Set-GlobalConfigValue "CacheMaxAge" (Convert-ToPositiveIntegerText $txtCacheAge.Text "1" 1 8760)
        Set-GlobalConfigValue "TransferCount" (Convert-ToPositiveIntegerText $txtTransfers.Text "8" 1 128)
        Set-GlobalConfigValue "CheckerCount" (Convert-ToPositiveIntegerText $txtCheckers.Text "16" 1 256)
        Set-GlobalConfigValue "BufferSizeMb" (Convert-ToPositiveIntegerText $txtBufferMb.Text "64" 1 4096)
        Set-GlobalConfigValue "ReadAheadMb" (Convert-ToPositiveIntegerText $txtReadAheadMb.Text "256" 0 65536)
        Set-GlobalConfigValue "MultiThreadStreams" (Convert-ToPositiveIntegerText $txtMtStreams.Text "4" 1 64)
        Set-GlobalConfigValue "ChunkSizeMb" (Convert-ToPositiveIntegerText $txtChunkMb.Text "64" 1 4096)
        
        Save-Config; $setWindow.Close()
    })
    $setWindow.ShowDialog() | Out-Null
})

$btnDelete.Add_Click({
    if ($global:CurrentEditId -and $global:CurrentEditId -ne "NEW") {
        $m = $global:appConfig.Mounts | Where-Object { $_.Id -eq $global:CurrentEditId }
        Stop-MountJob $m.DriveLetter
        $global:appConfig.Mounts = @($global:appConfig.Mounts | Where-Object { $_.Id -ne $global:CurrentEditId })
        Save-Config; Update-StartupShortcut; Refresh-Sidebar
        Reset-Editor
    }
})

$btnConnect.Add_Click({
    if ($lstMounts.SelectedItem) {
        $btnConnect.IsEnabled = $false
        $btnConnect.Content = "Validating..."
        [System.Windows.Forms.Application]::DoEvents()
        
        $m = $global:appConfig.Mounts | Where-Object { $_.Id -eq $lstMounts.SelectedItem.Id }
        $success = Start-MountJob $m
        
        Refresh-Sidebar
        $btnConnect.Content = "Connect Drive"
        
        if ($success) {
            $btnDisconnect.IsEnabled = $true
        } else {
            $btnConnect.IsEnabled = $true
        }
        
        if ($global:CurrentEditId -eq $m.Id) { Load-IntoEditor $m.Id }
        foreach ($item in $lstMounts.Items) { if ($item.Id -eq $m.Id) { $lstMounts.SelectedItem = $item; break } }
    }
})

$btnDisconnect.Add_Click({
    if ($lstMounts.SelectedItem) {
        $m = $global:appConfig.Mounts | Where-Object { $_.Id -eq $lstMounts.SelectedItem.Id }
        Stop-MountJob $m.DriveLetter
        Refresh-Sidebar
        $btnConnect.IsEnabled = $true; $btnDisconnect.IsEnabled = $false
        if ($global:CurrentEditId -eq $m.Id) { Load-IntoEditor $m.Id }
        foreach ($item in $lstMounts.Items) { if ($item.Id -eq $m.Id) { $lstMounts.SelectedItem = $item; break } }
    }
})

$btnSaveMount.Add_Click({
    if ([string]::IsNullOrWhiteSpace($cmbBucket.Text) -or $null -eq $cmbDrive.SelectedItem) {
        [System.Windows.MessageBox]::Show("Bucket name and Drive Letter are required.", "Input Error", 0, 48); return
    }

    $btnSaveMount.IsEnabled = $false
    $btnSaveMount.Content = "Validating..."
    [System.Windows.Forms.Application]::DoEvents()

    $targetId = $global:CurrentEditId
    if ($targetId -eq "NEW") {
        $targetId = [guid]::NewGuid().ToString()
        $newMount = [PSCustomObject]@{ Id = $targetId; BucketName = ""; ProjectId = ""; DriveLetter = ""; AutoMount = $false }
        $global:appConfig.Mounts += $newMount
    }

    for ($i=0; $i -lt $global:appConfig.Mounts.Count; $i++) {
        if ($global:appConfig.Mounts[$i].Id -eq $targetId) {
            $global:appConfig.Mounts[$i].BucketName = $cmbBucket.Text.Trim()
            $global:appConfig.Mounts[$i].ProjectId = $txtProject.Text.Trim()
            $global:appConfig.Mounts[$i].DriveLetter = $cmbDrive.SelectedItem
            $global:appConfig.Mounts[$i].AutoMount = [bool]$chkAutoMount.IsChecked
            
            Save-Config; Update-StartupShortcut
            $success = Start-MountJob $global:appConfig.Mounts[$i]
            
            if (-not $success) {
                if ($global:CurrentEditId -eq "NEW") {
                    $global:appConfig.Mounts = @($global:appConfig.Mounts | Where-Object { $_.Id -ne $targetId })
                    $btnSaveMount.Content = "Save and Mount"
                } else {
                    $btnSaveMount.Content = "Update and Mount"
                }
                $btnSaveMount.IsEnabled = $true
                return
            }
            break
        }
    }
    
    Refresh-Sidebar
    Reset-Editor 
    $btnSaveMount.IsEnabled = $true
})

# --- 11. AutoMount Execution Branch ---
$startHidden = $false
if ($AutoMount) {
    $startHidden = $true
    Start-Sleep -Seconds 20
    foreach ($m in $global:appConfig.Mounts) { if ($m.AutoMount -eq $true) { Start-MountJob $m | Out-Null } }
}

# --- 12. Launch & Init ---
Update-UIAuthState # Validates saved token to automatically unlock form on launch
Refresh-Sidebar
Reset-Editor
foreach ($m in $global:appConfig.Mounts) {
    if (Get-MountPID $m.DriveLetter) {
        Start-ConsoleFolderDeleteWatcher $m
    }
}

if ($startHidden) {
    $window.WindowState = [System.Windows.WindowState]::Minimized
    $window.ShowInTaskbar = $false
    $notifyIcon.Visible = $true
}

if (-not $global:WindowClosed) {
    try {
        $window.ShowDialog() | Out-Null
    } catch [System.InvalidOperationException] {
        Add-Content -Path $global:logPath -Value "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss') WARN  : Main window was already closed before ShowDialog could start: $($_.Exception.Message)" -ErrorAction SilentlyContinue
    }
}
