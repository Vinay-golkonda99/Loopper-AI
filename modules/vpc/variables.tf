variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "List of public subnet CIDRs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]  # For multi-AZ
}

variable "private_subnet_cidrs" {
  description = "List of private subnet CIDRs"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"] # For multi-AZ
}

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
  default     = "loopper-ai-vpc"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}
