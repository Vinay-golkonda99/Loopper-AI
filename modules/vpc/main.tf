provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

# --- VPC ---
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true

  tags = {
    Name = var.vpc_name
  }
}

# --- Internet Gateway ---
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "${var.vpc_name}-igw"
  }
}

# --- Public Subnets ---
resource "aws_subnet" "public" {
  for_each            = toset(var.public_subnet_cidrs)
  vpc_id              = aws_vpc.this.id
  cidr_block          = each.value
  map_public_ip_on_launch = true
  availability_zone   = element(data.aws_availability_zones.available.names, index(var.public_subnet_cidrs, each.value))

  tags = {
    Name = "${var.vpc_name}-public-${each.value}"
  }
}

# --- Private Subnets ---
resource "aws_subnet" "private" {
  for_each          = toset(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = element(data.aws_availability_zones.available.names, index(var.private_subnet_cidrs, each.value))

  tags = {
    Name = "${var.vpc_name}-private-${each.value}"
  }
}

# --- DB Subnet Group (for multi-AZ RDS) ---
resource "aws_db_subnet_group" "this" {
  name       = "${var.vpc_name}-db-subnet-group"
  subnet_ids = values(aws_subnet.private)[*].id

  tags = {
    Name = "${var.vpc_name}-db-subnet-group"
  }
}

# --- NAT Gateway (for Private Subnets) ---
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[var.public_subnet_cidrs[0]].id

  tags = {
    Name = "${var.vpc_name}-nat"
  }

  depends_on = [aws_internet_gateway.igw]
}

# --- Route Tables ---

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.vpc_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private Route Table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.vpc_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}


