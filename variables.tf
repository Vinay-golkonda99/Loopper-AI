variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
  default     = "MySafePass123!"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for private subnet"
  default     = "10.0.1.0/24"
}

variable "az" {
  description = "Availability Zone"
  default     = "eu-west-1a"
}
