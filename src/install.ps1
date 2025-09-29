$resourceGroup = 'PreDayRG'
$location = '@lab.CloudResourceGroup(ResourceGroup1).Location'
$acrName = 'acr@lab.LabInstance.Id'
$aksName = 'predaycluster'
$nodepoolName = 'labpool'
$accountName = 'cosmosdb-@lab.LabInstance.Id'
$databaseName = 'productsdb'
$productContainer = 'productscontainer'
$ordersContainer = 'orderscontainer'
$namespaceName = 'sbpreday-@lab.LabInstance.Id'
$queueName = 'productsqueue'
$keyVaultName = 'kvpreday-@lab.LabInstance.Id'
$openaiName = 'preday-@lab.LabInstance.Id'
$openailocation = 'westus'
$deploymentName = 'gpt-4o'
$modelName = 'gpt-4o'
$modelVersion = '2024-11-20'

#Register Azure Resources providers
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.ContainerRegistry

while ($true) {
  $status = az provider show --namespace Microsoft.ContainerService --query registrationState -o tsv
  Write-Output "Current registration state: $status"
  if ($status -eq "Registered") { break }
  Start-Sleep -Seconds 5
}

while ($true) {
  $status = az provider show --namespace Microsoft.ContainerRegistry --query registrationState -o tsv
  Write-Output "Current registration state: $status"
  if ($status -eq "Registered") { break }
  Start-Sleep -Seconds 5
}

# Create ACR
az acr create --resource-group $resourceGroup --name $acrName --sku Basic --location $location

#Create new User-Assigned Managed Identity
$identityName = "$aksName-identity"
az identity create --resource-group $resourceGroup --name $identityName --location $location
$identityId = az identity show --resource-group $resourceGroup --name $identityName --query id -o tsv

# Create AKS cluster, attach ACR, enable Key Vault CSI driver addon, and assign managed identity
az aks create --resource-group $resourceGroup --name $aksName --node-count 2 --node-vm-size Standard_D2s_v3 --network-plugin azure --no-ssh-key -x --enable-addons azure-keyvault-secrets-provider --assign-identity $identityId

#Create AKS node pool to run the workloads
az aks nodepool add --resource-group $resourceGroup --cluster-name $aksName --name $nodepoolName --node-count 2 --node-vm-size Standard_D2s_v3

# Assign the managed identity to the node pool
$VMSSresourceGroup = az aks show --resource-group $resourceGroup --name $aksName --query "nodeResourceGroup" -o tsv
$VMSSnodepoolName = az vmss list --resource-group $VMSSresourceGroup --query "[].name" -o tsv | Select-String "$nodepoolName"
az vmss identity assign --resource-group $VMSSresourceGroup --name $VMSSnodepoolName --identities $identityId

#Update VMSS instances
az vmss update-instances -g $VMSSresourceGroup -n $VMSSnodepoolName --instance-ids *

# Create CosmosDB account (SQL API)
az cosmosdb create --name $accountName --resource-group $resourceGroup --locations regionName=$location failoverPriority=0 isZoneRedundant=False --kind GlobalDocumentDB

# Create SQL API database
az cosmosdb sql database create --account-name $accountName --name $databaseName --resource-group $resourceGroup

# Create SQL API container for products
az cosmosdb sql container create --account-name $accountName --database-name $databaseName --name $productContainer --resource-group $resourceGroup --partition-key-path "/id" --throughput 400

# Create SQL API container for orders
az cosmosdb sql container create --account-name $accountName --database-name $databaseName --name $ordersContainer --resource-group $resourceGroup --partition-key-path "/id" --throughput 400

# Create Service Bus namespace
az servicebus namespace create --resource-group $resourceGroup --name $namespaceName --location $location --sku Standard

# Create Service Bus queue
az servicebus queue create --resource-group $resourceGroup --namespace-name $namespaceName --name $queueName

# Create Key Vault
az keyvault create --name $keyVaultName --resource-group $resourceGroup --location $location

# --- Grant AKS user-assigned managed identity access to Key Vault ---
# Get the principalId of the AKS user-assigned managed identity
$identityName = "$aksName-identity"
$identityId = az identity show --resource-group $resourceGroup --name $identityName --query principalId -o tsv

# Get subscription ID
$subscriptionId = $(az account show --query id -o tsv)

#Below script doesn't work on Skillable environment
# Assign Key Vault Secrets User role to AKS managed identity at Key Vault scope
$kvScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.KeyVault/vaults/$keyVaultName"
$roleResult = az role assignment create --assignee-object-id $identityId --role "Key Vault Secrets User" --scope $kvScope --assignee-principal-type "ServicePrincipal" 2>&1
if ($LASTEXITCODE -eq 0) {
	Write-Host "Granted AKS user-assigned managed identity Key Vault Secrets User role for RBAC access."
} else {
	Write-Error "Failed to assign Key Vault Secrets User role to managed identity. Output: $roleResult"
}

# Create Azure OpenAI resource
az cognitiveservices account create `
    --name $openaiName `
    --resource-group $resourceGroup `
    --location $openailocation `
    --kind OpenAI `
    --sku s0

az cognitiveservices account deployment create `
  --resource-group $resourceGroup `
  --name $openaiName `
  --model-name $deploymentName `
  --model-name $modelName `
  --model-version $modelVersion `
  --model-format OpenAI
