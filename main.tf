data "aws_region" "current" {
  current = true
}

locals {
  # Explicitly set the count due to: https://github.com/hashicorp/terraform/issues/12570
  master_count    = "3"
  resource_suffix = "${terraform.workspace}-${data.aws_region.current.name}"
  master0_ip      = "${var.network_interface_private_ips[0]}"
  master1_ip      = "${var.network_interface_private_ips[1]}"
  master2_ip      = "${var.network_interface_private_ips[2]}"

  worker_keys            = "${keys(var.workers)}"
  worker_resource_suffix = "${terraform.workspace}-${data.aws_region.current.name}"
}

resource "aws_key_pair" "kubernetes" {
  key_name   = "kubernetes-${local.resource_suffix}"
  public_key = "${var.public_key}"
}

data "aws_ami" "container_linux" {
  most_recent = true

  owners = ["595879546273"]

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  # https://coreos.com/releases/#1520.9.0
  # kernel: 4.13.16
  # rkt: 1.28.1
  # systemd: 234
  # ignition: 0.17.2
  # docker: 1.12.6
  # etcd: 3.1.10
  filter {
    name   = "name"
    values = ["CoreOS-stable-1520.9.0-hvm"]
  }
}

data "ignition_file" "kubernetes_config" {
  filesystem = "root"
  path       = "/etc/sysctl.d/kubernetes.conf"

  content {
    content = <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
  }
}

data "ignition_file" "br_netfilter" {
  filesystem = "root"
  path       = "/etc/modules-load.d/br_netfilter.conf"

  content {
    content = "br_netfilter"
  }
}

// Disable automatic updates daemon
data "ignition_systemd_unit" "update_engine" {
  name = "update-engine.service"
  mask = true
}

// Disable automatic updates daemon
data "ignition_systemd_unit" "locksmithd" {
  name = "locksmithd.service"
  mask = true
}

data "ignition_systemd_unit" "coreos_metadata" {
  name    = "coreos-metadata.service"
  enabled = true
}

data "ignition_systemd_unit" "docker" {
  name    = "docker.service"
  enabled = true

  dropin = [
    {
      name = "20-exec-start.conf"

      content = <<EOF
[Service]
Environment="DOCKER_NOFILE=1000000"
ExecStart=
ExecStart=/usr/bin/dockerd --ip-masq=false --storage-driver=overlay --selinux-enabled=false --live-restore=true --log-opt max-size=10m --log-opt max-file=3 --exec-opt native.cgroupdriver=systemd
EOF
    },
  ]
}

data "ignition_systemd_unit" "etcd" {
  count   = "${local.master_count}"
  name    = "etcd-member.service"
  enabled = true

  dropin = [
    {
      name = "20-clct-etcd-member.conf"

      content = <<EOF
[Unit]
Description=kubelet: The Kubernetes Bootstrap Tool
Documentation=https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm/
Requires=network.target coreos-metadata.service
After=network.target coreos-metadata.service

[Service]
EnvironmentFile=/run/metadata/coreos
Environment="ETCD_IMAGE_TAG=v3.1.10"
ExecStart=
ExecStart=/usr/lib/coreos/etcd-wrapper $ETCD_OPTS \
  --name=master${count.index} \
  --initial-advertise-peer-urls=http://$${COREOS_EC2_IPV4_LOCAL}:2380 \
  --listen-peer-urls=http://$${COREOS_EC2_IPV4_LOCAL}:2380 \
  --listen-client-urls=http://$${COREOS_EC2_IPV4_LOCAL}:2379 \
  --advertise-client-urls=http://$${COREOS_EC2_IPV4_LOCAL}:2379 \
  --initial-cluster-token etcd-${local.resource_suffix} \
  --initial-cluster master0=http://${local.master0_ip}:2380,master1=http://${local.master1_ip}:2380,master2=http://${local.master2_ip}:2380 \
  --initial-cluster-state new
EOF
    },
  ]
}

data "ignition_systemd_unit" "kubeadm" {
  name    = "kubeadm.service"
  enabled = true

  content = <<EOF
[Unit]
Description=Kubernetes Installer
After=network.target docker.service etcd-member.service coreos-metadata.service
Requires=network.target etcd-member.service coreos-metadata.service
ConditionFirstBoot=yes

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/etc/rc.d/rc.local

[Install]
WantedBy=multi-user.target
EOF
}

data "ignition_systemd_unit" "kubelet_master" {
  name    = "kubelet.service"
  enabled = true
  content = "${data.template_file.kubelet_master.rendered}"
}

resource "aws_iam_role" "master" {
  name = "master-${local.resource_suffix}"
  path = "/"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "master" {
  name = "master-${local.resource_suffix}"
  role = "${aws_iam_role.master.id}"

  // Temporary workaround for https://github.com/hashicorp/terraform/issues/1885
  provisioner "local-exec" {
    command = "sleep 60"
  }
}

resource "aws_iam_role_policy" "master" {
  name = "master-${local.resource_suffix}"
  role = "${aws_iam_role.master.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:*"],
      "Resource": ["*"]
    },
    {
      "Effect": "Allow",
      "Action": ["elasticloadbalancing:*"],
      "Resource": ["*"]
    },
    {
      "Effect": "Allow",
      "Action": ["route53:*"],
      "Resource": ["*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

# TODO: lock this down to only what is required.
resource "aws_security_group" "master" {
  name   = "master-${local.resource_suffix}"
  vpc_id = "${var.vpc_id}"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["${var.inbound_cidr_block}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["${var.outbound_cidr_block}"]
  }
}

data "ignition_file" "master_rc_local" {
  filesystem = "root"
  path       = "/etc/rc.d/rc.local"
  mode       = 448

  content {
    content = "${data.template_file.master_rc_local.rendered}"
  }
}

data "ignition_file" "worker_rc_local" {
  filesystem = "root"
  path       = "/etc/rc.d/rc.local"
  mode       = 448

  content {
    content = "${data.template_file.worker_rc_local.rendered}"
  }
}

data "template_file" "master_rc_local" {
  template = "${file("${path.module}/templates/rc.local")}"

  vars {
    cluster_dns             = "${var.cluster_dns}"
    join_endpoint           = "${local.master0_ip}"
    join_endpoint_port      = "6443"
    kubernetes_token_id     = "${var.kubernetes_token_id}"
    kubernetes_token_secret = "${var.kubernetes_token_secret}"
    kubernetes_version      = "${var.kubernetes_version}"
    master_count            = "${local.master_count}"
    type                    = "master"
  }
}

data "template_file" "worker_rc_local" {
  template = "${file("${path.module}/templates/rc.local")}"

  vars {
    cluster_dns             = "${var.cluster_dns}"
    join_endpoint           = "${var.cluster_dns}"
    join_endpoint_port      = "443"
    kubernetes_token_id     = "${var.kubernetes_token_id}"
    kubernetes_token_secret = "${var.kubernetes_token_secret}"
    kubernetes_version      = "${var.kubernetes_version}"
    master_count            = "${local.master_count}"
    type                    = "worker"
  }
}

data "template_file" "ingress" {
  template = "${file("${path.module}/templates/ingress.yaml")}"

  vars {
    cluster_dns = "${var.cluster_dns}"
  }
}

data "ignition_file" "ingress" {
  filesystem = "root"
  path       = "/etc/kubernetes/ingress.yaml"
  mode       = 384

  content {
    content = "${data.template_file.ingress.rendered}"
  }
}

data "ignition_file" "kubeadm_master_yaml" {
  filesystem = "root"
  path       = "/etc/kubernetes/kubeadm.yaml"
  mode       = 384

  content {
    content = <<EOF
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
kubernetesVersion: v${var.kubernetes_version}
authorizationMode: RBAC
token: ${var.kubernetes_token_id}.${var.kubernetes_token_secret}
tokenTTL: 8760h
etcd:
  endpoints:
  - http://${local.master0_ip}:2379
  - http://${local.master1_ip}:2379
  - http://${local.master2_ip}:2379
networking:
  dnsDomain: cluster.local
  serviceSubnet: ${var.service_network_cidr}
  podSubnet: ${var.pod_network_cidr}
apiServerCertSANs:
- ${local.master1_ip}
- ${local.master2_ip}
- ${var.cluster_dns}
apiServerExtraVolumes:
  - name: ca-certs
    hostPath: /usr/share/ca-certificates
    mountPath: /etc/ssl/certs
controllerManagerExtraArgs:
  address: 0.0.0.0
  flex-volume-plugin-dir: /opt/libexec/kubernetes/kubelet-plugins/volume/exec
controllerManagerExtraVolumes:
  - name: ca-certs
    hostPath: /usr/share/ca-certificates
    mountPath: /etc/ssl/certs
  - name: flexvolume-dir
    hostPath: /opt/libexec/kubernetes/kubelet-plugins/volume/exec
    mountPath: /usr/libexec/kubernetes/kubelet-plugins/volume/exec
schedulerExtraArgs:
  address: 0.0.0.0
featureGates:
  HighAvailability: true
  SelfHosting: true
  StoreCertsInSecrets: true
EOF
  }
}

data "ignition_config" "master" {
  count = "${local.master_count}"

  systemd = [
    "${data.ignition_systemd_unit.update_engine.id}",
    "${data.ignition_systemd_unit.locksmithd.id}",
    "${data.ignition_systemd_unit.coreos_metadata.id}",
    "${element(data.ignition_systemd_unit.etcd.*.id, count.index)}",
    "${data.ignition_systemd_unit.docker.id}",
    "${data.ignition_systemd_unit.kubelet_master.id}",
    "${data.ignition_systemd_unit.kubeadm.id}",
  ]

  files = [
    "${data.ignition_file.br_netfilter.id}",
    "${data.ignition_file.kubernetes_config.id}",
    "${data.ignition_file.master_rc_local.id}",
    "${data.ignition_file.ingress.id}",
    "${data.ignition_file.kubeadm_master_yaml.id}",
  ]
}

data "template_file" "kubelet_master" {
  template = "${file("${path.module}/templates/kubelet.service")}"

  vars {
    labels = "--node-labels=node-role.kubernetes.io/master=''"
    taints = "--register-with-taints=node-role.kubernetes.io/master=:NoSchedule"
  }
}

data "ignition_config" "worker" {
  count = "${length(local.worker_keys)}"

  systemd = [
    "${data.ignition_systemd_unit.update_engine.id}",
    "${data.ignition_systemd_unit.locksmithd.id}",
    "${data.ignition_systemd_unit.coreos_metadata.id}",
    "${data.ignition_systemd_unit.docker.id}",
    "${element(data.ignition_systemd_unit.kubelet_worker.*.id, count.index)}",
    "${data.ignition_systemd_unit.kubeadm.id}",
  ]

  files = [
    "${data.ignition_file.br_netfilter.id}",
    "${data.ignition_file.kubernetes_config.id}",
    "${data.ignition_file.worker_rc_local.id}",
  ]
}

data "ignition_systemd_unit" "kubelet_worker" {
  count = "${length(local.worker_keys)}"

  name    = "kubelet.service"
  enabled = true
  content = "${element(data.template_file.kubelet_worker.*.rendered, count.index)}"
}

data "template_file" "kubelet_worker" {
  count = "${length(local.worker_keys)}"

  template = "${file("${path.module}/templates/kubelet.service")}"

  vars {
    labels = "--node-labels='${lookup(var.workers[element(local.worker_keys, count.index)], "node_lables")}'"
    taints = "--register-with-taints='${lookup(var.workers[element(local.worker_keys, count.index)], "node_taints")}'"
  }
}

resource "aws_instance" "master" {
  count = "${local.master_count}"

  ami           = "${data.aws_ami.container_linux.id}"
  instance_type = "${var.master_instance_type}"

  root_block_device = {
    volume_type = "${var.master_volume_type}"
    volume_size = "${var.master_volume_size}"
  }

  user_data = "${element(data.ignition_config.master.*.rendered, count.index)}"

  key_name             = "${aws_key_pair.kubernetes.id}"
  iam_instance_profile = "${aws_iam_instance_profile.master.id}"

  network_interface {
    network_interface_id = "${element(var.network_interface_ids, count.index)}"
    device_index         = 0
  }

  lifecycle {
    ignore_changes = ["user_data"]
  }
}

resource "aws_iam_role" "worker" {
  name = "worker-${local.worker_resource_suffix}"
  path = "/"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "worker" {
  name = "worker-${local.worker_resource_suffix}"
  role = "${aws_iam_role.worker.id}"

  // Temporary workaround for https://github.com/hashicorp/terraform/issues/1885
  provisioner "local-exec" {
    command = "sleep 60"
  }
}

resource "aws_iam_role_policy" "worker" {
  name = "worker-${local.worker_resource_suffix}"
  role = "${aws_iam_role.worker.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::kubernetes-*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": "ec2:Describe*",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "ec2:AttachVolume",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "ec2:DetachVolume",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["route53:*"],
      "Resource": ["*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:GetRepositoryPolicy",
        "ecr:DescribeRepositories",
        "ecr:ListImages",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_security_group" "worker" {
  name   = "worker-${local.worker_resource_suffix}"
  vpc_id = "${var.vpc_id}"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["${var.inbound_cidr_block}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["${var.outbound_cidr_block}"]
  }
}

resource "aws_launch_configuration" "worker" {
  count = "${length(local.worker_keys)}"

  name_prefix   = "worker-${local.worker_resource_suffix}-${element(local.worker_keys, count.index)}"
  image_id      = "${data.aws_ami.container_linux.id}"
  instance_type = "${lookup(var.workers[element(local.worker_keys, count.index)], "instance_type")}"

  key_name             = "${aws_key_pair.kubernetes.id}"
  iam_instance_profile = "${aws_iam_instance_profile.worker.id}"
  security_groups      = ["${aws_security_group.worker.id}"]

  root_block_device = {
    volume_type = "${lookup(var.workers[element(local.worker_keys, count.index)], "volume_type")}"
    volume_size = "${lookup(var.workers[element(local.worker_keys, count.index)], "volume_size")}"
  }

  user_data = "${element(data.ignition_config.worker.*.rendered, count.index)}"

  lifecycle {
    ignore_changes        = ["user_data"]
    create_before_destroy = "true"
  }
}

resource "aws_autoscaling_group" "worker_asg" {
  count = "${length(local.worker_keys)}"

  name                      = "worker-${local.worker_resource_suffix}-${element(local.worker_keys, count.index)}"
  max_size                  = "${lookup(var.workers[element(local.worker_keys, count.index)], "max_size")}"
  min_size                  = "${lookup(var.workers[element(local.worker_keys, count.index)], "min_size")}"
  health_check_grace_period = 300
  health_check_type         = "EC2"
  force_delete              = false
  launch_configuration      = "${element(aws_launch_configuration.worker.*.name, count.index)}"
  vpc_zone_identifier       = ["${split(",", lookup(var.workers[element(local.worker_keys, count.index)], "subnet_ids"))}"]

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupStandbyInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  lifecycle {
    create_before_destroy = "true"
  }
}
