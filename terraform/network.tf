# Dedicated VPC for Dataproc Serverless. Workers get no public IPs, so Private Google
# Access lets them reach BigQuery and Cloud Storage.
resource "google_compute_network" "data" {
  name                    = "data-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "data" {
  name                     = "data-subnet"
  region                   = var.region
  network                  = google_compute_network.data.id
  ip_cidr_range            = "10.10.0.0/24"
  private_ip_google_access = true
}

# The Spark driver and executors talk to each other inside the subnet.
resource "google_compute_firewall" "internal" {
  name          = "data-vpc-allow-internal"
  network       = google_compute_network.data.id
  direction     = "INGRESS"
  source_ranges = [google_compute_subnetwork.data.ip_cidr_range]

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}
