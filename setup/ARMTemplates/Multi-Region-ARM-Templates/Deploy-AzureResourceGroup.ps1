#Requires -Version 3.0
#Requires -Module AzureRM.Resources
#Requires -Module Azure.Storage

Param(
    [string[]] [Parameter(Mandatory=$true)][ValidateCount(1,5)] $Locations,
    [string] $ResourceGroupNamePrefix = 'OpenDev-MultiRegion-' + $AppType,
	[string] [Parameter(Mandatory=$true)][ValidateSet("Java", "Node")] $AppType,
    [string] $StorageAccountName,
    [string] $StorageContainerName = $ResourceGroupNamePrefix.ToLowerInvariant() + '-stageartifacts',
    [string] $TemplateFile = 'azuredeploy.json',
    [string] $TemplateParametersFile = 'azuredeploy.parameters.json',
    [string] $TrafficManagerTemplateFile = 'azuredeploy.trafficManager.json',
    [string] $TrafficManagerTemplateParametersFile = 'azuredeploy.trafficManager.parameters.json',
    [string] $ArtifactStagingDirectory = '.',
    [string] $DSCSourceFolder = 'DSC',
    [switch] $ValidateOnly
)

try {
    [Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.AddUserAgent("VSAzureTools-$UI$($host.name)".replace(' ','_'), '2.9.6')
} catch { }

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

function Format-ValidationOutput {
    param ($ValidationOutput, [int] $Depth = 0)
    Set-StrictMode -Off
    return @($ValidationOutput | Where-Object { $_ -ne $null } | ForEach-Object { @('  ' * $Depth + ': ' + $_.Message) + @(Format-ValidationOutput @($_.Details) ($Depth + 1)) })
}

$HAResourceGroupName = $ResourceGroupNamePrefix + '-HA'
$PrimaryResourceGroupLocation = $Locations[0]

$OptionalParameters = New-Object -TypeName Hashtable

$TrafficManagerTemplateFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TrafficManagerTemplateFile))
$TrafficManagerTemplateParametersFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TrafficManagerTemplateParametersFile))

$TemplateFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateFile))
$TemplateParametersFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateParametersFile))

# Convert relative paths to absolute paths if needed
$ArtifactStagingDirectory = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $ArtifactStagingDirectory))
$DSCSourceFolder = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $DSCSourceFolder))

# Parse the parameter file and update the values of artifacts location and artifacts location SAS token if they are present
$JsonParameters = Get-Content $TemplateParametersFile -Raw | ConvertFrom-Json
if (($JsonParameters | Get-Member -Type NoteProperty 'parameters') -ne $null) {
    $JsonParameters = $JsonParameters.parameters
}
$ArtifactsLocationName = '_artifactsLocation'
$ArtifactsLocationSasTokenName = '_artifactsLocationSasToken'
$OptionalParameters[$ArtifactsLocationName] = $JsonParameters | Select -Expand $ArtifactsLocationName -ErrorAction Ignore | Select -Expand 'value' -ErrorAction Ignore
$OptionalParameters[$ArtifactsLocationSasTokenName] = $JsonParameters | Select -Expand $ArtifactsLocationSasTokenName -ErrorAction Ignore | Select -Expand 'value' -ErrorAction Ignore

# Create DSC configuration archive
if (Test-Path $DSCSourceFolder) {
    $DSCSourceFilePaths = @(Get-ChildItem $DSCSourceFolder -File -Filter '*.ps1' | ForEach-Object -Process {$_.FullName})
    foreach ($DSCSourceFilePath in $DSCSourceFilePaths) {
        $DSCArchiveFilePath = $DSCSourceFilePath.Substring(0, $DSCSourceFilePath.Length - 4) + '.zip'
        Publish-AzureRmVMDscConfiguration $DSCSourceFilePath -OutputArchivePath $DSCArchiveFilePath -Force -Verbose
    }
}

# Create a storage account name if none was provided
if ($StorageAccountName -eq '') {
    $StorageAccountName = 'stage' + ((Get-AzureRmContext).Subscription.SubscriptionId).Replace('-', '').substring(0, 19)
}

$StorageAccount = (Get-AzureRmStorageAccount | Where-Object{$_.StorageAccountName -eq $StorageAccountName})

# Create the storage account if it doesn't already exist
if ($StorageAccount -eq $null) {
    $StorageResourceGroupName = 'ARM_Deploy_Staging'
    New-AzureRmResourceGroup -Location "$PrimaryResourceGroupLocation" -Name $StorageResourceGroupName -Force
    $StorageAccount = New-AzureRmStorageAccount -StorageAccountName $StorageAccountName -Type 'Standard_LRS' -ResourceGroupName $StorageResourceGroupName -Location "$PrimaryResourceGroupLocation"
}

# Generate the value for artifacts location if it is not provided in the parameter file
if ($OptionalParameters[$ArtifactsLocationName] -eq $null) {
    $OptionalParameters[$ArtifactsLocationName] = $StorageAccount.Context.BlobEndPoint + $StorageContainerName
}

# Copy files from the local storage staging location to the storage account container
New-AzureStorageContainer -Name $StorageContainerName -Context $StorageAccount.Context -ErrorAction SilentlyContinue *>&1

$ArtifactFilePaths = Get-ChildItem $ArtifactStagingDirectory -Recurse -File | ForEach-Object -Process {$_.FullName}
foreach ($SourcePath in $ArtifactFilePaths) {
    Set-AzureStorageBlobContent -File $SourcePath -Blob $SourcePath.Substring($ArtifactStagingDirectory.length + 1) `
        -Container $StorageContainerName -Context $StorageAccount.Context -Force
}

# Generate a 4 hour SAS token for the artifacts location if one was not provided in the parameters file
if ($OptionalParameters[$ArtifactsLocationSasTokenName] -eq $null) {
    $OptionalParameters[$ArtifactsLocationSasTokenName] = ConvertTo-SecureString -AsPlainText -Force `
        (New-AzureStorageContainerSASToken -Container $StorageContainerName -Context $StorageAccount.Context -Permission r -ExpiryTime (Get-Date).AddHours(4))
}

$RegionObjects = @()
$Deployments = @()
$HADeployment = $null

foreach ($Location in $Locations)
{
	$R = New-Object -TypeName object
	$R | Add-Member -MemberType NoteProperty -Name Location -Value $Location
	$R | Add-Member -MemberType NoteProperty -Name ResourceGroupName -Value ($ResourceGroupNamePrefix + '-' + $Location)
	$RegionObjects += $R
}

foreach ($RegionObject in $RegionObjects)
{
    Write-Output ''
	Write-Output "*** Deploying Resource Group in $($RegionObject.ResourceGroupName) region ***"
	Write-Output ''

	New-AzureRmResourceGroup -Name $RegionObject.ResourceGroupName -Location $RegionObject.Location -Verbose -Force

    if ($ValidateOnly) {
        $ErrorMessages = Format-ValidationOutput (Test-AzureRmResourceGroupDeployment -ResourceGroupName $RegionObject.ResourceGroupName `
                                                                                      -TemplateFile $TemplateFile `
                                                                                      -TemplateParameterFile $TemplateParametersFile `
                                                                                      @OptionalParameters)
        if ($ErrorMessages) {
            Write-Output '', 'Validation returned the following errors:', @($ErrorMessages), '', 'Template is invalid.'
        }
        else {
            Write-Output '', 'Template is valid.'
        }
    }
    else {
        $Deployment = New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem $TemplateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
                                           -ResourceGroupName $RegionObject.ResourceGroupName `
                                           -TemplateFile $TemplateFile `
                                           -TemplateParameterFile $TemplateParametersFile `
                                           @OptionalParameters `
                                           -Force -Verbose `
                                           -ErrorVariable ErrorMessages
		$Deployments += $Deployment

        if ($ErrorMessages) {
            Write-Output '', 'Template deployment returned the following errors:', @(@($ErrorMessages) | ForEach-Object { $_.Exception.Message.TrimEnd("`r`n") })
        }
    }
}

# Deploy Traffic Manager Profile 
Write-Output ''
Write-Output '*** Deploying HA/Traffic Manager Resource Group ***'
Write-Output ''

New-AzureRmResourceGroup -Name $HAResourceGroupName -Location $PrimaryResourceGroupLocation -Verbose -Force

if ($ValidateOnly) {
    $ErrorMessages = Format-ValidationOutput (Test-AzureRmResourceGroupDeployment -ResourceGroupName $HAResourceGroupName `
                                                                                  -TemplateFile $TrafficManagerTemplateFile `
                                                                                  -TemplateParameterFile $TrafficManagerTemplateParametersFile `
                                                                                  @OptionalParameters)
    if ($ErrorMessages) {
        Write-Output '', 'Validation returned the following errors:', @($ErrorMessages), '', 'Template is invalid.'
    }
    else {
        Write-Output '', 'Template is valid.'
    }
}
else {
    $HADeployment = New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem $TrafficManagerTemplateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
                                       -ResourceGroupName $HAResourceGroupName `
                                       -TemplateFile $TrafficManagerTemplateFile `
                                       -TemplateParameterFile $TrafficManagerTemplateParametersFile `
                                       @OptionalParameters `
                                       -Force -Verbose `
                                       -ErrorVariable ErrorMessages
    if ($ErrorMessages) {
        Write-Output '', 'Template deployment returned the following errors:', @(@($ErrorMessages) | ForEach-Object { $_.Exception.Message.TrimEnd("`r`n") })
    }
	else
	{
		$TrafficManagerOutputs = $null
		if ($HADeployment.Outputs.TryGetValue("trafficManager", [ref] $TrafficManagerOutputs))
		{
			foreach ($Deployment in $Deployments)
			{
				$appEndpoint = Get-AzureRmTrafficManagerEndpoint -ResourceGroupName $HAResourceGroupName `
									-Name $Deployment.ResourceGroupName `
									-Type AzureEndpoints `
									-ProfileName $TrafficManagerOutputs.Value.profileName.value.ToString() `
									-ErrorAction SilentlyContinue
			
				$WebTierOutputs = $null
				if ($Deployment.Outputs.TryGetValue("webTier", [ref] $WebTierOutputs))
				{
					$WebTierPipResourceId = $WebTierOutputs.Value.pipResourceId.value.ToString()

					if ($appEndpoint -eq $null)
					{
						New-AzureRmTrafficManagerEndpoint -ResourceGroupName $HAResourceGroupName `
										-Name $Deployment.ResourceGroupName `
										-Type AzureEndpoints `
										-ProfileName $TrafficManagerOutputs.Value.profileName.value.ToString() `
										-EndpointStatus Enabled `
										-TargetResourceId $WebTierPipResourceId
					}
					else
					{
						$appEndpoint.TargetResourceId = $WebTierPipResourceId
						$appEndpoint.Type = "AzureEndpoints"
						$appEndpoint.EndpointStatus = "Enabled"
	
						Set-AzureRmTrafficManagerEndpoint -TrafficManagerEndpoint $appEndpoint
					}
				}
				else
				{
					Write-Warning 'Outputs not found for ""webTier"" deployment.  As a result, traffic manager endpoints are not configured.  You must set them manually.'
				}
			}
		}
		else
		{
			Write-Warning 'Outputs not found for ""trafficManager"" deployment.  As a result, traffic manager endpoints are not configured.  You must set them manually.'
		}
	}
}

if ( !($ValidateOnly) )
{
	$Deployments += $HADeployment

	Write-Output ''
	Write-Output '*** Deployment Outputs ***'
	Write-Output ''

	foreach ($Deployment in $Deployments)
	{
		Write-Output "Resource Group Name : $($Deployment.ResourceGroupName)"
		Write-Output "=================================="
		Write-Output ''

		$DeploymentOutputs = $Deployment.Outputs

		foreach ($Key in $DeploymentOutputs.Keys)
		{
			Write-Output $Key
			Write-Output '----------------------------------'
    
			$Outputs = $DeploymentOutputs.Item($Key)
			$Outputs = $Outputs.Value
			$OutputsEnum = $Outputs.GetEnumerator()

			while ($OutputsEnum.MoveNext())
			{
				$Output = $($OutputsEnum.Current.Value)
				Write-Output "$($OutputsEnum.Current.Key) : $($OutputsEnum.Current.Value.value.ToString())" 
			}

			Write-Output ''
		}
	}
}