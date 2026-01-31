# outputs.tf for VPC module

# VPC ID
output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.this.id
}

# Public Subnet IDs
output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = [for cidr in sort(var.public_subnet_cidrs) : aws_subnet.public[cidr].id]
}

# Private Subnet IDs
output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = [for cidr in sort(var.private_subnet_cidrs) : aws_subnet.private[cidr].id]
}

# Internet Gateway ID
output "igw_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.igw.id
}

# RDS DB Subnet Group ID
output "db_subnet_group_id" {
  description = "RDS DB Subnet Group ID"
  value       = aws_db_subnet_group.this.id
}

# RDS DB Subnet Group Name (needed for aws_db_instance)
output "db_subnet_group_name" {
  description = "RDS DB Subnet Group Name"
  value       = aws_db_subnet_group.this.name
}

# Optional: VPC name
output "vpc_name" {
  description = "Name of the VPC"
  value       = var.vpc_name
}
