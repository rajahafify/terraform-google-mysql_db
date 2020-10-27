terraform {
  required_version = ">= 0.13.1" # see https://releases.hashicorp.com/terraform/
}

locals {
  master_instance_name = (
    var.full_name_master_instance == "" ? format("mysql-%s-%s", var.name_master_instance, var.name_suffix) : var.full_name_master_instance
  )
  read_replica_name_suffix = format("-%s-", var.name_read_replica)
  master_authorized_networks = [
    for authorized_network in var.authorized_networks_master_instance : {
      name  = authorized_network.display_name
      value = authorized_network.cidr_block
    }
  ]
  read_replica_authorized_networks = [
    for authorized_network in var.authorized_networks_read_replica : {
      name  = authorized_network.display_name
      value = authorized_network.cidr_block
    }
  ]
  db_flags_master_instance = [for key, val in var.db_flags_master_instance : { name = key, value = val }]
  db_flags_read_replica    = [for key, val in var.db_flags_read_replica : { name = key, value = val }]
  backup_location          = var.backup_location == "" ? data.google_client_config.google_client.region : var.backup_location
}

data "google_client_config" "google_client" {}

resource "google_project_service" "compute_api" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudsql_api" {
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

module "google_mysql_db" {
  source            = "GoogleCloudPlatform/sql-db/google//modules/mysql"
  version           = "4.0.0"
  depends_on        = [google_project_service.compute_api, google_project_service.cloudsql_api]
  project_id        = data.google_client_config.google_client.project
  name              = local.master_instance_name
  db_name           = var.db_name
  db_collation      = var.db_collation
  db_charset        = var.db_charset
  database_version  = var.db_version
  region            = data.google_client_config.google_client.region
  zone              = var.zone_master_instance
  availability_type = var.highly_available ? "REGIONAL" : null
  tier              = var.instance_size_master_instance
  disk_size         = var.disk_size_gb_master_instance
  disk_autoresize   = var.disk_auto_resize_master_instance
  disk_type         = "PD_SSD"
  create_timeout    = var.db_timeout
  update_timeout    = var.db_timeout
  delete_timeout    = var.db_timeout
  user_name         = var.user_name
  database_flags    = local.db_flags_master_instance
  user_labels       = var.user_labels_master_instance
  ip_configuration = {
    authorized_networks = local.master_authorized_networks
    ipv4_enabled        = var.public_access_master_instance
    private_network     = var.private_network
    require_ssl         = null
  }

  # backup settings
  backup_configuration = {
    enabled            = var.backup_enabled
    binary_log_enabled = var.pit_recovery_enabled
    start_time         = "00:05"
    location           = local.backup_location
  }

  # read replica settings
  read_replica_name_suffix = local.read_replica_name_suffix
  read_replicas = [
    for array_index in range(var.read_replica_count) : {
      name = array_index
      tier = var.instance_size_read_replica
      zone = format("%s-%s", data.google_client_config.google_client.region, var.zone_read_replica)
      ip_configuration = {
        authorized_networks = local.read_replica_authorized_networks
        ipv4_enabled        = var.public_access_read_replica
        private_network     = var.private_network
        require_ssl         = null
      }
      database_flags  = local.db_flags_read_replica
      disk_autoresize = var.disk_auto_resize_read_replica
      disk_size       = var.disk_size_gb_read_replica
      disk_type       = "PD_SSD"
      user_labels     = var.user_labels_read_replica
    }
  ]
}

resource "google_project_iam_member" "cloudsql_proxy_user" {
  count      = length(var.sql_proxy_user_groups)
  role       = "roles/cloudsql.client" # see https://cloud.google.com/sql/docs/mysql/quickstart-proxy-test#before-you-begin
  member     = "group:${var.sql_proxy_user_groups[count.index]}"
  depends_on = [google_project_service.compute_api, google_project_service.cloudsql_api]
}
