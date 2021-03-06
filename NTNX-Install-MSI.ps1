############################################################
##
## Function: NTNX-Install-MSI
## Author: Steven Poitras
## Description: Automate bulk MSI installation
## Language: PowerShell
##
############################################################
function NTNX-Install-MSI {
<#
.NAME
	NTNX-Install-MSI
.SYNOPSIS
	Installs Nutanix package to Windows hosts
.DESCRIPTION
	Installs Nutanix package to Windows hosts
.NOTES
	Authors:  thedude@nutanix.com
	
	Logs: C:\Users\<USERNAME>\AppData\Local\Temp\NutanixCmdlets\logs
.LINK
	www.nutanix.com
.EXAMPLE
    NTNX-Install-MSI -installer "Nutanix-VirtIO-1.0.0.msi" `
		-cert "NutanixSoftware.cer" -localPath "C:\" `
		-computers $compArray -credential $(Get-Credential)
		
	NTNX-Install-MSI -installer "Nutanix-VirtIO-1.0.0.msi" `
		-cert "NutanixSoftware.cer" -localPath "C:\" `
		-computers "99.99.99.99"
#> 
	Param(
		[parameter(mandatory=$true)]$installer,
		
		[parameter(mandatory=$true)]$cert,
		
		[parameter(mandatory=$true)][AllowNull()]$localPath,
		
		[parameter(mandatory=$true)][Array]$computers,
		
		[parameter(mandatory=$false)][AllowNull()]$credential,
		
		[parameter(mandatory=$false)][Switch]$force
	)

	begin{
		# Pre-req message
		Write-host "NOTE: the following pre-requisites MUST be performed / valid before script execution:"
		Write-Host "	+ Nutanix installer must be downloaded and installed locally"
		Write-Host "	+ Export Nutanix Certificate in Trusted Publishers / Certificates"
		Write-Host "	+ Both should be located in c:\ if localPath not specified"
		
		if ($force.IsPresent) {
			Write-Host "Force flag specified, continuing..."
		} else {
			$input = Read-Host "Do you want to continue? [Y/N]"
				
			if ($input -ne 'y') {
				break
			}
		}

		if ($(Get-ExecutionPolicy) -ne 'Unrestricted') {
			Set-ExecutionPolicy Unrestricted -Scope CurrentUser -Force -Confirm:$false
		}
		
		Write-Host "Adding hosts to WinRM TrustedHosts..."
		winrm s winrm/config/client '@{TrustedHosts="*"}'
		
		$failedInstall = @()
		
		# Import modules and add snappins
		#Import-Module DnsClient

		# Installer and cert filenames
		if ([string]::IsNullOrEmpty($localPath)) {
			# Assume location is c:\
			$localPath = 'c:\'
		}
		
		# Path for ADMIN share used in transfer
		$adminShare = "C:\Windows\"
		
		# Format paths
		$localInstaller = $(Join-Path $localPath $installer)
		$localCert = $(Join-Path $localPath $cert)
		$remoteInstaller = $(Join-Path $adminShare $installer)
		$remoteCert = $(Join-Path $adminShare $cert)
		
		# Make sure files exist
		if (!(Test-Path -Path $localInstaller) -or !(Test-Path -Path $localCert)) {
			Write-Host "Warning one of more input files missing, exiting..."
			break
		}
		
		# Credential for remote PS connection
		if (!$credential) {
			$credential = Get-Credential -Message "Please enter domain admin credentials `
				Example: <SPLAB\superstevepo/*******>"
		}
		
		# Make sure drive doesn't exist
		Remove-PSDrive -Name P -ErrorAction SilentlyContinue
	
	}
	process {
		# For each computer copy file and install drivers
		$computers | %	{
			$vmConn = $null
			$l_vm = $_
			
			$vmType = $_.GetType().Name
			
			Write-Host "Object type is $vmType"
			
			# Determine passed object type
			Switch ($vmType) {
				# Nutanix object
				"VMDTO"	{$vmIP = $l_vm.ipAddresses}
				
				# VMware object
				"VirtualMachineImpl" {$vmIP = $l_vm.Guest.IPaddress | where {$_ -notmatch ":"}}
				
				# Hyper-V object
				"VirtualMachine" {$vmIP = $l_vm.NetworkAdapters.IPAddresses | where {$_ -notmatch ":"}}
				
				# Array object
				"Object[]" {$vmIP = $l_vm}
				
				# String
				"String" {$vmIP = $l_vm}
			}
			
			Write-Host "Found IPs: $vmIP"
			
			# For each IP try to connect until one is successful
			$vmIP | %{
				if(Test-Connection -ComputerName $_ -Count 3 -Quiet) {
					# Connection
					Write-Host "Successful connection on IP: $_"
					
					$vmConn = $_
					
					return
				} else {
					Write-Host "Unable to connect on IP: $_"
				}
			}
			
			# Make sure connection exists
			if ($vmConn -eq $null) {
				# No connection
				Write-Host "Unable to connect to VM, skipping..."
				return
			}
		
			# Create a new PS Drive
			New-PSDrive -Name P -PSProvider FileSystem -Root \\$vmConn\ADMIN$ `
				-Credential $credential | Out-Null
			
			# Copy virtio installer
			Write-Host "Copying installer to host..."
			Copy-Item  $localInstaller P:\$installer | Out-Null
			
			# Copy Nutanix cert
			Write-Host "Copying Nutanix Certificate to host..."
			Copy-Item $localCert P:\$cert | Out-Null
			
			# Create PS Session
			$sessionObj = New-PSSession -ComputerName $vmConn -Credential $credential
			
			# Install certificate for signing
			Write-Host "Installing certificate on host..."
			$certResponse = Invoke-Command -session $sessionObj -ScriptBlock {
				certutil -addstore "TrustedPublisher" $args[0]
			} -Args $remoteCert
			
			# Install driver silently
			Write-Host "Installing package on host..."
			$installResponse = Invoke-Command -session $sessionObj -ScriptBlock {
				$status = Start-Process -FilePath "msiexec.exe"  -ArgumentList `
					$args[0] -Wait -PassThru 
				
				return $status
			} -Args "/i $remoteInstaller /qn"
			
			# Check and return install status
			if ($installResponse.ExitCode -eq 0) {
				Write-Host "Installation of Nutanix package succeeded!"
			} else {
				Write-Host "Installation of Nutanix package failed..."
				$failedInstall += $l_vm
			}
			
			# Cleanup PS drive
			Remove-PSDrive -Name P
		
			# Cleanup session
			Disconnect-PSSession -Session $sessionObj -ErrorAction SilentlyContinue `
				| Remove-PSSession 

		}
	
	}
	end {
		# Return objects where install failed
		return $failedInstall
	}
}