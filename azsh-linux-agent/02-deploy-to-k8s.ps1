$yamlFile = "azsh-linux-agent-secret.yaml"
$yamlFileTemplate = "azsh-linux-agent-secret.template.yaml"

# Replace the placeholder with the actual value
$template = Get-Content $yamlFileTemplate
$template = $template -replace "__PAT_TOKEN__", $env:AZURE_DEVOPS_EXT_PAT_SOURCE

# Write the updated content to the yaml file
$template | Set-Content $yamlFile