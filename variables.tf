variable "cluster_dns" {}

variable "inbound_cidr_block" {
  default = "0.0.0.0/0"
}

variable "kubernetes_token_id" {}
variable "kubernetes_token_secret" {}

variable "kubernetes_version" {
  default = "1.9.2"
}

# TODO: add this to the `References` section in the README
# https://github.com/coreos/etcd/blob/master/Documentation/op-guide/hardware.md#hardware-recommendations
variable "master_instance_type" {
  default = "m4.large"
}

# TODO: add this to the `References` section in the README
# https://github.com/coreos/etcd/blob/master/Documentation/op-guide/hardware.md#hardware-recommendations
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EBSVolumeTypes.html
variable "master_volume_size" {
  default = "500"
}

variable "master_volume_type" {
  default = "gp2"
}

variable "outbound_cidr_block" {
  default = "0.0.0.0/0"
}

variable "pod_network_cidr" {
  default = "10.244.0.0/16"
}

variable "public_key" {}

variable "service_network_cidr" {
  default = "10.96.0.0/12"
}

variable "network_interface_ids" {
  type = "list"
}

variable "network_interface_private_ips" {
  type = "list"
}

variable "vpc_id" {}

variable "workers" {
  type = "map"
}
