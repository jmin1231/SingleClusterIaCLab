# providers.tf - CloudStack provider; credentials come from the lab's minted API keys.

provider "cloudstack" {
  api_url    = var.cloudstack_api_url
  api_key    = var.cloudstack_api_key
  secret_key = var.cloudstack_secret_key
  timeout    = var.cloudstack_timeout
}
