# =============================================================================
# vpc.tf — VPC + 3 public subnets + 3 private subnets + NAT + IGW
# =============================================================================
#
# Layout for sandbox:
#
#   VPC: 10.0.0.0/16
#   ├── Public:   10.0.0.0/24, 10.0.1.0/24, 10.0.2.0/24   (one per AZ)
#   │             └── NAT Gateway lives in 10.0.0.0/24 (us-east-1a only)
#   │             └── Internal ALB ENIs land here (auto-discovered via tag)
#   └── Private:  10.0.10.0/24, 10.0.11.0/24, 10.0.12.0/24 (one per AZ)
#                 └── EKS Auto Mode worker ENIs land here
#                 └── Pods get IPs from these subnets via VPC CNI
#                 └── Bastion lives in 10.0.10.0/24 (us-east-1a)
#
# Why single NAT (not per-AZ): cost. ~$32/mo for one vs ~$96/mo for three.
# Trade-off: if us-east-1a NAT or AZ goes down, pods in us-east-1b/c lose
# egress until traffic re-routes. Acceptable for sandbox; production would
# use 3.
#
# Tags drive auto-discovery:
#   - kubernetes.io/cluster/<cluster> = shared    → tells EKS the subnet is for it
#   - kubernetes.io/role/elb = 1                  → public subnets host internet-facing LBs
#   - kubernetes.io/role/internal-elb = 1         → private subnets host internal LBs
#   ALB controller reads these tags to pick where to put load balancers.

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway — public subnets need this for outbound + LB ingress
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# -----------------------------------------------------------------------------
# Public subnets (one per AZ)
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.name_prefix}-pub-${var.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

# -----------------------------------------------------------------------------
# Private subnets (one per AZ)
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name                                        = "${var.name_prefix}-prv-${var.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

# -----------------------------------------------------------------------------
# NAT Gateway — single, in the FIRST AZ. EIP attached.
# -----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}

# -----------------------------------------------------------------------------
# Route tables
# -----------------------------------------------------------------------------
# Public RT: 0.0.0.0/0 → IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private RT: 0.0.0.0/0 → NAT (single, in [0])
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-rt-private"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
