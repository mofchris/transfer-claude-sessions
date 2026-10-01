#Requires -Version 5.1
<#
.SYNOPSIS
Copies Claude Desktop Code tab session records from one account to another so
the second account's sidebar shows them too.

.DESCRIPTION
Claude Desktop keeps one record file per Code tab session at

    %APPDATA%\Claude\claude-code-sessions\<accountId>\<orgId>\local_<id>.json

and the sidebar only lists the records under the signed-in account. This
script copies those records (and any matching local_<id> folder) from a
SOURCE account folder to a DESTINATION account folder.

Safety rules:
  * Refuses to run while Claude Desktop is open.
  * Dry run is the default. Nothing changes until you pass -Apply.
  * Backs up the whole claude-code-sessions folder before copying.
  * Copy only. Never moves or deletes. Only replaces a destination file when
    the source copy is newer, and logs every skip.
  * Never touches the transcripts in %USERPROFILE%\.claude\projects.
  * -Undo restores from a backup. The folder it replaces is kept, not deleted.

.PARAMETER Apply
Actually copy (or, with -Undo, actually restore). Without it the script only
prints what it would do.

.PARAMETER DryRun
Spell out that you want a dry run. This is already the default. If both
-DryRun and -Apply are given, dry run wins.

.PARAMETER Source
Optional. The number from the folder list, or the "accountId\orgId" text, to
use as the source without being asked.

.PARAMETER Destination
Optional. Same as -Source, for the destination.

.PARAMETER Undo
Restore the sessions folder from a backup made by an earlier -Apply run.
Add -Apply to actually restore; without it you see the plan only.

.PARAMETER BackupFolder
With -Undo: full path of the backup folder to restore. If omitted you pick
from the backups found under -BackupPath.

.PARAMETER BackupPath
Where backups and log files go. Default: your Desktop.

.PARAMETER SessionsRoot
Override the sessions folder. Only needed for testing against a copy.

.PARAMETER SkipProcessCheck
Skip the "is Claude running" check. Only honored together with a custom
-SessionsRoot, so it can never be used against the real folder.

.EXAMPLE
.\transfer-claude-sessions.ps1
Dry run. Lists the folders, asks for source and destination, prints the plan.

.EXAMPLE
.\transfer-claude-sessions.ps1 -Apply
Backs up, then copies for real.

.EXAMPLE
.\transfer-claude-sessions.ps1 -Source 2 -Destination 1 -Apply
Same, with the choices given up front.

.EXAMPLE
.\transfer-claude-sessions.ps1 -Undo -Apply
Pick a backup and restore it.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$DryRun,
    [string]$Source,
    [string]$Destination,
    [switch]$Undo,
    [string]$BackupFolder,
    [string]$BackupPath,
    [string]$SessionsRoot,
    [switch]$SkipProcessCheck
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------

$GuidPattern   = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$RecordPattern = '^local_[0-9a-fA-F-]+\.json$'
$Stamp         = Get-Date -Format 'yyyyMMdd-HHmmss'
$IsDryRun      = (-not $Apply) -or $DryRun

$DefaultRoot = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
$CustomRoot  = $false
if ($SessionsRoot) {
    $CustomRoot = ($SessionsRoot.TrimEnd('\') -ine $DefaultRoot.TrimEnd('\'))
} else {
    $SessionsRoot = $DefaultRoot
}
if (-not $BackupPath) { $BackupPath = [Environment]::GetFolderPath('Desktop') }

$ModeTag = 'apply'
if ($IsDryRun) { $ModeTag = 'dryrun' }
$OpTag = 'transfer'
if ($Undo) { $OpTag = 'undo' }

$BackupDir = Join-Path $BackupPath "claude-code-sessions-backup-$Stamp"
$LogFile   = Join-Path $BackupPath "claude-code-sessions-$OpTag-$ModeTag-$Stamp.log"

$script:LogLines = New-Object 'System.Collections.Generic.List[string]'
$script:Counts   = @{ Copied = 0; Replaced = 0; Skipped = 0; Failed = 0 }

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Write-Log {
    param(
        [AllowEmptyString()][string]$Message,
        [string]$Level = 'INFO',
        [ConsoleColor]$Color = 'Gray'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $script:LogLines.Add($line)
    Write-Host $Message -ForegroundColor $Color
}

function Save-Log {
    try {
        if (-not (Test-Path -LiteralPath $BackupPath)) {
            New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
        }
        $script:LogLines | Set-Content -LiteralPath $LogFile -Encoding UTF8
        Write-Host ''
        Write-Host "Log written to $LogFile" -ForegroundColor DarkGray
    } catch {
        Write-Host "Could not write the log file: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Fail {
    param([string]$Message)
    Write-Log $Message 'ERROR' Red
    Save-Log
    exit 1
}

function Rel {
    param([string]$Path)
    if ($Path.StartsWith($SessionsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($SessionsRoot.Length).TrimStart('\')
    }
    return $Path
}

function Assert-ClaudeClosed {
    if ($SkipProcessCheck -and $CustomRoot) {
        Write-Log 'Process check skipped (custom -SessionsRoot).' 'WARN' Yellow
        return
    }
    $procs = @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $pids = ($procs | ForEach-Object { $_.Id }) -join ', '
        Write-Log ("Claude Desktop is still running ({0} process(es), PID {1})." -f $procs.Count, $pids) 'ERROR' Red
        Fail ('Quit Claude Desktop completely first. Closing the window is not enough: ' +
              'right-click the Claude icon in the system tray (bottom right, next to the clock, ' +
              'possibly under the ^ arrow) and choose Quit. Then run this script again.')
    }
    Write-Log 'Claude Desktop is not running. Good.' 'INFO' Green
}

function Get-LastAccountId {
    $cfg = Join-Path (Split-Path -Path $SessionsRoot -Parent) 'config.json'
    try {
        if (Test-Path -LiteralPath $cfg) {
            $j = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
            if ($j.PSObject.Properties['lastKnownAccountUuid']) {
                return [string]$j.lastKnownAccountUuid
            }
        }
    } catch { }
    return $null
}

function Get-OrgFolders {
    $result = @()
    $accounts = @(Get-ChildItem -LiteralPath $SessionsRoot -Directory | Where-Object { $_.Name -match $GuidPattern })
    foreach ($acct in $accounts) {
        $orgs = @(Get-ChildItem -LiteralPath $acct.FullName -Directory | Where-Object { $_.Name -match $GuidPattern })
        foreach ($org in $orgs) {
            $records = @(Get-ChildItem -LiteralPath $org.FullName -File | Where-Object { $_.Name -match $RecordPattern })
            $latest = $null
            if ($records.Count -gt 0) {
                $latest = ($records | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
            }
            $result += [pscustomobject]@{
                Key       = '{0}\{1}' -f $acct.Name, $org.Name
                AccountId = $acct.Name
                OrgId     = $org.Name
                Path      = $org.FullName
                Count     = $records.Count
                Latest    = $latest
            }
        }
    }
    return $result
}

function Show-FolderTable {
    param($Folders, [string]$LastAccount)
    Write-Log ''
    Write-Log "Session folders under $SessionsRoot" 'INFO' Cyan
    $i = 1
    foreach ($f in $Folders) {
        $when = 'no records'
        if ($f.Latest) { $when = $f.Latest.ToString('yyyy-MM-dd HH:mm') }
        $tag = ''
        if ($LastAccount -and ($f.AccountId -ieq $LastAccount)) { $tag = '   <- account signed in most recently' }
        Write-Log ('  [{0}] {1,4} records   last modified {2,-16}   {3}{4}' -f $i, $f.Count, $when, $f.Key, $tag)
        $i++
    }
    Write-Log ''
}

function Resolve-Choice {
    param($Folders, [string]$Given, [string]$Role)
    $paramName = $Role.Substring(0, 1) + $Role.Substring(1).ToLower()
    if ($Given) {
        if ($Given -match '^\d+$') {
            $n = [int]$Given
            if ($n -ge 1 -and $n -le $Folders.Count) { return $Folders[$n - 1] }
            Fail "-$paramName $Given is out of range (1 to $($Folders.Count))."
        }
        $norm = $Given.Trim().TrimEnd('\').Replace('/', '\')
        $match = @($Folders | Where-Object {
            ($_.Key -ieq $norm) -or ($_.Path -ieq $norm) -or
            $_.Key.EndsWith($norm, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($match.Count -eq 1) { return $match[0] }
        Fail "-$paramName '$Given' did not match exactly one folder. Use the number from the list or the full accountId\orgId text."
    }
    while ($true) {
        $answer = Read-Host "Enter the number of the $Role folder"
        if ($answer -match '^\d+$') {
            $n = [int]$answer
            if ($n -ge 1 -and $n -le $Folders.Count) { return $Folders[$n - 1] }
        }
        Write-Host "Please enter a number between 1 and $($Folders.Count)." -ForegroundColor Yellow
    }
}

function Test-Record {
    param([System.IO.FileInfo]$File)
    try {
        $j = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
        if ($null -eq $j) { return $false }
        if (-not $j.PSObject.Properties['sessionId']) { return $false }
        return $true
    } catch {
        return $false
    }
}

function New-PlanItem {
    param([string]$Action, [string]$Src, [string]$Dst, [string]$Reason)
    return [pscustomobject]@{ Action = $Action; Src = $Src; Dst = $Dst; Reason = $Reason }
}

function Get-FileDecision {
    param([System.IO.FileInfo]$SrcFile, [string]$DstPath)
    if (-not (Test-Path -LiteralPath $DstPath)) {
        return New-PlanItem 'Copy' $SrcFile.FullName $DstPath 'not in destination'
    }
    $dst = Get-Item -LiteralPath $DstPath
    if ($SrcFile.LastWriteTimeUtc -gt $dst.LastWriteTimeUtc) {
        $why = 'source is newer ({0} vs {1})' -f $SrcFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $dst.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        return New-PlanItem 'Replace' $SrcFile.FullName $DstPath $why
    }
    return New-PlanItem 'Skip' $SrcFile.FullName $DstPath 'destination already has it, same age or newer'
}

function Build-Plan {
    param($Src, $Dst)
    $plan = @()
    $records = @(Get-ChildItem -LiteralPath $Src.Path -File | Where-Object { $_.Name -match $RecordPattern } | Sort-Object Name)
    foreach ($r in $records) {
        $dstFile = Join-Path $Dst.Path $r.Name
        if (-not (Test-Record $r)) {
            $plan += New-PlanItem 'Invalid' $r.FullName $dstFile 'does not parse as a session record (no sessionId), not copied'
            continue
        }
        $plan += Get-FileDecision $r $dstFile

        $id     = [System.IO.Path]::GetFileNameWithoutExtension($r.Name)
        $srcDir = Join-Path $Src.Path $id
        if (Test-Path -LiteralPath $srcDir -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $srcDir -File -Recurse -Force)
            foreach ($f in $files) {
                $relPath = $f.FullName.Substring($srcDir.Length).TrimStart('\')
                $dstPath = Join-Path (Join-Path $Dst.Path $id) $relPath
                $plan += Get-FileDecision $f $dstPath
            }
        }
    }
    return $plan
}

function Show-Plan {
    param($Plan)
    $copy    = @($Plan | Where-Object { $_.Action -eq 'Copy' }).Count
    $replace = @($Plan | Where-Object { $_.Action -eq 'Replace' }).Count
    $skip    = @($Plan | Where-Object { $_.Action -eq 'Skip' }).Count
    $invalid = @($Plan | Where-Object { $_.Action -eq 'Invalid' }).Count
    Write-Log ('Plan: {0} to copy, {1} to replace (source newer), {2} to skip, {3} invalid' -f $copy, $replace, $skip, $invalid) 'INFO' Cyan
    foreach ($p in $Plan) {
        $color = 'Gray'
        switch ($p.Action) {
            'Copy'    { $color = 'Green' }
            'Replace' { $color = 'Yellow' }
            'Skip'    { $color = 'DarkGray' }
            'Invalid' { $color = 'Magenta' }
        }
        Write-Log ('  {0,-8} {1}   ({2})' -f $p.Action.ToUpper(), (Rel $p.Src), $p.Reason) 'PLAN' $color
    }
    Write-Log ''
}

function New-Backup {
    Write-Log "Backing up $SessionsRoot" 'INFO' Cyan
    Write-Log "        to $BackupDir"
    if (Test-Path -LiteralPath $BackupDir) { Fail "Backup folder already exists: $BackupDir" }
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    Copy-Item -Path (Join-Path $SessionsRoot '*') -Destination $BackupDir -Recurse -Force
    $srcCount = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Force).Count
    $bakCount = @(Get-ChildItem -LiteralPath $BackupDir -Recurse -File -Force).Count
    if ($srcCount -ne $bakCount) {
        Fail "Backup check failed: $srcCount files in the sessions folder, $bakCount in the backup. Nothing has been copied into the destination. Stopping."
    }
    Write-Log "Backup complete and verified: $bakCount files." 'INFO' Green
    Write-Log ''
}

function Invoke-Plan {
    param($Plan)
    foreach ($p in $Plan) {
        switch ($p.Action) {
            'Skip' {
                $script:Counts.Skipped++
                Write-Log ('  SKIP     {0}   ({1})' -f (Rel $p.Src), $p.Reason) 'SKIP' DarkGray
            }
            'Invalid' {
                $script:Counts.Skipped++
                Write-Log ('  SKIP     {0}   ({1})' -f (Rel $p.Src), $p.Reason) 'SKIP' Magenta
            }
            default {
                try {
                    $dir = Split-Path -Path $p.Dst -Parent
                    if (-not (Test-Path -LiteralPath $dir)) {
                        New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $p.Src -Destination $p.Dst -Force
                    if ($p.Action -eq 'Replace') { $script:Counts.Replaced++ } else { $script:Counts.Copied++ }
                    Write-Log ('  {0,-8} {1}' -f $p.Action.ToUpper(), (Rel $p.Src)) 'COPY' Green
                } catch {
                    $script:Counts.Failed++
                    Write-Log ('  FAILED   {0}: {1}' -f (Rel $p.Src), $_.Exception.Message) 'FAIL' Red
                }
            }
        }
    }
}

function Invoke-Undo {
    $backup = $null
    if ($BackupFolder) {
        if (-not (Test-Path -LiteralPath $BackupFolder -PathType Container)) {
            Fail "Backup folder not found: $BackupFolder"
        }
        $backup = Get-Item -LiteralPath $BackupFolder
    } else {
        if (-not (Test-Path -LiteralPath $BackupPath)) {
            Fail "Backup location not found: $BackupPath"
        }
        $cands = @(Get-ChildItem -LiteralPath $BackupPath -Directory -Filter 'claude-code-sessions-backup-*' | Sort-Object Name -Descending)
        if ($cands.Count -eq 0) {
            Fail "No backups found under $BackupPath. Pass -BackupFolder <path> if the backup is somewhere else."
        }
        Write-Log ''
        Write-Log "Backups found under $BackupPath" 'INFO' Cyan
        for ($i = 0; $i -lt $cands.Count; $i++) {
            $n = @(Get-ChildItem -LiteralPath $cands[$i].FullName -Recurse -File -Force).Count
            Write-Log ('  [{0}] {1}   ({2} files, created {3})' -f ($i + 1), $cands[$i].Name, $n, $cands[$i].CreationTime.ToString('yyyy-MM-dd HH:mm'))
        }
        Write-Log ''
        while ($true) {
            $a = Read-Host 'Enter the number of the backup to restore'
            if ($a -match '^\d+$') {
                $k = [int]$a
                if ($k -ge 1 -and $k -le $cands.Count) { $backup = $cands[$k - 1]; break }
            }
            Write-Host "Please enter a number between 1 and $($cands.Count)." -ForegroundColor Yellow
        }
    }

    $orgDirs = @(Get-ChildItem -LiteralPath $backup.FullName -Directory |
        Where-Object { $_.Name -match $GuidPattern } |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } |
        Where-Object { $_.Name -match $GuidPattern })
    if ($orgDirs.Count -eq 0) {
        Fail 'That folder does not look like a sessions backup (no accountId\orgId folders inside). Nothing was changed.'
    }

    $aside     = Join-Path $BackupPath "claude-code-sessions-before-undo-$Stamp"
    $fileCount = @(Get-ChildItem -LiteralPath $backup.FullName -Recurse -File -Force).Count

    Write-Log ''
    Write-Log 'Undo plan:' 'INFO' Cyan
    Write-Log "  1. Move the current folder   $SessionsRoot"
    Write-Log "     aside to                  $aside   (kept, not deleted)"
    Write-Log "  2. Copy the backup           $($backup.FullName)   ($fileCount files)"
    Write-Log "     back to                   $SessionsRoot"
    Write-Log ''

    if ($IsDryRun) {
        Write-Log 'DRY RUN: nothing was changed. If this looks right, run again with -Undo -Apply.' 'INFO' Yellow
        return
    }

    try {
        if (Test-Path -LiteralPath $SessionsRoot) {
            Move-Item -LiteralPath $SessionsRoot -Destination $aside
        }
        New-Item -ItemType Directory -Path $SessionsRoot -Force | Out-Null
        Copy-Item -Path (Join-Path $backup.FullName '*') -Destination $SessionsRoot -Recurse -Force
        $restored = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Force).Count
        if ($restored -ne $fileCount) {
            Fail "Restore check failed: $fileCount files in the backup, $restored restored. Your previous folder is intact at $aside"
        }
        Write-Log "Restored $restored files from the backup." 'INFO' Green
        Write-Log "Your previous sessions folder was kept at $aside" 'INFO' Green
        Write-Log 'You can delete that folder yourself once you are happy with the result.'
    } catch {
        Fail "Undo failed: $($_.Exception.Message). If the move already happened, your previous folder is at $aside"
    }
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

try {
    $modeText = 'APPLY (files will be copied)'
    if ($IsDryRun) { $modeText = 'DRY RUN (nothing will change)' }
    Write-Host ''
    Write-Log "transfer-claude-sessions   mode: $modeText" 'INFO' Cyan
    if ($CustomRoot) { Write-Log "Using custom sessions folder: $SessionsRoot" 'WARN' Yellow }

    if (-not (Test-Path -LiteralPath $SessionsRoot -PathType Container)) {
        Fail ("Sessions folder not found: $SessionsRoot. Claude Desktop creates it the first time the Code tab " +
              'is opened. If you have never used the Code tab on this computer there is nothing to transfer yet.')
    }

    Assert-ClaudeClosed

    if ($Undo) {
        Invoke-Undo
        Save-Log
        exit 0
    }

    $folders = @(Get-OrgFolders)
    if ($folders.Count -eq 0) {
        Fail ("No accountId\orgId folders found under $SessionsRoot. The layout may have changed in your version " +
              'of Claude Desktop. Nothing was touched.')
    }

    Show-FolderTable $folders (Get-LastAccountId)

    if ($folders.Count -lt 2) {
        Fail ('Only one account folder exists, so there is nowhere to copy to. Open Claude Desktop, sign into the ' +
              'NEW account, open the Code tab once so the app creates its folder, quit Claude fully, then run this again.')
    }

    $src = Resolve-Choice $folders $Source 'SOURCE'
    if ($src.Count -eq 0) { Fail "Source folder $($src.Key) has no session records. Pick the folder you want to copy FROM." }
    $dst = Resolve-Choice $folders $Destination 'DESTINATION'
    if ($src.Key -ieq $dst.Key) { Fail 'Source and destination are the same folder. Nothing to do.' }

    Write-Log ''
    Write-Log ("Source:      {0}   ({1} records)" -f $src.Key, $src.Count) 'INFO' White
    Write-Log ("Destination: {0}   ({1} records)" -f $dst.Key, $dst.Count) 'INFO' White
    Write-Log ''

    $plan = @(Build-Plan $src $dst)
    Show-Plan $plan

    $work = @($plan | Where-Object { ($_.Action -eq 'Copy') -or ($_.Action -eq 'Replace') })

    if ($IsDryRun) {
        Write-Log 'DRY RUN: nothing was copied. If the plan looks right, run again with -Apply.' 'INFO' Yellow
        Save-Log
        exit 0
    }

    if ($work.Count -eq 0) {
        Write-Log 'Nothing to copy. The destination already has every record from the source.' 'INFO' Green
        Save-Log
        exit 0
    }

    New-Backup
    Write-Log 'Copying...' 'INFO' Cyan
    Invoke-Plan $plan

    Write-Log ''
    Write-Log 'Summary' 'INFO' Cyan
    Write-Log ('  copied:   {0}' -f $script:Counts.Copied)   'INFO' Green
    Write-Log ('  replaced: {0}   (destination had an older copy)' -f $script:Counts.Replaced) 'INFO' Yellow
    Write-Log ('  skipped:  {0}' -f $script:Counts.Skipped)  'INFO' DarkGray
    $failColor = 'DarkGray'
    if ($script:Counts.Failed -gt 0) { $failColor = 'Red' }
    Write-Log ('  failed:   {0}' -f $script:Counts.Failed)   'INFO' $failColor
    Write-Log ''
    Write-Log "Backup: $BackupDir" 'INFO' White
    Write-Log ''
    Write-Log 'Next steps:' 'INFO' Cyan
    Write-Log '  1. Open Claude Desktop and sign into the destination account.'
    Write-Log '  2. Open the Code tab. The copied sessions should now be in the sidebar.'
    Write-Log '  3. If anything looks wrong, quit Claude fully and run:'
    Write-Log "       .\transfer-claude-sessions.ps1 -Undo -Apply -BackupFolder `"$BackupDir`""
    Save-Log
    if ($script:Counts.Failed -gt 0) { exit 2 }
    exit 0
} catch {
    Write-Log "Unexpected error: $($_.Exception.Message)" 'ERROR' Red
    Write-Log $_.ScriptStackTrace 'ERROR' DarkRed
    Save-Log
    exit 1
}
