# VMware Horizon Session Troubleshooting Script
param(
    [Parameter(Mandatory=$true)]
    [string]$HorizonServer,
    [Parameter(Mandatory=$true)]
    [string]$Username,
    [PSCredential]$Credentials
)

function Initialize-HorizonConnection {
    try {
        Import-Module VMware.VimAutomation.HorizonView
        if (-not $Credentials) {
            $Credentials = Get-Credential -Message "Enter Horizon admin credentials"
        }
        $global:hvServer = Connect-HVServer -Server $HorizonServer -Credential $Credentials
        return $true
    }
    catch {
        Write-Error "Failed to connect to Horizon server: $_"
        return $false
    }
}

function Get-UserSessionInfo {
    param([string]$Username)
    
    try {
        $services = $global:hvServer.ExtensionData
        $queryService = $services.QueryService

        # Get user's sessions
        $sessions = $queryService.QuerySession() | Where-Object { $_.Username -like "*$Username*" }
        
        # Get user's entitled pools
        $pools = $queryService.QueryDesktopPool()
        $entitledPools = $pools | Where-Object {
            $_.Base.Name -in ($sessions.DesktopSummary.Name)
        }

        # Compile diagnostic information
        $diagnostics = @{
            Sessions = @()
            EntitledPools = @()
            PotentialIssues = @()
        }

        # Analyze sessions
        foreach ($session in $sessions) {
            $sessionInfo = @{
                DesktopName = $session.Desktop.Name
                PoolName = $session.Desktop.DesktopSummary.Name
                SessionState = $session.State
                SessionType = if ($session.Desktop.Source -eq "INSTANT_CLONE_ENGINE") { "Temporary" } else { "Persistent" }
                ConnectionTime = $session.StartTime
                ClientAddress = $session.ClientAddress
                Protocol = $session.Protocol
            }
            $diagnostics.Sessions += $sessionInfo

            # Check for potential issues
            if ($session.State -ne "CONNECTED") {
                $diagnostics.PotentialIssues += "Session state is $($session.State) for desktop $($session.Desktop.Name)"
            }
            if ($session.Desktop.Source -eq "INSTANT_CLONE_ENGINE") {
                $diagnostics.PotentialIssues += "Using temporary instant clone for desktop $($session.Desktop.Name)"
            }
        }

        # Analyze entitled pools
        foreach ($pool in $entitledPools) {
            $poolInfo = @{
                Name = $pool.Base.Name
                Type = $pool.Type
                Source = $pool.Source
                EnabledState = $pool.DesktopSettings.EnabledState
                MaxSessions = $pool.DesktopSettings.MaxNumberOfSessions
                CurrentSessions = $pool.DesktopSettings.MaxNumberOfSessions - $pool.DesktopSettings.AvailableSessionCount
            }
            $diagnostics.EntitledPools += $poolInfo

            # Check pool-related issues
            if ($pool.DesktopSettings.EnabledState -ne "ENABLED") {
                $diagnostics.PotentialIssues += "Pool $($pool.Base.Name) is not enabled"
            }
            if ($pool.DesktopSettings.AvailableSessionCount -eq 0) {
                $diagnostics.PotentialIssues += "Pool $($pool.Base.Name) has no available sessions"
            }
        }

        return $diagnostics
    }
    catch {
        Write-Error "Error getting user session info: $_"
        return $null
    }
}

# Main execution
Write-Output "Starting troubleshooting for user: $Username"

if (Initialize-HorizonConnection) {
    try {
        $diagnostics = Get-UserSessionInfo -Username $Username
        
        if ($diagnostics) {
            Write-Output "`nCurrent Sessions:"
            $diagnostics.Sessions | Format-Table -AutoSize

            Write-Output "`nEntitled Pools:"
            $diagnostics.EntitledPools | Format-Table -AutoSize

            if ($diagnostics.PotentialIssues.Count -gt 0) {
                Write-Output "`nPotential Issues Detected:"
                $diagnostics.PotentialIssues | ForEach-Object { Write-Output "- $_" }
                
                Write-Output "`nRecommended Actions:"
                Write-Output "1. Check user's AD account and group memberships"
                Write-Output "2. Verify network connectivity from client to Connection Server"
                Write-Output "3. Review Connection Server logs for authentication errors"
                Write-Output "4. Check pool capacity and availability"
                Write-Output "5. Verify user profile is not corrupted"
            } else {
                Write-Output "`nNo immediate issues detected."
            }
        }
    }
    finally {
        Disconnect-HVServer -Server $global:hvServer -Force -Confirm:$false
    }
}