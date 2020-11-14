terraform {
  required_version = ">= 0.13.1" # see https://releases.hashicorp.com/terraform/
}

data "google_client_config" "google_client" {}

locals {
  instance_name = format("%s-vm-%s", var.instance_name, var.name_suffix)
  external_ip = var.create_external_ip ? google_compute_address.external_ip.0.address : (
    var.source_external_ip == "" ? null : var.source_external_ip
  )
  external_ip_name = var.external_ip_name == "" ? var.instance_name : var.external_ip_name
  tags             = toset(concat(var.network_tags, [var.name_suffix]))
  zone             = "${data.google_client_config.google_client.region}-${var.zone}"
  pre_defined_sa_roles = [
    # enable the VM instance to write logs and metrics
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/stackdriver.resourceMetadata.writer"
  ]
  sa_name         = var.sa_name == "" ? var.instance_name : var.sa_name
  sa_roles        = toset(concat(local.pre_defined_sa_roles, var.sa_roles))
  create_new_sa   = var.sa_email == "" ? true : false
  vm_sa_email     = local.create_new_sa ? module.service_account.0.email : var.sa_email
  vm_sa_self_link = "projects/${data.google_client_config.google_client.project}/serviceAccounts/${local.vm_sa_email}"

  # Firewall args
  vm_login_firewall_name  = format("login-to-%s-%s", var.instance_name, var.name_suffix)
  vm_egress_firewall_name = format("%s-to-network-%s", var.instance_name, var.name_suffix)
  google_iap_cidr         = "35.235.240.0/20" # GCloud Identity Aware Proxy Netblock - https://cloud.google.com/iap/docs/using-tcp-forwarding#preparing_your_project_for_tcp_forwarding
}

resource "google_project_service" "compute_api" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "networking_api" {
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_address" "external_ip" {
  count      = var.create_external_ip ? 1 : 0
  name       = format("%s-vmip-%s", local.external_ip_name, var.name_suffix)
  region     = data.google_client_config.google_client.region
  depends_on = [google_project_service.networking_api]
}

module "service_account" {
  count        = local.create_new_sa ? 1 : 0
  source       = "airasia/service_account/google"
  version      = "2.0.1"
  name_suffix  = var.name_suffix
  name         = local.sa_name
  display_name = local.sa_name
  description  = var.sa_description
  roles        = local.sa_roles
}

resource "google_compute_instance" "vm_instance" {
  name         = local.instance_name
  machine_type = var.machine_type
  zone         = local.zone
  tags         = local.tags
  boot_disk {
    initialize_params {
      size  = var.boot_disk_size
      type  = var.boot_disk_type
      image = var.boot_disk_image_source
    }
  }
  network_interface {
    subnetwork = var.vpc_subnetwork
    dynamic "access_config" {
      # Set 'access_config' block only if 'external_ip' is provided
      for_each = local.external_ip == null ? [] : [1]
      content {
        nat_ip = local.external_ip
      }
    }
  }
  metadata = {
    enable-oslogin = (var.allow_login ? "TRUE" : "FALSE") # see https://cloud.google.com/compute/docs/instances/managing-instance-access#enable_oslogin
    windows-keys   = null                                 # Placeholder to ignore changes. See https://www.terraform.io/docs/configuration/resources.html#ignore_changes
  }
  service_account {
    email  = local.vm_sa_email
    scopes = ["cloud-platform"]
  }
  allow_stopping_for_update = var.allow_stopping_for_update
  depends_on                = [google_project_service.compute_api]
  lifecycle {
    ignore_changes = [
      attached_disk, # to avoid conflict between google_compute_attached_disk & google_compute_instance over the control of disk block
      metadata["windows-keys"],
    ]
  }
}

resource "google_compute_firewall" "login_to_vm" {
  count         = var.allow_login ? 1 : 0
  name          = local.vm_login_firewall_name
  network       = data.google_compute_subnetwork.vm_subnet.network
  source_ranges = [local.google_iap_cidr /* see https://stackoverflow.com/a/57024714/636762 */]
  target_tags   = var.network_tags
  depends_on    = [google_compute_instance.vm_instance, google_project_service.networking_api]
  allow {
    protocol = "tcp"
    ports = [
      # https://cloud.google.com/iap/docs/using-tcp-forwarding#create-firewall-rule
      22,   # for SSH
      3389, # for RDP
    ]
  }
}

resource "google_compute_firewall" "vm_to_network" {
  name        = local.vm_egress_firewall_name
  network     = data.google_compute_subnetwork.vm_subnet.network
  source_tags = var.network_tags
  depends_on  = [google_compute_instance.vm_instance, google_project_service.networking_api]
  allow { protocol = "icmp" }
  allow { protocol = "tcp" }
  allow { protocol = "udp" }
}

data "google_compute_subnetwork" "vm_subnet" {
  self_link = google_compute_instance.vm_instance.network_interface.0.subnetwork
  region    = data.google_client_config.google_client.region
}

# ----------------------------------------------------------------------------------------------------------------------
# Grant IAM permissions to UserGroups and ServiceAccounts to be able to ssh/login to the VM instance
# ref: https://cloud.google.com/compute/docs/instances/managing-instance-access#configure_users
# ref: https://cloud.google.com/compute/docs/tutorials/service-account-ssh
# ----------------------------------------------------------------------------------------------------------------------
# UserGroups
# ----------------------------------------------------------------------------------------------------------------------

resource "google_compute_instance_iam_member" "group_login_role_compute_OS_login" {
  for_each      = toset(var.login_user_groups)
  instance_name = google_compute_instance.vm_instance.name
  zone          = google_compute_instance.vm_instance.zone
  role          = "roles/compute.osLogin" # to be able to perform the actual OS login
  member        = "group:${each.value}"
}

resource "google_project_iam_member" "group_login_role_compute_viewer" {
  for_each = toset(var.login_user_groups)
  role     = "roles/compute.viewer" # for project-wide permission of 'compute.projects.get' during OS login
  member   = "group:${each.value}"
}

resource "google_project_iam_member" "group_login_role_iap_secured_tunnel_user" {
  for_each = toset(var.login_user_groups)
  role     = "roles/iap.tunnelResourceAccessor" # to be able to 'gcloud.beta.compute.start-iap-tunnel' during OS login
  member   = "group:${each.value}"
}

resource "google_service_account_iam_member" "group_login_role_service_account_user" {
  for_each           = toset(var.login_user_groups)
  service_account_id = local.vm_sa_self_link
  role               = "roles/iam.serviceAccountUser" # to avoid password-prompt upon OS login
  member             = "group:${each.value}"
}

# ----------------------------------------------------------------------------------------------------------------------
# ServiceAccounts
# ----------------------------------------------------------------------------------------------------------------------

resource "google_compute_instance_iam_member" "sa_login_role_compute_OS_login" {
  for_each      = toset(var.login_service_accounts)
  instance_name = google_compute_instance.vm_instance.name
  zone          = google_compute_instance.vm_instance.zone
  role          = "roles/compute.osLogin" # to be able to perform the actual OS login
  member        = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "sa_login_role_compute_viewer" {
  for_each = toset(var.login_service_accounts)
  role     = "roles/compute.viewer" # for project-wide permission of 'compute.projects.get' during OS login
  member   = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "sa_login_role_iap_secured_tunnel_user" {
  for_each = toset(var.login_service_accounts)
  role     = "roles/iap.tunnelResourceAccessor" # to be able to 'gcloud.beta.compute.start-iap-tunnel' during OS login
  member   = "serviceAccount:${each.value}"
}

resource "google_service_account_iam_member" "sa_login_role_service_account_user" {
  for_each           = toset(var.login_service_accounts)
  service_account_id = local.vm_sa_self_link
  role               = "roles/iam.serviceAccountUser" # to avoid password-prompt upon OS login
  member             = "serviceAccount:${each.value}"
}

# ----------------------------------------------------------------------------------------------------------------------
