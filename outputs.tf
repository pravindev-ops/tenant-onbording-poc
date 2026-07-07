output "instance_connection_name" {
  description = "For Cloud SQL Auth Proxy / connectors: project:region:instance."
  value       = google_sql_database_instance.primary.connection_name
}

output "private_ip_address" {
  description = "Private IPv4 of the instance (same VPC / peered networks)."
  value       = google_sql_database_instance.primary.private_ip_address
}

output "secret_ids" {
  description = "Secret Manager secret IDs created for this stack (instance admin + connection)."
  value = {
    admin_user      = google_secret_manager_secret.admin_user.secret_id
    admin_password  = google_secret_manager_secret.admin_password.secret_id
    connection_name = google_secret_manager_secret.connection_name.secret_id
  }
}

output "client_secret_ids" {
  description = "Per-client Secret Manager secret IDs (map key = lower(company_code) from client.json)."
  value = {
    for k in keys(local.clients) : k => {
      db_username = google_secret_manager_secret.client_db_username[k].secret_id
      db_password = google_secret_manager_secret.client_db_password[k].secret_id
      db_name     = google_secret_manager_secret.client_db_name[k].secret_id
    }
  }
}

output "cloud_run_api_urls" {
  description = "HTTPS base URLs for FastAPI (path prefix /ss-agents). Empty if deploy_cloud_run is false or no clients."
  value = {
    for k, svc in google_cloud_run_v2_service.api : k => svc.uri
  }
}

output "cloud_run_mcp_urls" {
  description = "HTTPS base URLs for MCP (append /mcp for streamable HTTP). Same order as clients."
  value = {
    for k, svc in google_cloud_run_v2_service.mcp : k => svc.uri
  }
}