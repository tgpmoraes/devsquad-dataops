Using module ./Common.psm1
Using module ./RepoOperations.psm1
Using module ./Logging.psm1

function CreateAzureDevopsRepository {
    param (
        [Parameter(Mandatory)] [hashtable] $RepoConfiguration
    )
    [Argument]::AssertIsNotNull("RepoConfiguration", $RepoConfiguration)

    $repo = az repos show -r $RepoConfiguration.RepoName --org $RepoConfiguration.AzureDevOpsOrganizationURI --project $RepoConfiguration.AzureDevOpsProject
    if (! $?) {
        Write-Host "Creating repository..." -ForegroundColor Green
        $repo = az repos create --name $RepoConfiguration.RepoName --org $RepoConfiguration.AzureDevOpsOrganizationURI --project $RepoConfiguration.AzureDevOpsProject
    }
    else {
        Write-Host "Repository $($RepoConfiguration.RepoName) already exists." -ForegroundColor Blue
    }

    return $repo | ConvertFrom-Json -AsHashtable
}
function CloneRepo {
    [cmdletbinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $RepoInfo,
        [Parameter(Mandatory)] [boolean] $UseSSH,
        [Parameter(Mandatory)] [boolean] $UsePAT
    )

    if (! $IsWindows) {
        $env:Temp = "/tmp";
    }
    $directory = Join-Path $env:Temp $(New-Guid)
    New-Item -Type Directory -Path $directory

    if ($UseSSH) {
        $domainGitUrl = $repoInfo.sshUrl
    }
    else {
        $domainGitUrl = $repoInfo.remoteUrl

        if ($UsePAT) {
            $domainGitUrl = $domainGitUrl -replace "(?<=https://\s*).*?(?=\s*@)", $env:AZURE_DEVOPS_EXT_PAT
        }
    }

    git clone $domainGitUrl $directory
    
    return $directory[1]
}
function CreateAzDevOpsRepoApprovalPolicy {
    [cmdletbinding()]
    param (
        [Parameter(Mandatory)] [hashtable] $RepoInfo,
        [Parameter(Mandatory)] [hashtable] $RepoConfiguration
    )
    [Argument]::AssertIsNotNull("RepoInfo", $RepoInfo)
    [Argument]::AssertIsNotNull("RepoConfiguration", $RepoConfiguration)

    Write-Host "Creating policy for approver count on branch $($RepoConfiguration.DefaultBranchName)" -ForegroundColor Green

    $result = az repos policy approver-count create --blocking true --branch $RepoConfiguration.DefaultBranchName --creator-vote-counts false --enabled true --minimum-approver-count $RepoConfiguration.MinimumApprovers --reset-on-source-push false --allow-downvotes false --repository-id $RepoInfo.id --org $RepoConfiguration.AzureDevOpsOrganizationURI --project $RepoConfiguration.AzureDevOpsProject

    $result | Write-Verbose
}
function CreateAzDevOpsRepoCommentPolicy {
    [cmdletbinding()]
    param (
        [Parameter(Mandatory)] [hashtable] $RepoInfo,
        [Parameter(Mandatory)] [hashtable] $RepoConfiguration
    )
    [Argument]::AssertIsNotNull("RepoInfo", $RepoInfo)
    [Argument]::AssertIsNotNull("RepoConfiguration", $RepoConfiguration)

    Write-Host "Creating policy for comment resolution on branch $($RepoConfiguration.DefaultBranchName)" -ForegroundColor Green

    $result = az repos policy comment-required create --blocking true --branch $RepoConfiguration.DefaultBranchName --enabled true --repository-id $RepoInfo.id --org $RepoConfiguration.AzureDevOpsOrganizationURI --project $RepoConfiguration.AzureDevOpsProject

    $result | Write-Verbose
}
function CreateAzDevOpsYamlPipelines {
    [cmdletbinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $RepoConfiguration
    )
    [Argument]::AssertIsNotNull("RepoConfiguration", $RepoConfiguration)

    foreach ($pipeline in $RepoConfiguration.Pipelines) {
        Write-Host "Creating AzDevOps Pipeline $($pipeline.Name)..." -ForegroundColor Green

        $result = az pipelines show --name "$($pipeline.Name)" --org $RepoConfiguration.AzureDevOpsOrganizationURI --project $RepoConfiguration.AzureDevOpsProject
        if (! $?){
            $result = az pipelines create --skip-first-run --branch $RepoConfiguration.DefaultBranchName --name "$($pipeline.Name)" --folder-path $RepoConfiguration.RepoName `
                                          --repository-type tfsgit --repository $RepoConfiguration.RepoName --yml-path $pipeline.SourceYamlPath `
                                          --org $RepoConfiguration.AzureDevOpsOrganizationURI --project $RepoConfiguration.AzureDevOpsProject
        }else{
            Write-Host "Pipeline '$($pipeline.Name)' already exists" -ForegroundColor Blue
        }

        $result | Write-Verbose
    }

}
function CreateAzDevOpsRepoBuildPolicy {
    [cmdletbinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $RepoInfo,
        [Parameter(Mandatory)] [hashtable] $RepoConfiguration
    )

    [Argument]::AssertIsNotNull("RepoInfo", $RepoInfo)
    [Argument]::AssertIsNotNull("RepoConfiguration", $RepoConfiguration)

    foreach ($pipeline in $RepoConfiguration.Pipelines) {
        if ($pipeline.BuildPolicy){
            Write-Host "Creating AzDevOps Build Policy for $($pipeline.Name)..." -ForegroundColor Green

            $pipelineId = az pipelines show --name "$($pipeline.Name)" --org $RepoConfiguration.AzureDevOpsOrganizationURI --project $RepoConfiguration.AzureDevOpsProject --query "id" -o tsv

            $displayName = "$($pipeline.BuildPolicy.Name)"

            $policyId = az repos policy list --repository-id $RepoInfo.id --branch $RepoConfiguration.DefaultBranchName `
                            --org $RepoConfiguration.AzureDevOpsOrganizationURI --project $RepoConfiguration.AzureDevOpsProject `
                            --query "[?settings.displayName=='$displayName'].id" -o tsv

            if (! $policyId) {
                $result = az repos policy build create --repository-id $RepoInfo.id --build-definition-id $pipelineId --display-name $displayName `
                                                    --branch $RepoConfiguration.DefaultBranchName --path-filter $pipeline.BuildPolicy.PathFilter `
                                                    --blocking true --enabled true  --queue-on-source-update-only true `
                                                    --manual-queue-only false --valid-duration 0 `
                                                    --org $RepoConfiguration.AzureDevOpsOrganizationURI --project $RepoConfiguration.AzureDevOpsProject
                $result | Write-Verbose
            }else{
                Write-Host "Build Policy '$displayName' already exists" -ForegroundColor Blue
            }
        }
    }
}
function SetupServiceConnection {
    [cmdletbinding()]
    param (
		[Parameter(Mandatory)] [hashtable] $Configuration,
        [Parameter(Mandatory)] [hashtable] $Environment,
        [Parameter(Mandatory)] [hashtable] $ServicePrincipal
    )

	[string]$organizationURI = "https://dev.azure.com/$($Configuration.azureDevOps.organization)"
	[string]$project = $Configuration.azureDevOps.project
	[string]$serviceConnectionName = $Environment.serviceConnectionName

    LogInfo -Message "Listing Azure DevOps service connections..."

    $serviceEndpointId = az devops service-endpoint list `
		--query "[?name=='$serviceConnectionName'].id" -o tsv `
		--organization $organizationURI `
		--project $project
    
    if (!$serviceEndpointId) {
        LogInfo -Message "No '$serviceConnectionName' service connection found. Creating..."

        if (! $ServicePrincipal.clientSecret) {
            throw "Client Secret was not present in the request."
        }

        $env:AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY = ConvertFrom-SecureString -SecureString $ServicePrincipal.clientSecret -AsPlainText

        $subscription = Get-AzSubscription | Where-Object { $_.Id -eq $Environment.subscriptionId }

        $serviceEndpointId = az devops service-endpoint azurerm create `
            --azure-rm-service-principal-id $ServicePrincipal.clientId `
            --azure-rm-subscription-id $subscription.Id `
            --azure-rm-subscription-name $subscription.Name `
            --azure-rm-tenant-id $subscription.TenantId `
            --name $serviceConnectionName `
            --organization $organizationURI `
            --project $project `
            --query 'id' -o tsv

		LogInfo -Message "Service connection '$serviceConnectionName' created."
    }

	LogInfo -Message "Granting acess permission to all pipelines on the '$serviceConnectionName' service connection..."

    az devops service-endpoint update `
		--id $serviceEndpointId --enable-for-all true `
		--organization $organizationURI `
		--project $project
	
	LogInfo -Message "Access permission to all pipelines granted for '$serviceConnectionName' service connection."
}