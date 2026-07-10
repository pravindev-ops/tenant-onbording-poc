# ---------------------------------------------------------------------------
# Local Parsing, Normalization and Validations
# ---------------------------------------------------------------------------
locals {
  clients_raw = jsondecode(file("${path.module}/client.json"))

  clients = {
    for c in local.clients_raw : lower(trimspace(c.company_code)) => {
      database_name = "sharpsell_agents_${replace(lower(trimspace(c.company_code)), "-", "_")}"
      username      = "${replace(lower(trimspace(c.company_code)), "-", "_")}_app"
      base_url      = "https://${trimspace(c.base_url)}"
      tag           = trimspace(c.tag)
      env           = endswith(lower(trimspace(c.company_code)), "-dev") ? "development" : "production"
    }
  }

  gar_registry_host = "${var.gar_location}-docker.pkg.dev"
  api_image_base    = "${local.gar_registry_host}/${var.project_id}/${var.gar_repository}/${var.image_prefix}-api"
  mcp_image_base    = "${local.gar_registry_host}/${var.project_id}/${var.gar_repository}/${var.image_prefix}-mcp"

  network_id       = data.google_compute_network.selected.id
  cloudrun_enabled = var.deploy_cloud_run && length(local.clients) > 0

  mcp_shared_env = [
    { name = "MCP_SERVER_PORT", value = "80" },
    { name = "LANGSMITH_ENDPOINT", value = var.langsmith_endpoint },
    { name = "LANGSMITH_TRACING", value = var.langsmith_tracing },
    { name = "SHARPSELL_COMPANY_ID", value = var.sharpsell_company_id },
  ]
}

# ---------------------------------------------------------------------------
# Pre-flight Guardrails and Shape Checks
# ---------------------------------------------------------------------------
check "client_json_is_list" {
  assert {
    condition     = startswith(jsonencode(local.clients_raw), "[")
    error_message = "client.json must be a JSON array (e.g. [{\"company_code\":\"acme\",\"base_url\":\"acme.sharpselltech.com\",\"tag\":\"v1\"}])."
  }
}

check "client_entries_shape" {
  assert {
    condition = alltrue([
      for c in local.clients_raw : try(
        c.company_code != null && trimspace(c.company_code) != "" &&
        c.base_url != null && trimspace(c.base_url) != "" &&
        c.tag != null && trimspace(c.tag) != "",
        false
      )
    ])
    error_message = "Each entry must include non-empty company_code, base_url, and tag."
  }
}

check "client_base_urls_valid" {
  assert {
    condition = alltrue([
      for c in local.clients_raw : can(regex(
        "^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$",
        trimspace(c.base_url)
      ))
    ])
    error_message = "base_url must be a bare host without scheme, port, or path."
  }
}

check "client_image_tags_valid" {
  assert {
    condition = alltrue([
      for c in local.clients_raw : can(regex("^[a-zA-Z0-9._-]{1,128}$", trimspace(c.tag)))
    ])
    error_message = "Each tag must be a valid Docker tag."
  }
}

check "company_codes_valid" {
  assert {
    condition = alltrue([
      for c in local.clients_raw : can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,30}$", trimspace(c.company_code)))
    ])
    error_message = "company_code must be 1-31 alphanumeric characters or hyphens."
  }
}

check "client_derived_identifiers" {
  assert {
    condition = alltrue([
      for c in values(local.clients) : (
        can(regex("^[a-zA-Z_][a-zA-Z0-9_]{0,62}$", c.database_name)) &&
        can(regex("^[a-zA-Z_][a-zA-Z0-9_]{0,62}$", c.username))
      )
    ])
    error_message = "Derived database_name or username is not a valid Postgres identifier."
  }
}

check "client_usernames_not_admin" {
  assert {
    condition = alltrue([
      for c in values(local.clients) : c.username != var.admin_username
    ])
    error_message = "A derived client username matched the admin_username."
  }
}

# ---------------------------------------------------------------------------
# Enable all required GCP APIs
# ---------------------------------------------------------------------------

resource "google_project_service" "required" {
  for_each = toset([
    # Core platform
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    # Compute & networking
    "compute.googleapis.com",
    "deploymentmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "vpcaccess.googleapis.com",
    # Data & storage
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    # Compute services
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    # Observability
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# Wait for API enablement to propagate before any dependent resources are created.
# GCP can take 30–60s after enabling an API before it accepts resource creation calls.
resource "time_sleep" "api_propagation" {
  depends_on      = [google_project_service.required]
  create_duration = "60s"
}

# data source must wait for compute API to be enabled and propagated
data "google_compute_network" "selected" {
  name       = var.vpc_network_name
  depends_on = [time_sleep.api_propagation]
}
/*
resource "google_compute_global_address" "private_sql_peering" {
  name          = var.private_service_range_name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = local.network_id

  depends_on = [google_project_service.required]
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = local.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_sql_peering.name]

  depends_on = [
    google_project_service.required,
    google_compute_global_address.private_sql_peering,
  ]
}

resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "-_"
}

resource "google_sql_database_instance" "primary" {
  name             = var.instance_name
  region           = var.region
  database_version = "POSTGRES_16"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    google_service_networking_connection.private_vpc_connection,
    google_project_service.required,
  ]

  deletion_protection = var.deletion_protection

  settings {
    edition           = "ENTERPRISE"
    tier              = var.tier
    disk_size         = var.disk_size_gb
    disk_type         = "PD_SSD"
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled                                  = var.enable_public_ip
      private_network                               = local.network_id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      start_time                     = "18:00"
    }

    database_flags {
      # db-custom-2-8192 (8 GB) safely supports a smaller connection ceiling.
      # Per Cloud Run instance: SA pool(8+4) + checkpointer(8) ≈ 20 conns.
      # With max_instance_count=10 per client, each client's fleet peaks at ~200 conns.
      # 300 total leaves headroom for one actively peaking client; add PgBouncer
      # (and/or raise tier) once multi-client concurrent peaks become steady-state.
      name  = "max_connections"
      value = "300"
    }
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}

resource "google_sql_user" "admin" {
  name     = var.admin_username
  instance = google_sql_database_instance.primary.name
  password = random_password.admin.result
}

resource "google_secret_manager_secret" "admin_user" {
  secret_id = "${var.secret_name_prefix}-cloudsql-admin-user"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "admin_user" {
  secret      = google_secret_manager_secret.admin_user.id
  secret_data = var.admin_username
}

resource "google_secret_manager_secret" "admin_password" {
  secret_id = "${var.secret_name_prefix}-cloudsql-admin-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "admin_password" {
  secret      = google_secret_manager_secret.admin_password.id
  secret_data = random_password.admin.result
}
*/


# --- Fetch Existing Shared Cloud SQL Instance (Created by Script 1) ---
data "google_sql_database_instance" "primary" {
  name = var.instance_name
}

resource "google_secret_manager_secret" "connection_name" {
  secret_id = "${var.secret_name_prefix}-cloudsql-connection-name"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "connection_name" {
  secret      = google_secret_manager_secret.connection_name.id
  secret_data = data.google_sql_database_instance.primary.connection_name
}



# --- Per-client databases, users, and Secret Manager credentials ---

resource "random_password" "client" {
  for_each = local.clients

  length           = 32
  special          = true
  override_special = "-_"
}

resource "google_sql_database" "client" {
  for_each = local.clients

  name     = each.value.database_name
  instance = data.google_sql_database_instance.primary.name # <--- Reference the data source
}

resource "google_sql_user" "client" {
  for_each = local.clients

  name     = each.value.username
  instance = data.google_sql_database_instance.primary.name # <--- Reference the data source
  password = random_password.client[each.key].result

  depends_on = [google_sql_database.client]
}

resource "google_secret_manager_secret" "client_db_username" {
  for_each = local.clients

  secret_id = "${var.secret_name_prefix}-cloudsql-client-${each.key}-db-username"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "client_db_username" {
  for_each = local.clients

  secret      = google_secret_manager_secret.client_db_username[each.key].id
  secret_data = each.value.username
}

resource "google_secret_manager_secret" "client_db_password" {
  for_each = local.clients

  secret_id = "${var.secret_name_prefix}-cloudsql-client-${each.key}-db-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "client_db_password" {
  for_each = local.clients

  secret      = google_secret_manager_secret.client_db_password[each.key].id
  secret_data = random_password.client[each.key].result
}

resource "google_secret_manager_secret" "client_db_name" {
  for_each = local.clients

  secret_id = "${var.secret_name_prefix}-cloudsql-client-${each.key}-db-name"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "client_db_name" {
  for_each = local.clients

  secret      = google_secret_manager_secret.client_db_name[each.key].id
  secret_data = each.value.database_name
}

# ---------------------------------------------------------------------------
# Cloud Run Execution Layer
# ---------------------------------------------------------------------------
resource "google_service_account" "cloudrun_clients" {
  count        = local.cloudrun_enabled ? 1 : 0
  account_id   = "ss-agents-cloudrun"
  display_name = "Sharpsell agents Cloud Run (per-client services)"
  project      = var.project_id
  depends_on   = [google_project_service.required]
}

resource "google_project_iam_member" "cloudrun_sql_client" {
  count   = local.cloudrun_enabled ? 1 : 0
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.cloudrun_clients[0].email}"
}

resource "google_project_iam_member" "cloudrun_artifact_registry_reader" {
  count   = local.cloudrun_enabled ? 1 : 0
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.cloudrun_clients[0].email}"
}

# --- Client Secret Access Mapping ---
resource "google_secret_manager_secret_iam_member" "cloudrun_accessor_client_db" {
  for_each  = local.cloudrun_enabled ? local.clients : {}
  project   = var.project_id
  secret_id = google_secret_manager_secret.client_db_username[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloudrun_clients[0].email}"
}

resource "google_secret_manager_secret_iam_member" "cloudrun_accessor_client_pw" {
  for_each  = local.cloudrun_enabled ? local.clients : {}
  project   = var.project_id
  secret_id = google_secret_manager_secret.client_db_password[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloudrun_clients[0].email}"
}

resource "google_secret_manager_secret_iam_member" "cloudrun_accessor_client_dbname" {
  for_each  = local.cloudrun_enabled ? local.clients : {}
  project   = var.project_id
  secret_id = google_secret_manager_secret.client_db_name[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloudrun_clients[0].email}"
}

# ---------------------------------------------------------------------------
# Cloud Run Services (Direct VPC Egress Integration)
# ---------------------------------------------------------------------------

# 1. MCP Service
resource "google_cloud_run_v2_service" "mcp" {
  for_each            = local.cloudrun_enabled ? local.clients : {}
  name                = "ss-agents-mcp-${each.key}"
  location            = var.region
  project             = var.project_id
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_ALL"

  template {
    service_account                  = google_service_account.cloudrun_clients[0].email
    max_instance_request_concurrency = 40
    session_affinity                 = true
    timeout                          = "1200s"

    scaling {
      min_instance_count = 1
      max_instance_count = 10
    }

    # Replaced Serverless VPC Access connector with Direct VPC Egress
    vpc_access {
      network_interfaces {
        network    = data.google_compute_network.selected.name
        subnetwork = data.google_compute_subnetwork.selected_subnetwork.name
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = "${local.mcp_image_base}:${each.value.tag}"
      resources {
        limits = {
          memory = var.cloudrun_mcp_memory_limit
        }
      }
      ports {
        container_port = 80
      }

      startup_probe {
        http_get {
          path = "/"
          port = 80
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        timeout_seconds       = 3
        failure_threshold     = 60
      }

      dynamic "env" {
        for_each = local.mcp_shared_env
        iterator = item
        content {
          name  = item.value.name
          value = item.value.value
        }
      }

      env {
        name  = "COMPANY_CODE"
        value = each.key
      }
      env {
        name  = "LANGSMITH_PROJECT"
        value = each.key
      }
      env {
        name  = "SHARPSELL_BASE_URL"
        value = each.value.base_url
      }
      env {
        name  = "DEPLOY_STAMP"
        value = lookup(var.force_redeploy_stamps, each.key, "stable")
      }
      env {
        name  = "ANTHROPIC_API_KEY"
        value = var.anthropic_api_key
      }
      env {
        name  = "OPENAI_API_KEY"
        value = var.openai_api_key
      }
      env {
        name  = "GEMINI_API_KEY"
        value = var.gemini_api_key
      }
      env {
        name  = "LANGSMITH_API_KEY"
        value = var.langsmith_api_key
      }
      env {
        name  = "TAVILY_API_KEY"
        value = var.tavily_api_key
      }
      env {
        name  = "GOOGLE_SERVICE_ACCOUNT_KEY"
        value = var.google_service_account_key
      }
      env {
        name  = "GOOGLE_SHARED_DRIVE_ID"
        value = "0AJhDluJYGWqEUk9PVA"
      }
    }
  }

  lifecycle {
    ignore_changes = [
      client,
      annotations,
      labels,
      scaling,
      template[0].annotations,
      template[0].labels,
      template[0].containers[0].resources,
      template[0].scaling,
    ]
  }

  depends_on = [
    google_project_service.required,
  ]
}

# 2. API Service
resource "google_cloud_run_v2_service" "api" {
  for_each            = local.cloudrun_enabled ? local.clients : {}
  name                = "ss-agents-api-${each.key}"
  location            = var.region
  project             = var.project_id
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_ALL"

  template {
    service_account                  = google_service_account.cloudrun_clients[0].email
    max_instance_request_concurrency = 40
    timeout                          = "1200s"

    scaling {
      min_instance_count = 1
      max_instance_count = 10
    }

    # Replaced Serverless VPC Access connector with Direct VPC Egress
    vpc_access {
      network_interfaces {
        network    = data.google_compute_network.selected.name
        subnetwork = data.google_compute_subnetwork.selected_subnetwork.name
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = "${local.api_image_base}:${each.value.tag}"
      resources {
        limits = {
          memory = var.cloudrun_api_memory_limit
        }
      }
      ports {
        container_port = 80
      }

      startup_probe {
        http_get {
          path = "/"
          port = 80
        }
        initial_delay_seconds = 10
        period_seconds        = 5
        timeout_seconds       = 3
        failure_threshold     = 60
      }

      env {
        name  = "MCP_SERVER_URL"
        value = "${google_cloud_run_v2_service.mcp[each.key].uri}/mcp"
      }
      env {
        name  = "POSTGRES_DB_HOST"
        value = data.google_sql_database_instance.primary.private_ip_address
      }
      env {
        name  = "POSTGRES_DB_PORT"
        value = "5432"
      }
      env {
        name = "POSTGRES_DB_USER"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.client_db_username[each.key].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "POSTGRES_DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.client_db_password[each.key].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "POSTGRES_DB_NAME"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.client_db_name[each.key].secret_id
            version = "latest"
          }
        }
      }

      env {
        name  = "APP_ENV"
        value = each.value.env
      }
      env {
        name  = "COMPANY_CODE"
        value = each.key
      }
      env {
        name  = "SHARPSELL_BASE_URL"
        value = each.value.base_url
      }
      env {
        name  = "LANGSMITH_PROJECT"
        value = each.key
      }
      env {
        name  = "LANGSMITH_ENDPOINT"
        value = var.langsmith_endpoint
      }
      env {
        name  = "LANGSMITH_TRACING"
        value = var.langsmith_tracing
      }
      env {
        name  = "DEPLOY_STAMP"
        value = lookup(var.force_redeploy_stamps, each.key, "stable")
      }
      env {
        name  = "ANTHROPIC_API_KEY"
        value = var.anthropic_api_key
      }
      env {
        name  = "OPENAI_API_KEY"
        value = var.openai_api_key
      }
      env {
        name  = "GEMINI_API_KEY"
        value = var.gemini_api_key
      }
      env {
        name  = "LANGSMITH_API_KEY"
        value = var.langsmith_api_key
      }
      env {
        name  = "TAVILY_API_KEY"
        value = var.tavily_api_key
      }
      env {
        name  = "GOOGLE_SERVICE_ACCOUNT_KEY"
        value = var.google_service_account_key
      }
      env {
        name  = "GOOGLE_SHARED_DRIVE_ID"
        value = "0AJhDluJYGWqEUk9PVA"
      }
      env {
        name  = "UNLEASH_URL"
        value = var.unleash_url
      }
      env {
        name  = "UNLEASH_API_TOKEN"
        value = each.value.env == "development" ? var.unleash_api_token_dev : var.unleash_api_token_prod
      }
    }
  }

  lifecycle {
    ignore_changes = [
      client,
      annotations,
      labels,
      scaling,
      template[0].annotations,
      template[0].labels,
      template[0].containers[0].resources,
      template[0].scaling,
    ]
  }

  depends_on = [
    google_project_service.required,
    google_cloud_run_v2_service.mcp,
    google_secret_manager_secret_version.client_db_username,
    google_secret_manager_secret_version.client_db_password,
    google_secret_manager_secret_version.client_db_name,
  ]
}

# --- Service Public Access Rules ---
resource "google_cloud_run_v2_service_iam_member" "mcp_invoker_public" {
  for_each = local.cloudrun_enabled ? local.clients : {}
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.mcp[each.key].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "api_invoker_public" {
  for_each = local.cloudrun_enabled ? local.clients : {}
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api[each.key].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}