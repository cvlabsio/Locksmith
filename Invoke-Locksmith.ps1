<#
.SYNOPSIS
Finds the most common malconfigurations of Active Directory Certificate Services (AD CS).

.DESCRIPTION
Locksmith uses the Active Directory (DA) Powershell (PS) module to identify 6 misconfigurations
commonly found in Enterprise mode AD CS installations.

.COMPONENT
Locksmith requires the AD PS module to be installed in the scope of the Current User.
If Locksmith does not identify the AD PS module as installed, it will attempt to 
install the module. If module installation does not complete successfully, 
Locksmith will fail.

.PARAMETER Mode
Specifies sets of common configurations.
-Mode 0
Finds and displays any malconfiguration in the console.
No attempt is made to fix identified issues.

-Mode 1
Finds and displays any malconfiguration in the console.
Displays example Powershell snippet that can be used to resolve the issue.
No attempt is made to fix identified issues.

-Mode 2
Finds any malconfigurations and writes them to a series of CSV files.
No attempt is made to fix identified issues.

-Mode 3
Finds any malconfigurations and writes them to a series of CSV files.
Creates code snippets to fix each issue and writes them to an environment-specific custom .ps1 file.
No attempt is made to fix identified issues.

-Mode 4
Creates code snippets to fix each issue.
Attempts to fix all identified issues. This mode may require high-privileged access.

.INPUTS
None. You cannot pipe objects to Invoke-Locksmith.ps1.

.OUTPUTS
Output types:
1. Console display of identified issues
2. Console display of identified issues and their fixes
3. CSV containing all identified issues
4. CSV containing all identified issues and their fixes
#>

# Windows PowerShell cmdlet Restart-Service requires RunAsAdministrator
#Requires -Version 3.0

[CmdletBinding()]
param (
    [string]$Forest,
    [string]$InputPath,
    [int]$Mode = 0,
    [string]$OutputPath = (Get-Location).Path
)

$Logo = "
 _       _____  _______ _     _ _______ _______ _____ _______ _     _
 |      |     | |       |____/  |______ |  |  |   |      |    |_____|
 |_____ |_____| |_____  |    \_ ______| |  |  | __|__    |    |     |
     .--.                  .--.                  .--.            
    /.-. '----------.     /.-. '----------.     /.-. '----------.
    \'-' .--'--''-'-'     \'-' .--'--''-'-'     \'-' .--'--''-'-'
     '--'                  '--'                  '--'            
"


$SafeOwners = "$env:USERDOMAIN\\Domain Admins|$env:USERDOMAIN\\Enterprise Admins|BUILTIN\\Administrators|NT AUTHORITY\\SYSTEM|$env:USERDOMAIN\\Cert Publishers|$env:USERDOMAIN\\Administrator"
$SafeUsers = "$env:USERDOMAIN\\Domain Admins|$env:USERDOMAIN\\Enterprise Admins|BUILTIN\\Administrators|NT AUTHORITY\\SYSTEM|$env:USERDOMAIN\\Cert Publishers|$env:USERDOMAIN\\Administrator|$env:USERDOMAIN\\Domain Controllers|$env:USERDOMAIN\\Enterprise Domain Controllers"
$Admins = @('Domain Admins','Enterprise Admins','Administrators')
$AdminUsers = $Admins | ForEach-Object { (Get-ADGroupMember $_ | Where-Object { $_.objectClass -eq 'user'}).SamAccountName } | Select-Object -Unique
$AdminUsers | ForEach-Object { $SafeUsers += "|$($env:USERDOMAIN)\\" + $_ }
$ClientAuthEKUs = '1\.3\.6\.1\.5\.5\.7\.3\.2|1\.3\.6\.1\.5\.2\.3\.4|1\.3\.6\.1\.4\.1\.311\.20\.2\.2|2\.5\.29\.37\.0'
$DangerousRights = 'GenericAll|WriteDacl|WriteOwner'

function Get-Target {
    param (
        [string]$Forest,
        [string]$InputPath
    )

    if ($Forest) {
        $Targets = $Forest
    } elseif ($InputPath) {
        $Targets = Get-Content $InputPath
    } else {
        $Targets = (Get-ADForest).Name
    }
    return $Targets
}


function New-OutputPath {
    [CmdletBinding(SupportsShouldProcess)]
    param ()
    # Create one output directory per forest
    foreach ( $forest in $Targets ) {
        $ForestPath = $OutputPath + "`\" + $forest
        New-Item -Path $ForestPath -ItemType Directory -Force  | Out-Null
    }
}


function Get-ADCSObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Targets
    )
    foreach ( $forest in $Targets ) {
        $ADRoot = (Get-ADRootDSE -Server $forest).defaultNamingContext
        Get-ADObject -Filter * -SearchBase "CN=Public Key Services,CN=Services,CN=Configuration,$ADRoot" -SearchScope 2 -Properties * 
    }
}


function Set-AdditionalCAProperty {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [parameter(
            Mandatory = $true,
            ValueFromPipeline = $true)]
        [array]$ADCSObjects
    )
    process {
        $ADCSObjects | Where-Object objectClass -Match 'pKIEnrollmentService' | ForEach-Object {
            [string]$CAFullName = "$($_.dNSHostName)\$($_.Name)"
            $CAHostname = $_.dNSHostName.split('.')[0]
            $CAHostDistinguishedName = (Get-ADObject -Filter { (Name -eq $CAHostName) -and (objectclass -eq 'computer') }).DistinguishedName
            certutil.exe -config $CAFullName -ping | Out-Null
            if ($LASTEXITCODE -eq 0) {
                try {
                    $CertutilAudit = certutil -config $CAFullName -getreg CA\AuditFilter
                } catch {
                    $AuditFilter = 'Failure'
                }
                try {
                    $CertutilFlag = certutil -config $CAFullName -getreg policy\EditFlags
                } catch {
                    $AuditFilter = 'Failure'
                }
            } else {
                $AuditFilter = 'CA Unavailable'
                $SANFlag = 'CA Unavailable'
            }
            if ($CertutilAudit) {
                try {
                    [string]$AuditFilter = $CertutilAudit | Select-String 'AuditFilter REG_DWORD = ' | Select-String '\('
                    $AuditFilter = $AuditFilter.split('(')[1].split(')')[0]
                } catch {
                    try {
                        [string]$AuditFilter = $CertutilAudit | Select-String 'AuditFilter REG_DWORD = '
                        $AuditFilter = $AuditFilter.split('=')[1].trim()
                    } catch {
                        $AuditFilter = 'Never Configured'
                    }
                }
            }
            if ($CertutilFlag) {
                [string]$SANFlag = $CertutilFlag | Select-String ' EDITF_ATTRIBUTESUBJECTALTNAME2 -- 40000 \('
                if ($SANFlag) {
                    $SANFlag = 'Yes'
                } else {
                    $SANFlag = 'No'
                }
            }
            Add-Member -InputObject $_ -MemberType NoteProperty -Name AuditFilter -Value $AuditFilter -Force
            Add-Member -InputObject $_ -MemberType NoteProperty -Name CAFullName -Value $CAFullName -Force
            Add-Member -InputObject $_ -MemberType NoteProperty -Name CAHostname -Value $CAHostname -Force
            Add-Member -InputObject $_ -MemberType NoteProperty -Name CAHostDistinguishedName -Value $CAHostDistinguishedName -Force
            Add-Member -InputObject $_ -MemberType NoteProperty -Name SANFlag -Value $SANFlag -Force
        }
    }
}


function Get-CAHostObject {
    [CmdletBinding()]
    param (
        [parameter(
            Mandatory = $true,
            ValueFromPipeline = $true)]
        [array]$ADCSObjects
    )
    process {
        $ADCSObjects | Where-Object objectClass -Match 'pKIEnrollmentService' | ForEach-Object {
            Get-ADObject $_.CAHostDistinguishedName -Properties *
        }
    }
}


function Find-AuditingIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ADCSObjects
    )
    $ADCSObjects | Where-Object {
        ($_.objectClass -eq 'pKIEnrollmentService') -and
        ($_.AuditFilter -ne '127')
    } | ForEach-Object {
        $Issue = New-Object -TypeName pscustomobject
        $Issue | Add-Member -MemberType NoteProperty -Name Forest -Value $_.CanonicalName.split('/')[0] -Force
        $Issue | Add-Member -MemberType NoteProperty -Name Name -Value $_.Name -Force
        $Issue | Add-Member -MemberType NoteProperty -Name DistinguishedName -Value $_.DistinguishedName -Force
        if ($_.AuditFilter -match 'CA Unavailable') {
            $Issue | Add-Member -MemberType NoteProperty -Name Issue -Value $_.AuditFilter -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Fix -Value 'N/A' -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Revert -Value 'N/A' -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Technique -Value 'DETECT' -Force
        } else {
            $Issue | Add-Member -MemberType NoteProperty -Name Issue -Value "Auditing is not fully enabled. Current value is $($_.AuditFilter)" -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Fix `
                -Value "certutil -config `'$($_.CAFullname)`' -setreg `'CA\AuditFilter`' 127; Invoke-Command -ComputerName `'$($_.dNSHostName)`' -ScriptBlock { Get-Service -Name `'certsvc`' | Restart-Service -Force }" -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Revert `
                -Value "certutil -config $($_.CAFullname) -setreg CA\AuditFilter  $($_.AuditFilter); Invoke-Command -ComputerName `'$($_.dNSHostName)`' -ScriptBlock { Get-Service -Name `'certsvc`' | Restart-Service -Force }" -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Technique -Value 'DETECT' -Force
        }
        $Issue
    }
}


function Find-ESC1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ADCSObjects,
        [Parameter(Mandatory = $true)]
        [array]$SafeUsers
    )
    $ADCSObjects | Where-Object {
        ($_.objectClass -eq 'pKICertificateTemplate') -and
        ($_.pkiExtendedKeyUsage -match $ClientAuthEKUs) -and
        ($_.'msPKI-Certificate-Name-Flag' -eq 1) -and
        ($_.'msPKI-Enrollment-Flag' -ne 2) -and
        ( ($_.'msPKI-RA-Signature' -eq 0) -or ($null -eq $_.'msPKI-RA-Signature') )
    } | ForEach-Object {
        foreach($entry in $_.nTSecurityDescriptor.Access) {
            if ( ($entry.IdentityReference -notmatch $SafeUsers) -and ($entry.ActiveDirectoryRights -match 'ExtendedRight') ) {
                $Issue = New-Object -TypeName pscustomobject
                $Issue | Add-Member -MemberType NoteProperty -Name Forest -Value $_.CanonicalName.split('/')[0] -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Name -Value $_.Name -Force
                $Issue | Add-Member -MemberType NoteProperty -Name DistinguishedName -Value $_.DistinguishedName -Force
                $Issue | Add-Member -MemberType NoteProperty -Name IdentityReference -Value $entry.IdentityReference -Force
                $Issue | Add-Member -MemberType NoteProperty -Name ActiveDirectoryRights -Value $entry.ActiveDirectoryRights -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Issue `
                    -Value "$($entry.IdentityReference) can enroll in this Client Authentication template using a SAN without Manager Approval"  -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Fix `
                    -Value "Get-ADObject `'$($_.DistinguishedName)`' | Set-ADObject -Replace @{'msPKI-Certificate-Name-Flag' = 0}" -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Revert `
                    -Value "Get-ADObject `'$($_.DistinguishedName)`' | Set-ADObject -Replace @{'msPKI-Certificate-Name-Flag' = 1}"  -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Technique -Value 'ESC1'
                $Issue
            }
        }
    }
}


function Find-ESC2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ADCSObjects,
        [Parameter(Mandatory = $true)]
        [string]$SafeUsers
    )
    $ADCSObjects | Where-Object {
        ($_.ObjectClass -eq 'pKICertificateTemplate') -and
        (!$_.pkiExtendedKeyUsage) -and 
        ($_.'msPKI-Certificate-Name-Flag' -eq 1) -and
        ($_.'msPKI-Enrollment-Flag' -ne 2) -and
        ( ($_.'msPKI-RA-Signature' -eq 0) -or ($null -eq $_.'msPKI-RA-Signature') ) 
    } | ForEach-Object {
        foreach ($entry in $_.nTSecurityDescriptor.Access) {
            if ( ($entry.IdentityReference -notmatch $SafeUsers) -and ($entry.ActiveDirectoryRights -match 'ExtendedRight') ) {
                $Issue = New-Object -TypeName pscustomobject
                $Issue | Add-Member -MemberType NoteProperty -Name Forest -Value $_.CanonicalName.split('/')[0] -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Name -Value $_.Name -Force
                $Issue | Add-Member -MemberType NoteProperty -Name DistinguishedName -Value $_.DistinguishedName -Force
                $Issue | Add-Member -MemberType NoteProperty -Name IdentityReference -Value $entry.IdentityReference -Force
                $Issue | Add-Member -MemberType NoteProperty -Name ActiveDirectoryRights -Value $entry.ActiveDirectoryRights  -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Issue `
                    -Value "$($entry.IdentityReference) can request a SubCA certificate without Manager Approval" -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Fix `
                    -Value "Get-ADObject `'$($_.DistinguishedName)`' | Set-ADObject -Replace @{'msPKI-Certificate-Name-Flag' = 0}"  -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Revert `
                    -Value "Get-ADObject `'$($_.DistinguishedName)`' | Set-ADObject -Replace @{'msPKI-Certificate-Name-Flag' = 1}"  -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Technique -Value 'ESC2'
                $Issue
            }
        }
    }
}


function Find-ESC4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ADCSObjects,
        [Parameter(Mandatory = $true)]
        $DangerousRights,
        [Parameter(Mandatory = $true)]
        $SafeOwners,
        [Parameter(Mandatory = $true)]
        $SafeUsers
    )
    $ADCSObjects | ForEach-Object {
        if ( ($_.objectClass -eq 'pKICertificateTemplate') -and ($_.nTSecurityDescriptor.Owner -notmatch $SafeOwners) ) {
            $Issue = New-Object -TypeName pscustomobject
            $Issue | Add-Member -MemberType NoteProperty -Name Forest -Value $_.CanonicalName.split('/')[0] -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Name -Value $_.Name -Force
            $Issue | Add-Member -MemberType NoteProperty -Name DistinguishedName -Value $_.DistinguishedName -Force
            $Issue | Add-Member -MemberType NoteProperty -Name IdentityReference -Value $entry.IdentityReference -Force
            $Issue | Add-Member -MemberType NoteProperty -Name ActiveDirectoryRights -Value $entry.ActiveDirectoryRights -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Issue `
                -Value "$($_.nTSecurityDescriptor.Owner) has Owner rights on this template" -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Fix -Value '[TODO]' -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Revert -Value '[TODO]'  -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Technique -Value 'ESC4'
            $Issue
        }
        foreach ($entry in $_.nTSecurityDescriptor.Access) {
            if ( ($_.objectClass -eq 'pKICertificateTemplate') -and
                ($entry.IdentityReference -notmatch $SafeUsers) -and
                ($entry.ActiveDirectoryRights -match $DangerousRights) ) {
                $Issue = New-Object -TypeName pscustomobject
                $Issue | Add-Member -MemberType NoteProperty -Name Forest -Value $_.CanonicalName.split('/')[0] -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Name -Value $_.Name -Force
                $Issue | Add-Member -MemberType NoteProperty -Name DistinguishedName -Value $_.DistinguishedName -Force
                $Issue | Add-Member -MemberType NoteProperty -Name IdentityReference -Value $entry.IdentityReference -Force
                $Issue | Add-Member -MemberType NoteProperty -Name ActiveDirectoryRights -Value $entry.ActiveDirectoryRights -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Issue `
                    -Value "$($entry.IdentityReference) has $($entry.ActiveDirectoryRights) rights on this template"  -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Fix -Value '[TODO]'  -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Revert -Value '[TODO]'  -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Technique -Value 'ESC4'
                $Issue
            }
        }
    }
}


function Find-ESC5 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ADCSObjects,
        [Parameter(Mandatory = $true)]
        $DangerousRights,
        [Parameter(Mandatory = $true)]
        $SafeOwners,
        [Parameter(Mandatory = $true)]
        $SafeUsers
    )
    $ADCSObjects | ForEach-Object {
        if ( ($_.objectClass -ne 'pKICertificateTemplate') -and ($_.nTSecurityDescriptor.Owner -notmatch $SafeOwners) ) {
            $Issue = New-Object -TypeName pscustomobject
            $Issue | Add-Member -MemberType NoteProperty -Name Forest -Value $_.CanonicalName.split('/')[0] -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Name -Value $_.Name -Force
            $Issue | Add-Member -MemberType NoteProperty -Name DistinguishedName -Value $_.DistinguishedName -Force
            $Issue | Add-Member -MemberType NoteProperty -Name IdentityReference -Value $entry.IdentityReference -Force
            $Issue | Add-Member -MemberType NoteProperty -Name ActiveDirectoryRights -Value $entry.ActiveDirectoryRights -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Issue `
                -Value "$($_.nTSecurityDescriptor.Owner) has Owner rights on this object" -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Fix -Value '[TODO]' -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Revert -Value '[TODO]'  -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Technique -Value 'ESC5'
            $Issue
        }
        foreach ($entry in $_.nTSecurityDescriptor.Access) {
            if ( ($_.objectClass -ne 'pKICertificateTemplate') -and
                ($entry.IdentityReference -notmatch $SafeUsers) -and
                ($entry.ActiveDirectoryRights -match $DangerousRights) ) {
                    $Issue = New-Object -TypeName pscustomobject
                    $Issue | Add-Member -MemberType NoteProperty -Name Forest -Value $_.CanonicalName.split('/')[0] -Force
                    $Issue | Add-Member -MemberType NoteProperty -Name Name -Value $_.Name -Force
                    $Issue | Add-Member -MemberType NoteProperty -Name DistinguishedName -Value $_.DistinguishedName -Force
                    $Issue | Add-Member -MemberType NoteProperty -Name IdentityReference -Value $entry.IdentityReference -Force
                    $Issue | Add-Member -MemberType NoteProperty -Name ActiveDirectoryRights -Value $entry.ActiveDirectoryRights -Force
                    $Issue | Add-Member -MemberType NoteProperty -Name Issue `
                        -Value "$($entry.IdentityReference) has $($entry.ActiveDirectoryRights) rights on this object" -Force
                    $Issue | Add-Member -MemberType NoteProperty -Name Fix -Value '[TODO]'  -Force
                    $Issue | Add-Member -MemberType NoteProperty -Name Revert -Value '[TODO]'  -Force
                    $Issue | Add-Member -MemberType NoteProperty -Name Technique -Value 'ESC5'
                    $Issue
            }
        }
    }
}


function Find-ESC6 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ADCSObjects
    )
    process {
        $ADCSObjects | Where-Object {
            ($_.objectClass -eq 'pKIEnrollmentService') -and
            ($_.SANFlag -ne 'No')
        } | ForEach-Object {
            [string]$CAFullName = "$($_.dNSHostName)\$($_.Name)"
            $Issue = New-Object -TypeName pscustomobject
            $Issue | Add-Member -MemberType NoteProperty -Name Forest -Value $_.CanonicalName.split('/')[0] -Force
            $Issue | Add-Member -MemberType NoteProperty -Name Name -Value $_.Name -Force
            $Issue | Add-Member -MemberType NoteProperty -Name DistinguishedName -Value $_.DistinguishedName -Force
            if ($_.SANFlag -eq 'Yes') { 
                $Issue | Add-Member -MemberType NoteProperty -Name Issue -Value 'EDITF_ATTRIBUTESUBJECTALTNAME2 is enabled.' -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Fix `
                    -Value "certutil -config $CAFullname -setreg policy\EditFlags -EDITF_ATTRIBUTESUBJECTALTNAME2; Invoke-Command -ComputerName `"$($_.dNSHostName)`" -ScriptBlock { Get-Service -Name `'certsvc`' | Restart-Service -Force }" -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Revert `
                    -Value "certutil -config $CAFullname -setreg policy\EditFlags +EDITF_ATTRIBUTESUBJECTALTNAME2; Invoke-Command -ComputerName `"$($_.dNSHostName)`" -ScriptBlock { Get-Service -Name `'certsvc`' | Restart-Service -Force }" -Force
            } else {
                $Issue | Add-Member -MemberType NoteProperty -Name Issue -Value $_.AuditFilter -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Fix -Value 'N/A' -Force
                $Issue | Add-Member -MemberType NoteProperty -Name Revert -Value 'N/A' -Force
            }
            $Issue | Add-Member -MemberType NoteProperty -Name Technique -Value 'ESC6'
            $Issue
        }
    }
}


function Export-RevertScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$AuditingIssues,
        [Parameter(Mandatory = $true)]
        [array]$ESC1,
        [Parameter(Mandatory = $true)]
        [array]$ESC2,
        [Parameter(Mandatory = $true)]
        [array]$ESC6
    )
    begin {
        $Output = 'Invoke-RevertLocksmith.ps1'
        Set-Content -Path $Output -Value "<#`nScript to revert changes performed by Locksmith`nCreated $(Get-Date)`n#>" -Force
        $Objects = $AuditingIssues + $ESC1 + $ESC2 + $ESC6
    }
    process {
        $Objects| ForEach-Object {
            Add-Content -Path $Output -Value $_.Revert
            Start-Sleep -Seconds 5
        }
    }
}

function Format-Result {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $Issue,
        [Parameter(Mandatory = $true)]
        [int]$Mode
    )

    $IssueTable = @{
        DETECT = 'Auditing Issues'
        ESC1 = 'ESC1 - Misconfigured Certificate Template'
        ESC2 = 'ESC2 - Misconfigured Certificate Template'
        ESC4 = 'ESC4 - Vulnerable Certifcate Template Access Control'
        ESC5 = 'ESC5 - Vulnerable PKI Object Access Control'
        ESC6 = 'ESC6 - EDITF_ATTRIBUTESUBJECTALTNAME2'
    }

    if ($null -ne $Issue) {
        $UniqueIssue = $Issue.Technique | Sort-Object -Unique
        Write-Host "`n########## $($IssueTable[$UniqueIssue]) ##########`n"
        switch ($Mode) {
            0 {
                $Issue | Format-Table Technique, Name, Issue -Wrap
            }
            1 {
                $Issue | Format-List Technique, Name, DistinguishedName, Issue, Fix
            }
        }
    }
}


Clear-Host
$Logo
$Targets = Get-Target
# New-OutputPath

# Check if ActiveDirectory PowerShell module is available, and attempt to install if not found
if (-not(Get-Module -Name 'ActiveDirectory' -ListAvailable)) { 
    # Attempt to install ActiveDirectory PowerShell module for Windows Server OSes, works with Windows Server 2012 R2 through Windows Server 2022
    Install-WindowsFeature -Name RSAT-AD-PowerShell
    #TODO: Check for Windows 10/11 OS (admin workstation, PAW) and install using Add-WindowsCapability cmdlet instead
}

Clear-Host
$Logo
Write-Host 'Gathering AD CS Objects from $($Targets[0])...'
$ADCSObjects = Get-ADCSObject -Targets $Targets
Set-AdditionalCAProperty -ADCSObjects $ADCSObjects
$ADCSObjects += Get-CAHostObject -ADCSObjects $ADCSObjects
$CAHosts = Get-CAHostObject -ADCSObjects $ADCSObjects
$CAHosts | ForEach-Object { $SafeUsers += '|' + $_.Name }

Clear-Host
$Logo
Write-Host 'Identifying auditing issues...'
[array]$AuditingIssues = Find-AuditingIssue -ADCSObjects $ADCSObjects 

Clear-Host
$Logo
Write-Host 'Identifying AD CS templates with dangerous configurations...'
[array]$ESC1 = Find-ESC1 -ADCSObjects $ADCSObjects -SafeUsers $SafeUsers
[array]$ESC2 = Find-ESC2 -ADCSObjects $ADCSObjects -SafeUsers $SafeUsers

Clear-Host
$Logo
Write-Host 'Identifying AD CS template and other objects with poor access control...'
[array]$ESC4 = Find-ESC4 -ADCSObjects $ADCSObjects -SafeUsers $SafeUsers -DangerousRights $DangerousRights -SafeOwners $SafeOwners
[array]$ESC5 = Find-ESC5 -ADCSObjects $ADCSObjects -SafeUsers $SafeUsers -DangerousRights $DangerousRights -SafeOwners $SafeOwners
[array]$ESC6 = Find-ESC6 -ADCSObjects $ADCSObjects
[array]$AllIssues = $AuditingIssues + $ESC1 + $ESC2 + $ESC4 + $ESC5 + $ESC6

switch ($Mode) {
    0 { 
        Clear-Host
        $Logo
        Format-Result $AuditingIssues '0'  
        Format-Result $ESC1 '0'
        Format-Result $ESC2 '0'
        Format-Result $ESC4 '0'
        Format-Result $ESC5 '0'
        Format-Result $ESC6 '0'
    }
    1 {
        Clear-Host
        $Logo
        Format-Result $AuditingIssues '1'  
        Format-Result $ESC1 '1'
        Format-Result $ESC2 '1'
        Format-Result $ESC4 '1'
        Format-Result $ESC5 '1'
        Format-Result $ESC6 '1'
    }
    2 {
        Clear-Host
        $Logo
        $Output = 'ADCSIssues.CSV'
        Write-Host "Writing AD CS issues to $Output..."
        try {
            $AllIssues | Select-Object Forest, Name, Issue | Export-Csv -NoTypeInformation $Output
            Write-Host "$Output created successfully!"
        } catch {
            Write-Host 'Ope! Something broke.'
        } 
    }
    3 {
        Clear-Host
        $Logo
        $Output = 'ADCSRemediation.CSV'
        Write-Host "Writing AD CS issues to $Output..."
        try {
            $AllIssues | Select-Object Forest, Name, DistinguishedName, Issue, Fix | Export-Csv -NoTypeInformation $Output
            Write-Host "$Output created successfully!"
        } catch {
            Write-Host 'Ope! Something broke.'
        }
    }
    4 {
        Write-Host 'Creating a script to revert any changes made by Locksmith...'
        Export-RevertScript -AuditingIssues $AuditingIssues -ESC1 $ESC1 -ESC2 $ESC2 -ESC6 $ESC6
        Write-Host 'Executing Mode 4 - Attempting to fix all identified issues!'
        if ($AuditingIssues) {
            $AuditingIssues | ForEach-Object {
                Clear-Host
                Write-Host $Logo
                $FixBlock = [scriptblock]::Create($_.Fix)
                Write-Host "Attempting to fully enable AD CS auditing on $($_.Name)..."
                Write-Host "This should have little impact on your environment.`n"
                Write-Host 'Command(s) to be run:'
                Write-Host 'PS> ' -NoNewline
                Write-Host "$($_.Fix)`n" -ForegroundColor Cyan
                try {
                    $WarningError = $null
                    Write-Warning 'If you continue, this script will attempt to fix this issue.' -WarningAction Inquire -ErrorVariable WarningError
                    if (!$WarningError) {
                        try {
                            Invoke-Command -ScriptBlock $FixBlock
                        } catch {
                            Write-Error 'Could not modify AD CS auditing. Are you a local admin on this host?'
                        }
                    }
                } catch {
                    Write-Host 'SKIPPED!' -ForegroundColor Yellow
                }
                $Pause = Read-Host -Prompt 'Press any key to continue...'
            }
        }
        if ($ESC1) {
            $ESC1 | ForEach-Object {
                Clear-Host
                Write-Host $Logo
                $FixBlock = [scriptblock]::Create($_.Fix)
                Write-Host "Attempting to enable Manager Approval on the $($_.Name) template...`n"
                Write-Host 'Command(s) to be run:'
                Write-Host 'PS> ' -NoNewline
                Write-Host "$($_.Fix)`n" -ForegroundColor Cyan
                try {
                    $WarningError = $null
                    Write-Warning "This could cause some services to stop working until certificates are approved.`nIf you continue this script will attempt to fix this issues." -WarningAction Inquire -ErrorVariable WarningError
                    if (!$WarningError) {
                        try {
                            Invoke-Command -ScriptBlock $FixBlock
                        } catch {
                            Write-Error 'Could not enable Manager Approval. Are you an Active Directory or AD CS admin?'
                        }
                    }
                } catch {
                        Write-Host 'SKIPPED!' -ForegroundColor Yellow
                }
                $Pause = Read-Host -Prompt 'Press any key to continue...'
            }
        }
        if ($ESC2) {
            $ESC2 | ForEach-Object {
                Clear-Host
                Write-Host $Logo
                $FixBlock = [scriptblock]::Create($_.Fix)
                Write-Host "Attempting to enable Manager Approval on the $($_.Name) template...`n"
                Write-Host 'Command(s) to be run:'
                Write-Host 'PS> ' -NoNewline
                Write-Host "$($_.Fix)`n" -ForegroundColor Cyan
                try {
                    $WarningError = $null
                    Write-Warning "This could cause some services to stop working until certificates are approved.`nIf you continue, this script will attempt to fix this issue." -WarningAction Inquire -ErrorVariable WarningError
                    if (!$WarningError) {
                        try {
                            Invoke-Command -ScriptBlock $FixBlock
                        } catch {
                            Write-Error 'Could not enable Manager Approval. Are you an Active Directory or AD CS admin?'
                        }
                    }
                } catch {
                    Write-Host 'SKIPPED!' -ForegroundColor Yellow
                }
                $Pause = Read-Host -Prompt 'Press any key to continue...'
            }
        }
        if ($ESC6) {
            $ESC6 | ForEach-Object {
                Clear-Host
                Write-Host $Logo
                $FixBlock = [scriptblock]::Create($_.Fix)
                Write-Host "Attempting to disable the EDITF_ATTRIBUTESUBJECTALTNAME2 flag on $($_.Name)...`n"
                Write-Host 'Command(s) to be run:'
                Write-Host 'PS> ' -NoNewline
                Write-Host "$($_.Fix)`n" -ForegroundColor Cyan
                try {
                    $WarningError = $null
                    Write-Warning "This could cause some services to stop working.`nIf you continue this script will attempt to fix this issues." -WarningAction Inquire -ErrorVariable WarningError
                    if (!$WarningError) {
                        try {
                            Invoke-Command -ScriptBlock $FixBlock
                        } catch {
                            Write-Error 'Could not enable Manager Approval. Are you an Active Directory or AD CS admin?'
                        }
                    }
                } catch {
                    Write-Host 'SKIPPED!' -ForegroundColor Yellow
                }
                $Pause = Read-Host -Prompt 'Press any key to continue...'
            }
        }
    }
}
