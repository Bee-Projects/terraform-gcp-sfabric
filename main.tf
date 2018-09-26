provider "google" {
    
}

resource "google_compute_network" "sfnet" {
  name                    = "sfnet"
  auto_create_subnetworks = "true"
}

resource "google_compute_firewall" "bastion-ssh" {
  name    = "bastion-ssh"
  network = "${google_compute_network.sfnet.self_link}"

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  target_tags = ["bastion"]
}

resource "google_compute_firewall" "internal-ssh" {
  name    = "internal-ssh"
  network = "${google_compute_network.sfnet.self_link}"
  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_tags = ["bastion"]
  target_tags = ["sfnode"]
}


resource "google_compute_firewall" "servicefabric-ports" {
  name    = "servicefabric-ports"
  network = "${google_compute_network.sfnet.self_link}"
  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["19080"]
  }

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  target_tags = ["sfnode"]
}



variable "nat_ip" {
    default = ""
    description = "NAT ip configuration for each instance"
}

resource "google_compute_instance" "bastion" {
  depends_on = ["google_compute_network.sfnet"]
  name         = "bastion"
  machine_type = "g1-small"
  zone         = "australia-southeast1-a"
  tags = ["bastion"]
  boot_disk {
    initialize_params {
        image = "ubuntu-1604-lts"
        size = 100
    }
  }
  network_interface {
    network = "sfnet"

    access_config = {
        nat_ip = "${var.nat_ip}"
    }
  }
}

module "nat" {
  source     = "GoogleCloudPlatform/nat-gateway/google"
  region     = "australia-southeast1"
  network    = "${google_compute_network.sfnet.name}"
  subnetwork = "${google_compute_network.sfnet.name}"
}

data "template_file" "init-script" {
  template = "${file("${path.module}/scripts/init.sh")}"
}

resource "google_compute_instance_template" "sftemplate" {
    name                  = "sftemplate"
    instance_description  = "Service Fabric Nodes"
    tags = ["sfnode","nat-${var.region}"]
    machine_type          = "n1-standard-2"
    metadata_startup_script = "${data.template_file.init-script.rendered}"
    can_ip_forward        = false
    network_interface     {
        network = "${google_compute_network.sfnet.name}"
    }
    disk {
        source_image        = "ubuntu-1604-lts"
        disk_size_gb        = 100
    }
 
}

resource "google_compute_health_check" "autohealing" {
    name                = "autohealing-health-check"
    check_interval_sec  = 5
    timeout_sec         = 5
    healthy_threshold   = 2
    unhealthy_threshold = 10                         

    http_health_check {
        request_path = "/"
        port         = "19080"
    }
}

resource "google_compute_instance_group_manager" "instance_group_manager" {
    depends_on            = ["google_compute_network.sfnet"]
    name               = "sfabric-igm"
    instance_template  = "${google_compute_instance_template.sftemplate.self_link}"
    base_instance_name = "sfabric"
    zone               = "australia-southeast1-a"
    target_size        = "1"

    named_port {
        name = "https"
        port = "443"
    }

    named_port {
        name = "sfabric"
        port = "19080"
    }  

  auto_healing_policies {
    health_check      = "${google_compute_health_check.autohealing.self_link}"

    # Takes about 25 minutes to start up
    initial_delay_sec = 1500
  }
}


module "gce-lb-http" {
  source            = "github.com/GoogleCloudPlatform/terraform-google-lb-http"
  name              = "group-http-lb"
  target_tags       = ["sfnode"]
  backends          = {
    "0" = [
      { group = "${google_compute_instance_group_manager.instance_group_manager.instance_group}" },
    ],
  }
  backend_params    = [
    # health check path, port name, port number, timeout seconds.
    "/,sfabric,19080,10"
  ]
}

output external_ip {
  description = "The external IP assigned to the global fowarding rule."
  value       = "${module.gce-lb-http.external_ip}"
}

