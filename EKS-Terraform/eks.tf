
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-west-1"
}

############################
# VARIABLES
############################

variable "cluster_version" {
  default = "1.35"
}

# CHANGE THIS TO YOUR PUBLIC IP
variable "admin_cidr" {
  default = "YOUR_PUBLIC_IP/32"
}

############################
# AVAILABILITY ZONES
############################

data "aws_availability_zones" "available" {
  state = "available"
}

############################
# VPC
############################

resource "aws_vpc" "eks_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "eks-vpc"
  }
}

############################
# INTERNET GATEWAY
############################

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks_vpc.id

  tags = {
    Name = "eks-igw"
  }
}

############################
# PUBLIC SUBNETS
############################

resource "aws_subnet" "public1" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name                           = "eks-public-1"
    "kubernetes.io/cluster/naresh" = "shared"
    "kubernetes.io/role/elb"       = "1"
  }
}

resource "aws_subnet" "public2" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name                           = "eks-public-2"
    "kubernetes.io/cluster/naresh" = "shared"
    "kubernetes.io/role/elb"       = "1"
  }
}

############################
# PRIVATE SUBNETS
############################

resource "aws_subnet" "private1" {
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name                           = "eks-private-1"
    "kubernetes.io/cluster/naresh" = "shared"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "private2" {
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name                           = "eks-private-2"
    "kubernetes.io/cluster/naresh" = "shared"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

############################
# NAT GATEWAY
############################

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "eks-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public1.id

  depends_on = [
    aws_internet_gateway.igw
  ]

  tags = {
    Name = "eks-nat-gateway"
  }
}

############################
# PUBLIC ROUTE TABLE
############################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "eks-public-rt"
  }
}

resource "aws_route_table_association" "pub1" {
  subnet_id      = aws_subnet.public1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "pub2" {
  subnet_id      = aws_subnet.public2.id
  route_table_id = aws_route_table.public.id
}

############################
# PRIVATE ROUTE TABLE
############################

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "eks-private-rt"
  }
}

resource "aws_route_table_association" "priv1" {
  subnet_id      = aws_subnet.private1.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "priv2" {
  subnet_id      = aws_subnet.private2.id
  route_table_id = aws_route_table.private.id
}

############################
# EKS CLUSTER IAM ROLE
############################

resource "aws_iam_role" "cluster_role" {
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

############################
# WORKER NODE IAM ROLE
############################

resource "aws_iam_role" "worker_role" {
  name = "eks-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "worker_node" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

############################
# EKS CLUSTER
############################

resource "aws_eks_cluster" "eks" {
  name     = "naresh"
  role_arn = aws_iam_role.cluster_role.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids = [
      aws_subnet.private1.id,
      aws_subnet.private2.id
    ]

    endpoint_public_access  = true
    endpoint_private_access = true

    public_access_cidrs = [
      var.admin_cidr
    ]
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_route_table_association.priv1,
    aws_route_table_association.priv2
  ]

  tags = {
    Name        = "naresh"
    Environment = "dev"
    Project     = "eks-project"
  }
}

############################
# EKS MANAGED NODE GROUP
############################

resource "aws_eks_node_group" "node_group" {
  cluster_name    = aws_eks_cluster.eks.name
  node_group_name = "eks-node-group"

  node_role_arn = aws_iam_role.worker_role.arn

  subnet_ids = [
    aws_subnet.private1.id,
    aws_subnet.private2.id
  ]

  instance_types = ["m7i-flex.large"]

  capacity_type = "ON_DEMAND"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_node,
    aws_iam_role_policy_attachment.cni,
    aws_iam_role_policy_attachment.ecr
  ]

  tags = {
    Name        = "eks-node"
    Environment = "dev"
    Project     = "eks-project"
    Owner       = "veeraops"
  }
}

############################
# VPC CNI ADDON
############################

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "vpc-cni"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.node_group
  ]
}

############################
# COREDNS ADDON
############################

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.node_group
  ]
}

############################
# KUBE PROXY ADDON
############################

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.node_group
  ]
}

############################
# POD IDENTITY AGENT
############################

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "eks-pod-identity-agent"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.node_group
  ]
}

############################
# EBS CSI IAM ROLE
############################

resource "aws_iam_role" "ebs_csi_role" {
  name = "AmazonEKS_EBS_CSI_DriverRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

############################
# EBS CSI POD IDENTITY
############################

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.eks.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"

  role_arn = aws_iam_role.ebs_csi_role.arn

  depends_on = [
    aws_eks_addon.pod_identity,
    aws_iam_role_policy_attachment.ebs_csi_policy
  ]
}

############################
# EBS CSI DRIVER ADDON
############################

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "aws-ebs-csi-driver"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.node_group,
    aws_eks_pod_identity_association.ebs_csi
  ]
}

############################
# OUTPUTS
############################

output "cluster_name" {
  value = aws_eks_cluster.eks.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.eks.endpoint
}

output "region" {
  value = "us-west-1"
}

output "worker_instance_type" {
  value = "m7i-flex.large"
}

output "worker_node_count" {
  value = aws_eks_node_group.node_group.scaling_config[0].desired_size
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region us-west-1 --name naresh"
}
