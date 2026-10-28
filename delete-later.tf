terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "demo-project"
  region  = "us-central1"
}

# Flaw 1: GCS Bucket with Uniform Bucket-Level Access Disabled & Publicly Accessible
resource "google_storage_bucket" "insecure_bucket" {
  name          = "demo-insecure-bucket-xyz123"
  location      = "US"
  force_destroy = true

  uniform_bucket_level_access = false # Triggers High/Critical violation
}

# Flaw 2: Firewall open to the entire internet on sensitive port (SSH)
resource "google_compute_firewall" "allow_all_ssh" {
  name    = "allow-ssh-all"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Triggers High/Critical violation
}
