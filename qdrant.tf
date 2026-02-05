provider "qdrant-cloud" {
  api_key = jsondecode(aws_secretsmanager_secret_version.app_secrets.secret_string)["QDRANT_API_KEY"]
}

# ------------------------
# Managed Qdrant Connection (PrivateLink)
# ------------------------

# NOTE: This requires the Service Name from the Qdrant Cloud Console
# resource "aws_vpc_endpoint" "qdrant" {
#   vpc_id              = module.vpc.vpc_id
#   service_name        = "PLACEHOLDER_FROM_QDRANT_CONSOLE"
#   vpc_endpoint_type   = "Interface"
#   subnet_ids          = module.vpc.private_subnet_ids
#   security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
#   private_dns_enabled = true
# }
