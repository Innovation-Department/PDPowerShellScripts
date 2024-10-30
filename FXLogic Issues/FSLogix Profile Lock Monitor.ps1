# FSLogix Profile Lock Monitor 
param(
    [Parameter(Mandatory=$false)]
    [string]$ProfilePath = "\\server\FSLogixProfiles", Where the FSLogixProfiles are located
    [string]$SMTPServer = "smtp.pape-dawson.com",
    [string]$EmailFrom = "fslogix-monitor@pape-dawson.com",
    [string]$EmailTo = "it-team@pape-dawson.com",
    [switch]$AttemptFix = $false
)

function Get-LockedProfiles {
    param (
        [string]$ProfilePath
    )
    
    try {
        # Get all profile VHD/VHDX files
        $profileContainers = Get-ChildItem -Path $ProfilePath -Recurse -Filter "*.vhd*"
        $lockedProfiles = @()

        foreach ($container in $profileContainers) {
            $lockFile = Join-Path $container.DirectoryName "$($container.BaseName).lock"
            if (Test-Path $lockFile) {
                # Check if the lock file is actually in use
                try {
                    $fileStream = [System.IO.File]::Open($lockFile, 'Open', 'Read', 'None')
                    $fileStream.Close()
                    $fileStream.Dispose()
                    
                    # If we can open the file, it's a stale lock
                    $lockedProfiles += @{
                        ProfilePath = $container.FullName
                        LockFile = $lockFile
                        Username = $container.Directory.Name
                        LastWriteTime = $container.LastWriteTime
                        StaleLock = $true
                    }
                }
                catch {
                    # If we can't open the file, it's actively locked
                    $lockedProfiles += @{
                        ProfilePath = $container.FullName
                        LockFile = $lockFile
                        Username = $container.Directory.Name
                        LastWriteTime = $container.LastWriteTime
                        StaleLock = $false
                    }
                }
            }
        }
        
        return $lockedProfiles
    }
    catch {
        Write-Error "Error checking locked profiles: $_"
        return $null
    }
}

function Get-ProcessesUsingProfile {
    param (
        [string]$ProfilePath
    )
    
    try {
        $handle = Join-Path $env:SystemRoot "System32\handle.exe"
        if (Test-Path $handle) {
            $output = & $handle $ProfilePath
            return $output | Where-Object { $_ -match "pid:" }
        }
        return $null
    }
    catch {
        Write-Error "Error getting processes using profile: $_"
        return $null
    }
}

function Clear-StaleLock {
    param (
        [string]$LockFile
    )
    
    try {
        if (Test-Path $LockFile) {
            Remove-Item -Path $LockFile -Force
            return $true
        }
        return $false
    }
    catch {
        Write-Error "Error clearing stale lock: $_"
        return $false
    }
}

function Send-LockAlert {
    param (
        [array]$LockedProfiles
    )

    $body = @"
FSLogix Profile Lock Issues Detected:

Total locked profiles: $($LockedProfiles.Count)

Details:
"@

    foreach ($profile in $LockedProfiles) {
        $body += @"

Username: $($profile.Username)
Profile Path: $($profile.ProfilePath)
Lock Status: $(if ($profile.StaleLock) { "Stale Lock" } else { "Active Lock" })
Last Write Time: $($profile.LastWriteTime)
"@
        
        $processes = Get-ProcessesUsingProfile -ProfilePath $profile.ProfilePath
        if ($processes) {
            $body += "`nProcesses using profile:`n$($processes -join "`n")"
        }
    }

    try {
        $emailParams = @{
            From = $EmailFrom
            To = $EmailTo
            Subject = "Alert: FSLogix Profile Lock Issues Detected"
            Body = $body
            SmtpServer = $SMTPServer
        }
        
        Send-MailMessage @emailParams -Priority High
        Write-Output "Alert email sent successfully"
    }
    catch {
        Write-Error "Failed to send email: $_"
    }
}

function Write-LogEntry {
    param(
        [string]$Message,
        [string]$Type = "Information"
    )
    
    $logPath = "C:\Logs\FSLogixMonitor"
    if (-not (Test-Path $logPath)) {
        New-Item -ItemType Directory -Path $logPath -Force | Out-Null
    }
    
    $logFile = Join-Path $logPath "FSLogixMonitor_$(Get-Date -Format 'yyyyMMdd').log"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [$Type] $Message" | Add-Content -Path $logFile
}

# Main execution
Write-LogEntry "Starting FSLogix profile lock monitoring..."

# Check for Handle.exe ##Jesse this needs to be downloaded 
# Download Handle.exe from Sysinternals and place in System32
#Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Handle.zip" -OutFile "$env:TEMP\Handle.zip"
#Expand-Archive -Path "$env:TEMP\Handle.zip" -DestinationPath "$env:SystemRoot\System32"


$handlePath = Join-Path $env:SystemRoot "System32\handle.exe"
if (-not (Test-Path $handlePath)) {
    Write-LogEntry "Sysinternals Handle.exe not found. Some functionality will be limited." -Type "Warning"
}

while ($true) {
    $lockedProfiles = Get-LockedProfiles -ProfilePath $ProfilePath
    
    if ($lockedProfiles -and $lockedProfiles.Count -gt 0) {
        Write-LogEntry "Found $($lockedProfiles.Count) locked profiles"
        Send-LockAlert -LockedProfiles $lockedProfiles
        
        if ($AttemptFix) {
            foreach ($profile in $lockedProfiles) {
                if ($profile.StaleLock) {
                    Write-LogEntry "Attempting to clear stale lock for $($profile.Username)"
                    if (Clear-StaleLock -LockFile $profile.LockFile) {
                        Write-LogEntry "Successfully cleared stale lock for $($profile.Username)"
                    }
                }
            }
        }
    }
    else {
        Write-LogEntry "No locked profiles found"
    }
    
    # Wait 5 minutes before next check
    Start-Sleep -Seconds 300
}

#.\Monitor-FSLogixLocks.ps1 -ProfilePath "\\server\FSLogixProfiles" -AttemptFix $true

