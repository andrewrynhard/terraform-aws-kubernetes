variable "cluster_dns" {
  description = "The DNS record to be used for HA API control plane."
}

variable "inbound_cidr_block" {
  description = "The inbound CIDR block to allow."
  default     = "0.0.0.0/0"
}

variable "kubernetes_token_id" {
  description = "The token ID generted by kubeadm."
}

variable "kubernetes_token_secret" {
  description = "The token secret generted by kubeadm."
}

variable "kubernetes_version" {
  description = "The version of Kubernetes to use."
  default     = "1.9.2"
}

# TODO: add this to the `References` section in the README
# https://github.com/coreos/etcd/blob/master/Documentation/op-guide/hardware.md#hardware-recommendations
variable "master_instance_type" {
  description = "The EC2 instance type for master nodes."
  default     = "m4.large"
}

# TODO: add this to the `References` section in the README
# https://github.com/coreos/etcd/blob/master/Documentation/op-guide/hardware.md#hardware-recommendations
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EBSVolumeTypes.html
variable "master_volume_size" {
  description = "The size of the EBS volume for the master nodes."
  default     = "500"
}

variable "master_volume_type" {
  description = "The type EBS volume for the master nodes."
  default     = "gp2"
}

variable "outbound_cidr_block" {
  description = "The outbound CIDR block to allow."
  default     = "0.0.0.0/0"
}

variable "pod_network_cidr" {
  description = "The CIDR block for the Flannel CNI plugin."
  default     = "10.244.0.0/16"
}

variable "public_key" {
  description = "The public portion of an SSH key for remote access."
}

variable "service_network_cidr" {
  description = "The CIDR block for internal Kubernetes services."
  default     = "10.96.0.0/12"
}

variable "network_interface_ids" {
  description = "The list of ENI IDs for master nodes."
  type        = "list"
}

variable "network_interface_private_ips" {
  description = "The list of ENI IPs for master nodes."
  type        = "list"
}

variable "vpc_id" {
  description = "The VPC to create resources in."
}

variable "workers" {
  description = "A map that describes sets of worker nodes to join in the cluster."
  type        = "map"
}
