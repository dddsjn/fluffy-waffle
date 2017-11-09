<# 
 
 
 
.SYNOPSIS 
 
 
 
V1 - Prepares one or more servers for automated patching via SCCM.

 
.DESCRIPTION 
 
1) Add to AD group 'Server SCCM Config'
2) Add to ADR collection in SCCM
3) Add to MW collection in SCCM
4) Run 'klist –li 0x3e7 purge' on server
5) Run gpupdate
 
 
 
.NOTES 
 
Parts 2 and 3 in the description will not work on Windows 2008 / Windows 2008 R2 servers
due to Powershell not being configured for remote access. These commands will
need to be run manually on the server.

 
 
#>

Import-Module 'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1' # Import the ConfigurationManager.psd1 module
$origdir = pwd
Set-Location 'CM1:' # Set the current location to be the SCCM site code.

Function Get-FileName($initialDirectory)
{
    [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null
    
    $OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $OpenFileDialog.initialDirectory = $initialDirectory
    $OpenFileDialog.filter = "TXT (*.txt)| *.txt"
    $OpenFileDialog.ShowDialog() | Out-Null
    $OpenFileDialog.filename
}

clear-host
write-output "Please select a text file containing a list of servers to be configured for automated patching by SCCM"
start-sleep -s 2
$serverfile = Get-FileName "C:\temp"
$serverlist = Get-Content $serverfile

Write-Output "Servers to be configured for SCCM patching $serverlist"

$adgroup = "Server SCCM Config" 

$mwcollArray = @()
$mwcollArray +=  Get-CMDeviceCollection -Id CM1001E3   # MW-1-Thursday-1800-2100
$mwcollArray +=  Get-CMDeviceCollection -Id CM100213   # MW-2-Thursday-2100-2300


foreach ($server in $serverlist) {
    
    # SCCM Device collection array
    $adrcollArray = @()
    $status = 0

    write-output "*****************************************"

    Write-Host "Check $server is in AD ..." -nonewline
    try {
        $comaccount = Get-ADComputer -Identity $server -Properties OperatingSystem -ErrorAction Stop
        $status += 1
        write-host "Success"
    } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] { 
        write-host "$server not in AD and will not be configured for SCCM patching" -ForegroundColor red
        Continue 
    }
     
    Write-Host "Add $server to 'Server SCCM Config' AD group ..." -nonewline
    try { 
        Add-ADGroupMember -identity "CN=Server SCCM Config,OU=Permissions Groups and Users,DC=norfolk,DC=police,DC=uk" -Members $comaccount.DistinguishedName
        $status += 1
        write-host "Success"
    } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException]{ 
        write-host "Unable to find 'server sccm config' group in AD. Check if it exists or has moved, and amendd the script as required." -ForegroundColor Red
    }

    $os = $comaccount.operatingsystem

    switch -wildcard ($os)
    {
    "Windows Server® 2008 Standard*" { $adrcollArray +=  Get-CMDeviceCollection -Id CM100208   # MW - ADR Mapped - Windows 2008 (Reboot Enabled)
                                       $adrcollArray +=  Get-CMDeviceCollection -Id CM100206   # MW - ADR Mapped - Windows 2008 (Reboot Restricted) 
                                     }
    "Windows Server 2008 R2 Standard" { $adrcollArray +=  Get-CMDeviceCollection -Id CM100204   # MW - ADR Mapped - Windows 2008 R2 (Reboot Enabled)
                                        $adrcollArray +=  Get-CMDeviceCollection -Id CM100205   # MW - ADR Mapped - Windows 2008 R2 (Reboot Restricted)
                               }
    "Windows Server 2012 R2 Standard" { $adrcollArray +=  Get-CMDeviceCollection -Id CM1001FD   # MW - ADR Mapped - Windows 2012 R2 (Reboot Enabled)
                                        $adrcollArray +=  Get-CMDeviceCollection -Id CM1001FE   # MW - ADR Mapped - Windows 2012 R2 (Reboot Restricted)
                               }
    "Windows Server 2016 Standard" { $adrcollArray +=  Get-CMDeviceCollection -Id CM10020D   # MW - ADR Mapped - Windows 2016 (Reboot Enabled)
                                     $adrcollArray +=  Get-CMDeviceCollection -Id CM10020C   # MW - ADR Mapped - Windows 2016 (Reboot Restricted)
                            }                                                                                                                 
    }

    # Add server to SCCM collections
    Write-Host "Add $server to SCCM ADR collection..." -nonewline
    $cmdevice = get-cmdevice -Name $server

    # Add to ADR device collection
    $adrcoll = $adrcollArray | select Name, CollectionID | Out-GridView -PassThru -Title "$server ($os) - Select a device collection"
    try {
        Add-CMDeviceCollectionDirectMembershipRule -CollectionId $adrcoll.CollectionID -ResourceId $cmdevice.ResourceID
        $status += 1
        write-host "Success"
    } catch [System.ArgumentException] {
        write-host "Looks like $server may already be in that collection. No action taken." -ForegroundColor Yellow
    }  

    # Add to maintenance window collection
    Write-Host "Add $server to SCCM MW collection..." -nonewline

    $mwcoll = $mwcollArray | select Name, CollectionID, LocalMemberCount | Out-GridView -PassThru -Title "$server ($os) -  Select a maintenance window collection"
    try {
        Add-CMDeviceCollectionDirectMembershipRule -CollectionId $mwcoll.CollectionID -ResourceId $cmdevice.ResourceID
        $status += 1
        write-host "Success"
    } catch [System.ArgumentException] {
        write-host "Looks like $server may already be in that collection. No action taken." -ForegroundColor Yellow
    } 

    switch -wildcard ($os) {
    "Windows Server® 2008 standard*" { Write-Host "As the server runs $os, run the following command manually on the server:  klist –li 0x3e7 purge " -ForegroundColor Yellow}
    default { 
            # Update server kerberos ticket
            Write-Output "Updating server kerberos ticket on $server..."
            try  {
                Invoke-Command -ComputerName $server -scriptblock {klist –li 0x3e7 purge} -ErrorAction Stop
                $status += 1
                Write-Host "Success"

            } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
                write-host "Unable to PSremote on to $server. It may be down or WinRM not enabled. Run command " -NoNewline -ForegroundColor Yellow
                write-host "klist –li 0x3e7 purge " -ForegroundColor white -NoNewline
                Write-Host "on the server" -ForegroundColor yellow
            }

            # Run GPUpdate
            Write-Output "Running GPUPDATE on $server. Please wait..."
            try {
                Invoke-Command -ComputerName $server -scriptblock {gpupdate /force} -ErrorAction Stop
                $status += 1
                Write-Host "Success"

            } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
                write-host "Unable to PSremote on to $server. It may be down or WinRM not enabled. Run command " -NoNewline -ForegroundColor Yellow
                write-host "gpupdate /force " -ForegroundColor white -NoNewline
                Write-Host "on the server" -ForegroundColor yellow
            } 
        }    
    }
    
    write-output "*****************************************"
    
    if ($status -eq 6) {                                                                                                                                                                                                                                                                                            
        Write-Host "$server successfully configured for SCCM automated patching." -ForegroundColor Green
        Write-Host " Remember to update the patch sheet, RDG and ping files." -ForegroundColor Green
    }
    else {
        Write-Host "$server partial success for the configuration of SCCM automated patching. " -ForegroundColor yellow
        Write-Host "Review messages and take manual actions as required. " -ForegroundColor yellow
        Write-Host "If server is Windows 2008 or Windows 2008 R2, run command " -ForegroundColor yello -NoNewline  
        write-host "klist –li 0x3e7 purge" -ForegroundColor white -NoNewline
        write-host " manually on server." -ForegroundColor yellow
    }
    
    write-output "*****************************************"
}

# Cleanup
Set-Location $origdir
