variable "project_id" {
  type        = string
  description = "The GCP Project ID"
}

variable "region" {
  type        = string
  default     = "asia-south1"
  description = "The GCP Region"
}

variable "vpc_network_name" {
  type        = string
  default     = "platform-vpc"
  description = "The name of the VPC network"
}

variable "subnet_name" {
  type        = string
  default     = "direct-vpc-egress-subnet" # Ensure this subnet is created (minimum /24 size recommended)
  description = "The name of the subnet in the target region used for Direct VPC Egress"
}

variable "private_service_range_name" {
  type        = string
  default     = "google-private-services"
  description = "The reserved peering IP range name"
}

variable "instance_name" {
  type        = string
  default     = "platform-postgres-db"
  description = "Base Cloud SQL instance name"
}

variable "admin_username" {
  type        = string
  default     = "postgres"
  description = "Admin username for the Postgres instance"
}

variable "secret_name_prefix" {
  type        = string
  default     = "ss-agents"
  description = "Prefix for Secret Manager secrets"
}

variable "gar_location" {
  type        = string
  default     = "asia-south1"
  description = "Artifact Registry regional location"
}

variable "gar_repository" {
  type        = string
  default     = "preveen-repo"
  description = "Artifact Registry Docker repository name"
}

variable "image_prefix" {
  type        = string
  default     = "ss-agents"
  description = "Prefix prepended to image names"
}

variable "deletion_protection" {
  type        = bool
  default     = false
  description = "Whether to protect the Cloud SQL instance from deletion"
}

variable "tier" {
  type        = string
  default     = "db-custom-2-8192"
  description = "Machine tier for the database instance"
}

variable "disk_size_gb" {
  type        = number
  default     = 20
  description = "Disk capacity for the database"
}

variable "enable_public_ip" {
  type        = bool
  default     = false
  description = "Enable public access interface for database"
}

# --- Cloud Run Compute Settings ---
variable "deploy_cloud_run" {
  type        = bool
  default     = true
  description = "Global switch to toggle Cloud Run service deployments"
}

variable "cloudrun_api_memory_limit" {
  type    = string
  default = "1024Mi"
}

variable "cloudrun_mcp_memory_limit" {
  type    = string
  default = "1024Mi"
}

# --- Deployment Stamps (Force Rollouts) ---
variable "force_redeploy_stamps" {
  type        = map(string)
  default     = {}
  description = "Stamps used to force resource updates in-place"
}

# --- Integration Secrets & Configuration Env Variables ---

variable "anthropic_api_key" {
  type    = string
  default = ""
}

variable "openai_api_key" {
  type    = string
  default = ""
}

variable "gemini_api_key" {
  type    = string
  default = ""
}

variable "langsmith_api_key" {
  type    = string
  default = ""
}

variable "slack_token" {
  type    = string
  default = ""
}

variable "google_service_account_key" {
  type    = string
  default = ""
}

variable "unleash_url" {
  type    = string
  default = ""
}

variable "unleash_api_token_dev" {
  type    = string
  default = ""
}

variable "unleash_api_token_prod" {
  type    = string
  default = ""
}
variable "langsmith_endpoint" {
  description = "LangSmith API endpoint URL."
  type        = string
  default     = "https://api.smith.langchain.com"
}

variable "langsmith_tracing" {
  description = "LANGSMITH_TRACING (true/false)."
  type        = string
  default     = "true"
}

variable "tavily_api_key" {
  description = "Tavily search API key — TF_VAR_tavily_api_key (TAVILY_API_KEY)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "sharpsell_company_id" {
  description = "Default SHARPSELL_COMPANY_ID for MCP marketing tools."
  type        = string
  default     = "1"
}