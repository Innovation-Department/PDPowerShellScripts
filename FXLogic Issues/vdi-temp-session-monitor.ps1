# Monitor for PD Temporary Sessions
# Requires VMware PowerCLI and Autmation HorizonView modules
#Install-Module -Name VMware.PowerCLI -Scope AllUsers
#Install-Module -Name VMware.VimAutomation.HorizonView -Scope AllUsers

param(
    [Parameter(Mandatory=$true)]
    [string]$HorizonServer = "your-connection-server",
     [string]$SMTPServer = "smtp.pape-dawson.com",
    [string]$EmailFrom = "vdi-monitor@pape-dawson.com",
    [string]$EmailTo = "it-team@pape-dawson.com",
    [int]$CheckIntervalMinutes = 10,
    [PSCredential]$Credentials
)

# Function to initialize VMware Horizon connection
function Initialize-HorizonConnection {
    try {
        # Check if PowerCLI is installed
        if (!(Get-Module -ListAvailable VMware.VimAutomation.HorizonView)) {
            Write-Error "VMware PowerCLI with Horizon View module is not installed. Please install it first."
            return $false
        }

        # Import the module
        Import-Module VMware.VimAutomation.HorizonView

        # If credentials weren't provided, prompt for them
        if (-not $Credentials) {
            $Credentials = Get-Credential -Message "Enter credentials for Horizon Connection Server"
        }

        # Connect to Horizon Connection Server
        $global:hvServer = Connect-HVServer -Server $HorizonServer -Credential $Credentials
        
        if ($global:hvServer) {
            Write-Output "Successfully connected to Horizon Connection Server"
            return $true
        } else {
            Write-Error "Failed to connect to Horizon Connection Server"
            return $false
        }
    }
    catch {
        Write-Error "Error initializing Horizon connection: $_"
        return $false
    }
}

# Function to check for temporary sessions
function Get-TempSessions {
    try {
        $services = $global:hvServer.ExtensionData
        $queryService = $services.QueryService
        
        # Get all sessions
        $sessions = $queryService.QuerySession()
        
        # Filter for temporary/non-persistent sessions
        $tempSessions = $sessions | Where-Object { 
            $_.Desktop.Source -eq "INSTANT_CLONE_ENGINE" -or 
            $_.Desktop.PersistentDisk -eq $false -or
            $_.State -eq "NON_PERSISTENT"
        }
        
        return $tempSessions
    }
    catch {
        Write-Error "Error querying sessions: $_"
        return $null
    }
}

# Function to send email notification
function Send-TempSessionAlert {
    param (
        [Parameter(Mandatory=$true)]
        [array]$TempSessions
    )

    $body = @"
Temporary VMware Horizon Sessions Detected:

Total temporary sessions: $($TempSessions.Count)

Details:
"@

    foreach ($session in $TempSessions) {
        $body += @"

User: $($session.UserName)
Machine: $($session.Desktop.Name)
Desktop Pool: $($session.Desktop.DesktopSummary.Name)
State: $($session.State)
Session Type: $($session.Desktop.Source)
Start Time: $($session.StartTime)
Client Address: $($session.ClientAddress)
"@
    }

    try {
        $emailParams = @{
            From = $EmailFrom
            To = $EmailTo
            Subject = "Alert: Horizon Temporary Sessions Detected"
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

# Main script execution
Write-Output "Starting VMware Horizon temporary session monitoring..."

# Initialize Horizon connection
if (!(Initialize-HorizonConnection)) {
    Write-Error "Failed to initialize Horizon connection. Script will exit."
    exit 1
}

Write-Output "Starting monitoring loop..."

try {
    while ($true) {
        $tempSessions = Get-TempSessions

        if ($tempSessions -and $tempSessions.Count -gt 0) {
            Write-Output "Found $($tempSessions.Count) temporary sessions"
            Send-TempSessionAlert -TempSessions $tempSessions
        }
        else {
            Write-Output "No temporary sessions found at $(Get-Date)"
        }

        # Wait for the specified interval before next check
        Start-Sleep -Seconds ($CheckIntervalMinutes * 60)
    }
}
finally {
    # Disconnect from Horizon server when script finishes
    if ($global:hvServer) {
        Disconnect-HVServer -Server $global:hvServer -Force -Confirm:$false
    }
}


