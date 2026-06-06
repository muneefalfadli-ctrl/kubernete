provider "aws" {
  region = "us-east-2" # Target commercial region for the cloud migration
}

# 1. Initialize IPAM to automatically manage enterprise IP pools
resource "aws_vpc_ipam" "main" {
  operating_regions {
    region_name = "us-east-2"
  }
}

resource "aws_vpc_ipam_pool" "pool" {
  address_family = "ipv4"
  ipam_scope_id  = aws_vpc_ipam.main.private_default_scope_id
  locale         = "us-east-2"

  # ADD THIS: Allows allocations anywhere from a /16 down to a /24
  allocation_min_netmask_length = 16
  allocation_max_netmask_length = 24
}

resource "aws_vpc_ipam_pool_cidr" "cidr" {
  ipam_pool_id = aws_vpc_ipam_pool.pool.id
  cidr         = "10.240.0.0/16" # Your dedicated commercial CIDR block allocation
}

# 2. Build the secure target VPC pulling its CIDR straight from IPAM
resource "aws_vpc" "eks_vpc" {
  ipv4_ipam_pool_id   = aws_vpc_ipam_pool.pool.id
  ipv4_netmask_length = 20 # Allocates a /20 pool (4,096 IPs) for our cluster scaling bounds

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "migration-eks-vpc"
  }
}

# 3. Create Subnets across Multiple Availability Zones
resource "aws_subnet" "public_az1" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = "10.240.0.0/24"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "eks-public-sub-1" }
}

resource "aws_subnet" "private_az1" {
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = "10.240.1.0/24"
  availability_zone = "us-east-2a"
  tags              = { Name = "eks-private-sub-1" }
}

# 🟢 NEW: Subnets in Availability Zone B
resource "aws_subnet" "public_az2" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = "10.240.2.0/24" # Incrementing the third octet
  availability_zone       = "us-east-2b"    # Crucial: Moving to AZ 'b'
  map_public_ip_on_launch = true
  tags                    = { Name = "eks-public-sub-2" }
}

resource "aws_subnet" "private_az2" {
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = "10.240.3.0/24" # Incrementing the third octet
  availability_zone = "us-east-2b"    # Crucial: Moving to AZ 'b'
  tags              = { Name = "eks-private-sub-2" }
}


# Allocate a public static IP for the NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "eks-nat-eip" }
}

# Deploy the NAT Gateway inside your public subnet
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_az1.id # Must sit in a public subnet

  tags = { Name = "eks-nat-gateway" }
}



# Create the Internet Gateway for the VPC
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks_vpc.id
  tags   = { Name = "eks-internet-gateway" }
}



# Create a route table that points internet traffic to the IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "eks-public-rt" }
}

# Link the public route table to your two public subnets
resource "aws_route_table_association" "public_az1" {
  subnet_id      = aws_subnet.public_az1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_az2" {
  subnet_id      = aws_subnet.public_az2.id
  route_table_id = aws_route_table.public.id
}


# Create a private route table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id # Route outbound traffic via NAT
  }

  tags = { Name = "eks-private-rt" }
}

# Associate the private route table with Private Subnet 1
resource "aws_route_table_association" "private_az1" {
  subnet_id      = aws_subnet.private_az1.id
  route_table_id = aws_route_table.private.id
}

# Associate the private route table with Private Subnet 2
resource "aws_route_table_association" "private_az2" {
  subnet_id      = aws_subnet.private_az2.id
  route_table_id = aws_route_table.private.id
}





# IAM Role for the EKS Cluster Control Plane
resource "aws_iam_role" "eks_cluster" {
  name = "migration-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}


resource "aws_eks_cluster" "control_plane" {
  name     = "target-commercial-cluster"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    # Stitches EKS directly into the network architecture you built in Option B
    subnet_ids = [
      aws_subnet.public_az1.id,
      aws_subnet.private_az1.id,
      aws_subnet.public_az2.id,
      aws_subnet.private_az2.id
    ]


    # 🟢 ADD THESE LINES inside vpc_config:
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # Ensures IAM policies are attached completely before the cluster provisions
  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}
# IAM Role for EKS Worker Nodes
resource "aws_iam_role" "eks_nodes" {
  name = "migration-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_eks_node_group" "worker_nodes" {
  cluster_name    = aws_eks_cluster.control_plane.name
  node_group_name = "commercial-compute-fleet"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  # Isolates compute workers strictly inside private subnet spaces
  subnet_ids = [
    aws_subnet.private_az1.id,
    aws_subnet.private_az2.id
  ]

  scaling_config {
    desired_size = 2 # Starts with 2 instances running across your AZs
    max_size     = 4 # Allows automatic scaling cap bounds
    min_size     = 1
  }

  instance_types = ["t3.medium"] # Balanced standard compute sizing for development workloads

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
  ]
}
