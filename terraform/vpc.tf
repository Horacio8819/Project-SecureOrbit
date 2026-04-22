# ============================================================
# VPC
# ============================================================
resource "aws_vpc" "gds_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true  # Required by EKS
  enable_dns_hostnames = true  # Required by EKS
  tags = { Name = "gds-mission-vpc" }
}

# ============================================================
# INTERNET GATEWAY (lets public subnets reach the internet)
# ============================================================
resource "aws_internet_gateway" "gds_igw" {
  vpc_id = aws_vpc.gds_vpc.id
  tags   = { Name = "gds-igw" }
}

# ============================================================
# SUBNETS
# Public — ALB lives here
# Private — EKS nodes and pods live here
# ============================================================
resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.gds_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-central-1a"
  map_public_ip_on_launch = true
  tags = {
    Name                                        = "gds-public-1a"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"  # LB Controller uses public subnets for internet-facing ALB
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.gds_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-central-1b"
  map_public_ip_on_launch = true
  tags = {
    Name                                        = "gds-public-1b"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.gds_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "eu-central-1a"
  tags = {
    Name                                        = "gds-private-1a"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"  # Nodes live here
  }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.gds_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "eu-central-1b"
  tags = {
    Name                                        = "gds-private-2b"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

# ============================================================
# NAT GATEWAY  (lets private nodes reach the internet for updates, etc.)
# ============================================================
resource "aws_eip" "nat_eip" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.gds_igw]
}

resource "aws_nat_gateway" "gds_nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_1.id
  tags          = { Name = "gds-nat-gateway" }
}

# ============================================================
# ROUTE TABLES (lets public subnets reach the internet via the IGW, and private subnets reach the internet via the NAT Gateway)
# ============================================================
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.gds_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gds_igw.id
  }
  tags = { Name = "gds-public-rt" }
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.gds_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.gds_nat.id
  }
  tags = { Name = "gds-private-rt" }
}

resource "aws_route_table_association" "private_1" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private_rt.id
}

# ============================================================
# SECURITY GROUPS
# ============================================================

# Node SG — allows the ALB Controller-created ALB to reach pods
resource "aws_security_group" "alb_sg" {
  name   = "gds-alb-sg"
  vpc_id = aws_vpc.gds_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # Internet → ALB
    description = "HTTP from internet"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "gds-alb-sg" }
}

resource "aws_security_group" "node_sg" {
  name   = "gds-node-sg"
  vpc_id = aws_vpc.gds_vpc.id

  # Node to node (Kubernetes internal traffic)
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
    description = "Node to node"
  }

  # ALB → Flask pod (ALB rewrites destination to pod :5000)
  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]  # source is the ALB SG, not 0.0.0.0/0
    description     = "ALB to Flask pods"
  }

  # EKS control plane → kubelet
  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.gds_vpc.cidr_block]
    description = "EKS control plane to kubelet"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "gds-node-sg" }
}