locals {
  network_id = data.google_compute_network.selected.id
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

resource "google_secret_manager_secret" "connection_name" {
  secret_id = "${var.secret_name_prefix}-cloudsql-connection-name"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "connection_name" {
  secret      = google_secret_manager_secret.connection_name.id
  secret_data = google_sql_database_instance.primary.connection_name
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
  instance = google_sql_database_instance.primary.name
}

resource "google_sql_user" "client" {
  for_each = local.clients

  name     = each.value.username
  instance = google_sql_database_instance.primary.name
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
