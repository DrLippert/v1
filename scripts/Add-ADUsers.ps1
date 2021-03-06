#
# Add-NewADUsers.ps1
#
<# Custom Script for Windows #>
Param (		
		[Parameter(Mandatory)]
        [string]$UserName,
	    [Parameter(Mandatory)]
        [string]$Password,
	    [Parameter(Mandatory)]
        [string]$Share,
		[Parameter(Mandatory)]
        [string]$sasToken,
		[Parameter(Mandatory)]
        [string]$DNSName1,
		[Parameter(Mandatory)]
        [string]$DNSIPrecord1,
		[Parameter(Mandatory)]
        [string]$DNSName2,
		[Parameter(Mandatory)]
        [string]$DNSIPrecord2,
		[Parameter(Mandatory)]
        [string]$DNSName3,
		[Parameter(Mandatory)]
        [string]$DNSIPrecord3,
		[Parameter(Mandatory)]
        [string]$SipDomain,
		[Parameter(Mandatory)]
        [string]$SkypeIP
       )
$Domain = Get-ADDomain
$DomainDNSName = $Domain.DNSRoot
$SkypeOU = "SfBusers"
$Container = "ou="+$SkypeOU+","+$Domain.DistinguishedName

#region###  Add Active Directory Users
#Unzipe Users' Picture files
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory(".\Pics.zip", ".")

New-ADOrganizationalUnit -Name $SkypeOU -Path $Domain.DistinguishedName

Import-Csv .\New-ADUsers.csv | ForEach-Object {
    $userPrinc = $_.LogonUsername+"@"+$DomainDNSName
    New-ADUser -Name $_.Name `
    -SamAccountName $_.LogonUsername `
    -UserPrincipalName $userPrinc `
	-DisplayName $_.Name `
	-GivenName $_.FirstName `
    -SurName $_.LastName `
	-Description $_.Site `
	-Department $_.Dept `
    -Path $Container `
    -AccountPassword (ConvertTo-SecureString $Password -AsPlainText -force) `
	-Enabled $True `
	-PasswordNeverExpires $True `
    -PassThru
	 
	$Pic = ".\" + $_.LogonUsername + ".jpg"
     if(Test-Path $Pic){
         Set-ADUser $_.LogonUsername -Replace @{thumbnailPhoto=([byte[]](Get-Content $Pic -Encoding byte))}
     }
	#Set the primary email address used by Exchange Online with SMTP in Uppercase
	Set-ADUser $_.LogonUsername -Add @{ProxyAddresses='SMTP:'+$userPrinc}
}
#endregion

#region ######### Create Synced rooms
#$RoomsOU = "Rooms" 
#New-ADOrganizationalUnit -Name $RoomsOU -Path $Domain.DistinguishedName
#$Container = "ou="+$RoomsOU+","+$Domain.DistinguishedName
##Buildings
#New-ADGroup -Name UK-Bld1 -GroupCategory Distribution -DisplayName "Building 1" -GroupScope Universal -Path $Container
#New-ADGroup -Name UK-Bld2 -GroupCategory Distribution -DisplayName "Building 1" -GroupScope Universal -Path $Container

#$Rooms = @('Kilimandjaro','Dashan','Elgon','Toubkal')
#$Rooms | ForEach-Object {
#	$ADUserProperties = @{
#		Name =               $_
#	    Path =               $Container
#		SamAccountName =     $_
#	    UserPrincipalName =  $_+'@'+$DomainDNSName
#	    DisplayName =        'Meeting Room '+$_
#	    EmailAddress =       $_+'@'+$DomainDNSName
#	    OtherAttributes = @{
#        ProxyAddresses = 'SMTP:'+$_+'@'+$DomainDNSName
#		}
#	}
#	New-ADUser @ADUserProperties -PassThru
#}

#Add-ADGroupMember Uk-Bld1 -Members $Rooms[0],$Rooms[1]
#Add-ADGroupMember Uk-Bld2 -Members $Rooms[2],$Rooms[3]
#endregion ########

#region###  DNS Records
## DNS Records ## if your SIPdomain = Internal AD Domain
Add-DnsServerResourceRecordA -IPv4Address $SkypeIP -Name sip -ZoneName $SipDomain -ErrorAction Continue
Add-DnsServerResourceRecordA -IPv4Address $SkypeIP -Name meet -ZoneName $SipDomain -ErrorAction Continue
Add-DnsServerResourceRecordA -IPv4Address $SkypeIP -Name admin -ZoneName $SipDomain -ErrorAction Continue
Add-DnsServerResourceRecordA -IPv4Address $SkypeIP -Name dialin -ZoneName $SipDomain -ErrorAction Continue
Add-DnsServerResourceRecordA -IPv4Address $SkypeIP -Name webext -ZoneName $SipDomain -ErrorAction Continue

#Add STS DNS record if in the same doamin otherwise create a new primary zone
$STSname = $DNSname1.split('.')[0]
$STSdomainName = $DNSname1.split('.',2)[1]
if ($STSdomainName -match $DomainDNSName) {
	Add-DnsServerResourceRecordA -IPv4Address $DNSIPrecord1 -Name $STSname -ZoneName $DomainDNSName -ErrorAction Continue
	}
else{
	Add-DnsServerPrimaryZone -Name $STSdomainName -ReplicationScope Domain -ErrorAction Continue
	Add-DnsServerResourceRecordA -IPv4Address $DNSIPrecord1 -Name $STSname -ZoneName $STSdomainName -ErrorAction Continue
	}

#Add DNS records for servers in DMZ Reverse Proxy and Edge Server
Add-DnsServerResourceRecordA -IPv4Address $DNSIPrecord2 -Name $DNSName2 -ZoneName $DomainDNSName -ErrorAction Continue
Add-DnsServerResourceRecordA -IPv4Address $DNSIPrecord3 -Name $DNSName3 -ZoneName $DomainDNSName -ErrorAction Continue

#Add DNS record for PSTN gateway : Sbc will be installed on the reversproxy, DNS entry will point to RP server
$SBCCname= $DNSName2+'.'+$DomainDNSName+'.'
Add-DnsServerResourceRecordCName -HostNameAlias $SBCCname -Name 'sbc1' -ZoneName $DomainDNSName -ErrorAction Continue

#As in our configuration Edge server has a dns server on his internal Nic he is resolving aginst internal dns
#Then we need to add SRV record used for Exchange UM
Add-DnsServerResourceRecord -Srv -Name "_sipfederationtls._tcp" -ZoneName $SipDomain -DomainName "sip.$SipDomain" -Priority 0 -Weight 0 -Port 5061
#endregion

#region### #Export Domain Enterprise Root CA
$User=$Share
$Share="\\"+$Share+".file.core.windows.net\skype"
$RootCA= "G:\Share\"+$DomainDNSName+"-CA.crt"
$CAName= "CN="+$DomainDNSName+"-CA*"

net use G: $Share /u:$User $sasToken
New-Item G:\Share,G:\Logs -type directory -ErrorAction SilentlyContinue
Remove-Item $RootCA -ErrorAction SilentlyContinue
Export-Certificate -Cert (get-childitem Cert:\LocalMachine\My | where {$_.subject -like $CAName}) -FilePath $RootCA
#endregion

#region###  Install AADConnect
#Start-Process -FilePath msiexec -ArgumentList /i, "G:\AzureADConnect.msi", /quiet -Wait
$userfolder =  $UserName+"."+$DomainDNSName.split('.')[0]
New-Item C:\Users\$userfolder\Desktop\ -Force -ItemType Directory
Copy-Item -Path "G:\AzureADConnect.msi" -Destination C:\Users\$userfolder\Desktop\AzureADConnect.msi -ErrorAction Continue
#endregion

net use G: /d