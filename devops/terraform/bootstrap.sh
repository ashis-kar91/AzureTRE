#!/bin/bash
set -o errexit
set -o pipefail
set -o nounset

# Baseline Azure resources
echo -e "\n\e[34m»»» 🤖 \e[96mCreating resource group and storage account\e[0m..."
# shellcheck disable=SC2154
az group create --resource-group "$TF_VAR_mgmt_resource_group_name" --location "$LOCATION" -o table

# shellcheck disable=SC2154
if ! az storage account show --resource-group "$TF_VAR_mgmt_resource_group_name" --name "$TF_VAR_mgmt_storage_account_name" --query "name" -o none 2>/dev/null; then
  # only run `az storage account create` if doesn't exist (to prevent error from occuring if storage account was originally created without infrastructure encryption enabled)

  # Set default encryption types based on enable_cmk
  encryption_type=$([ "${TF_VAR_enable_cmk_encryption:-false}" = true ] && echo "Account" || echo "Service")

  # shellcheck disable=SC2154
  az storage account create --resource-group "$TF_VAR_mgmt_resource_group_name" \
    --name "$TF_VAR_mgmt_storage_account_name" --location "$LOCATION" \
    --allow-blob-public-access false --min-tls-version TLS1_2 \
    --kind StorageV2 --sku Standard_LRS -o table \
    --encryption-key-type-for-queue "$encryption_type" \
    --encryption-key-type-for-table "$encryption_type" \
    --require-infrastructure-encryption true
else
  echo "Storage account already exists..."
  az storage account show --resource-group "$TF_VAR_mgmt_resource_group_name" --name "$TF_VAR_mgmt_storage_account_name" --output table
fi

# Grant user blob data contributor permissions
echo -e "\n\e[34m»»» 🔑 \e[96mGranting Storage Blob Data Contributor role to the current user\e[0m..."
if [ -n "${ARM_CLIENT_ID:-}" ]; then
    USER_OBJECT_ID=$(az ad sp show --id "$ARM_CLIENT_ID" --query id --output tsv)
else
    USER_OBJECT_ID=$(az ad signed-in-user show --query id --output tsv)
fi
az role assignment create --assignee "$USER_OBJECT_ID" \
  --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$TF_VAR_mgmt_resource_group_name/providers/Microsoft.Storage/storageAccounts/$TF_VAR_mgmt_storage_account_name"

# Function to check if the role assignment exists
check_role_assignment() {
  az role assignment list --assignee "$USER_OBJECT_ID" --role "Storage Blob Data Contributor" --scope "/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$TF_VAR_mgmt_resource_group_name/providers/Microsoft.Storage/storageAccounts/$TF_VAR_mgmt_storage_account_name" --query "[].id" --output tsv
}

# Wait for the role assignment to be applied
echo -e "\n\e[34m»»» ⏳ \e[96mWaiting for role assignment to be applied\e[0m..."
while [ -z "$(check_role_assignment)" ]; do
  echo "Waiting for role assignment..."
  sleep 10
done
echo "Role assignment applied."

# Blob container
# shellcheck disable=SC2154
az storage container create --account-name "$TF_VAR_mgmt_storage_account_name" --name "$TF_VAR_terraform_state_container_name" --auth-mode login -o table

# logs container
az storage container create --account-name "$TF_VAR_mgmt_storage_account_name" --name "tflogs" --auth-mode login -o table

cat > bootstrap_backend.tf <<BOOTSTRAP_BACKEND
terraform {
  backend "azurerm" {
    resource_group_name  = "$TF_VAR_mgmt_resource_group_name"
    storage_account_name = "$TF_VAR_mgmt_storage_account_name"
    container_name       = "$TF_VAR_terraform_state_container_name"
    key                  = "bootstrap.tfstate"
    use_azuread_auth     = true
    use_oidc             = true
  }
}
BOOTSTRAP_BACKEND


# Set up Terraform
echo -e "\n\e[34m»»» ✨ \e[96mTerraform init\e[0m..."
terraform init -input=false -backend=true -reconfigure

# Import the storage account & res group into state
echo -e "\n\e[34m»»» 📤 \e[96mImporting resources to state\e[0m..."
if ! terraform state show azurerm_resource_group.mgmt > /dev/null; then
  echo  "/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$TF_VAR_mgmt_resource_group_name"
  terraform import azurerm_resource_group.mgmt "/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$TF_VAR_mgmt_resource_group_name"
fi

if ! terraform state show azurerm_storage_account.state_storage > /dev/null; then
  terraform import azurerm_storage_account.state_storage "/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$TF_VAR_mgmt_resource_group_name/providers/Microsoft.Storage/storageAccounts/$TF_VAR_mgmt_storage_account_name"
fi

if [ "${IMPORT_MANUALLY_CREATED_RESOURCES_IN_BOOTSTRAP:-true}" = false ]; then
  echo -e "\n\e[33m Skipping Terraform imports of manually created resources as IMPORT_MANUALLY_CREATED_RESOURCES_IN_BOOTSTRAP=false\e[0m"
else
  echo -e "\n\e[33m WARNING: IMPORT_MANUALLY_CREATED_RESOURCES_IN_BOOTSTRAP=true. if you encounter 'Error: Cannot import non-existent remote object', note that some environments (e.g., production) have policies that require manual creation of resources, which then has to be imported into Terraform. If this is not required for this deployment, set IMPORT_MANUALLY_CREATED_RESOURCES_IN_BOOTSTRAP:false in the config.yaml to skip these imports.\e[0m"

  # Import the Key Vault and the CMK into the state
  if ! terraform state show 'azurerm_key_vault.encryption_kv[0]' > /dev/null; then
    terraform import 'azurerm_key_vault.encryption_kv[0]' "/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$TF_VAR_mgmt_resource_group_name/providers/Microsoft.KeyVault/vaults/$TF_VAR_encryption_kv_name"
  fi

  if ! terraform state show 'azurerm_key_vault_key.tre_mgmt_encryption[0]' > /dev/null; then
    terraform import 'azurerm_key_vault_key.tre_mgmt_encryption[0]' "$MGMT_ENCYRPTION_KEY_IDENTIFIER_URL"
  fi

  # Import the encryption identity and its role assignment into the state
  if ! terraform state show 'azurerm_user_assigned_identity.tre_mgmt_encryption[0]' > /dev/null; then
    terraform import 'azurerm_user_assigned_identity.tre_mgmt_encryption[0]' "/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$TF_VAR_mgmt_resource_group_name/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-tre-mgmt-encryption"
  fi

  if ! terraform state show 'azurerm_role_assignment.kv_mgmt_encryption_key_user[0]' > /dev/null; then
    terraform import 'azurerm_role_assignment.kv_mgmt_encryption_key_user[0]' "/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$TF_VAR_mgmt_resource_group_name/providers/Microsoft.KeyVault/vaults/$TF_VAR_encryption_kv_name/providers/Microsoft.Authorization/roleAssignments/$MGMT_ENCRYPTION_IDENTITY_ROLE_ASSIGNMENT_ID"
  fi

  # Import current user's key vault role assignment into the state
  if ! terraform state show 'azurerm_role_assignment.current_user_to_key_vault_crypto_officer[0]' > /dev/null; then
    terraform import 'azurerm_role_assignment.current_user_to_key_vault_crypto_officer[0]' "/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$TF_VAR_mgmt_resource_group_name/providers/Microsoft.KeyVault/vaults/$TF_VAR_encryption_kv_name/providers/Microsoft.Authorization/roleAssignments/$CURRENT_USER_KEY_VAULT_CRYPTO_OFFICER"
  fi
fi

echo "State imported"

set +o nounset
