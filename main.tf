# ------------------------
# Provider & Data
# ------------------------
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"
    }
  }
  required_version = ">= 1.4.0"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "archive_file" "s3_zip" {
  type        = "zip"
  source_file = "${path.module}/s3_handler.js"
  output_path = "${path.module}/s3_handler.zip"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/index.js"
  output_path = "${path.module}/lambda.zip"
}

# ------------------------
# KMS Key for RDS
# ------------------------
resource "aws_kms_key" "rds" {
  description             = "KMS key for RDS encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 10
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "Enable IAM User Permissions"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

# ------------------------
# Networking (VPC & Security Groups)
# ------------------------
module "vpc" {
  source = "./modules/vpc"
}

resource "aws_security_group" "ecs_sg" {
  name        = "loopper-ecs-sg"
  vpc_id      = module.vpc.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db_sg" {
  name        = "loopper-db-sg"
  vpc_id      = module.vpc.vpc_id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }
}

# ------------------------
# RDS Instance
# ------------------------
resource "aws_db_subnet_group" "this" {
  name       = "loopper-db-subnet-group"
  subnet_ids = module.vpc.private_subnet_ids
}

resource "aws_db_instance" "postgres" {
  identifier                 = "loopper-postgres"
  engine                     = "postgres"
  engine_version             = "15.13"
  instance_class             = "db.t3.micro"
  allocated_storage          = 20
  username                   = "loopper"
  password                   = var.db_password
  db_subnet_group_name       = aws_db_subnet_group.this.name
  vpc_security_group_ids     = [aws_security_group.db_sg.id]
  storage_encrypted          = true
  kms_key_id                 = aws_kms_key.rds.arn
  skip_final_snapshot        = true
}

# ------------------------
# SQS Queue
# ------------------------
resource "aws_sqs_queue" "freshdesk_queue" {
  name                        = "loopper-freshdesk-queue.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 86400
  receive_wait_time_seconds   = 10
}

# ------------------------
# Lambda Function
# ------------------------
resource "aws_iam_role" "lambda_role" {
  name = "loopper-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sqs" {
  name = "lambda-sqs-publish"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sqs:SendMessage", Effect = "Allow", Resource = aws_sqs_queue.freshdesk_queue.arn }]
  })
}

resource "aws_lambda_function" "api_to_sqs" {
  function_name    = "loopper-api-to-sqs"
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  role             = aws_iam_role.lambda_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 10
  environment {
    variables = { 
      QUEUE_URL = jsondecode(aws_secretsmanager_secret_version.app_secrets.secret_string)["QUEUE_URL"]
    }
  }
}

# ------------------------
# API Gateway (HTTP API)
# ------------------------
resource "aws_apigatewayv2_api" "freshdesk_api" {
  name          = "loopper-freshdesk-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_int" {
  api_id           = aws_apigatewayv2_api.freshdesk_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.api_to_sqs.arn
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.freshdesk_api.id
  route_key = "POST /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_int.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.freshdesk_api.id
  name        = "$default"
  auto_deploy = true
}

# ------------------------
# ECS Cluster & Task
# ------------------------
resource "aws_ecs_cluster" "main" {
  name = "loopper-cluster"
}

# ------------------------
# Secrets Manager
# ------------------------
resource "aws_secretsmanager_secret" "app_secrets" {
  name        = "loopper-app-secrets"
  description = "Centralized secrets for Loopper AI services"
  # Optional: use existing KMS key if appropriate, or leave for default
  kms_key_id  = aws_kms_key.rds.arn 
}

resource "aws_secretsmanager_secret_version" "app_secrets" {
  secret_id = aws_secretsmanager_secret.app_secrets.id
  secret_string = jsonencode({
    DB_HOST          = aws_db_instance.postgres.address
    REDIS_HOST       = aws_elasticache_replication_group.redis.primary_endpoint_address
    QUEUE_URL        = aws_sqs_queue.freshdesk_queue.id
    ECS_CLUSTER      = aws_ecs_cluster.main.id
    TASK_DEFINITION_3 = aws_ecs_task_definition.task_3.arn
    PRIVATE_SUBNETS  = join(",", module.vpc.private_subnet_ids)
    ECS_SG           = aws_security_group.ecs_sg.id
  })
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "loopper-ecs-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_exec_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  # FIXED ARN
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ------------------------
# ECR Repositories
# ------------------------
resource "aws_ecr_repository" "ai_agent" {
  name         = "ai-agent"
  force_delete = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_repository" "app_server" {
  name         = "app-server"
  force_delete = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_repository" "rag_server" {
  name         = "rag-server"
  force_delete = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_iam_role_policy" "ecs_exec_policy_secrets" {
  name = "loopper-ecs-secrets-policy"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "secretsmanager:GetSecretValue"
        Effect   = "Allow"
        Resource = aws_secretsmanager_secret.app_secrets.arn
      },
      {
        Action   = "kms:Decrypt"
        Effect   = "Allow"
        Resource = aws_kms_key.rds.arn
      }
    ]
  })
}

resource "aws_ecs_task_definition" "task_1" {
  family                   = "loopper-task-1"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  container_definitions    = jsonencode([{
    name  = "loopper-app-1"
    image = "nginx:latest"
    secrets = [
      { name = "DB_HOST", valueFrom = "${aws_secretsmanager_secret.app_secrets.arn}:DB_HOST::" },
      { name = "REDIS_HOST", valueFrom = "${aws_secretsmanager_secret.app_secrets.arn}:REDIS_HOST::" }
    ]
  }])
}

resource "aws_ecs_task_definition" "task_2" {
  family                   = "loopper-task-2"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  container_definitions    = jsonencode([{
    name  = "loopper-app-2"
    image = "nginx:latest"
    secrets = [
      { name = "DB_HOST", valueFrom = "${aws_secretsmanager_secret.app_secrets.arn}:DB_HOST::" },
      { name = "REDIS_HOST", valueFrom = "${aws_secretsmanager_secret.app_secrets.arn}:REDIS_HOST::" }
    ]
  }])
}

resource "aws_ecs_service" "service_1" {
  name            = "loopper-service-1"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.task_1.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnet_ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }
}

# ------------------------
# Auto Scaling for Service 1
# ------------------------
resource "aws_appautoscaling_target" "service_1_target" {
  max_capacity       = 5
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.service_1.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "service_1_cpu" {
  name               = "service-1-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.service_1_target.resource_id
  scalable_dimension = aws_appautoscaling_target.service_1_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.service_1_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

resource "aws_appautoscaling_policy" "service_1_memory" {
  name               = "service-1-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.service_1_target.resource_id
  scalable_dimension = aws_appautoscaling_target.service_1_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.service_1_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value = 70.0
  }
}

resource "aws_ecs_service" "service_2" {
  name            = "loopper-service-2"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.task_2.arn
  desired_count   = 0
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnet_ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }
}

# ------------------------
# EventBridge Pipe (SQS -> ECS)
# ------------------------
resource "aws_iam_role" "pipe_role" {
  name = "loopper-pipe-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "pipes.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "pipe_policy" {
  name = "pipe-execution-policy"
  role = aws_iam_role.pipe_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Effect = "Allow", Resource = aws_sqs_queue.freshdesk_queue.arn },
      { Action = "ecs:RunTask", Effect = "Allow", Resource = aws_ecs_task_definition.task_2.arn },
      { Action = "iam:PassRole", Effect = "Allow", Resource = [aws_iam_role.ecs_task_execution_role.arn] }
    ]
  })
}

resource "aws_pipes_pipe" "sqs_to_ecs" {
  name     = "sqs-to-ecs-pipe"
  role_arn = aws_iam_role.pipe_role.arn
  source   = aws_sqs_queue.freshdesk_queue.arn
  target   = aws_ecs_cluster.main.arn
  
  target_parameters {
    ecs_task_parameters {
      task_definition_arn = aws_ecs_task_definition.task_2.arn
      launch_type         = "FARGATE"
      task_count          = 1

      network_configuration {
        # FIXED: subnets and security_groups must be inside aws_vpc_configuration
        aws_vpc_configuration {
          subnets         = module.vpc.private_subnet_ids
          security_groups = [aws_security_group.ecs_sg.id]
        }
      }
    }
  }
}

# ------------------------
# S3 Document Workflow
# ------------------------

resource "aws_s3_bucket" "company_docs" {
  bucket        = "loopper-company-docs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_iam_role" "s3_lambda_role" {
  name = "loopper-s3-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "s3_lambda_basic" {
  role       = aws_iam_role.s3_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "s3_lambda_policy" {
  name = "s3-lambda-policy"
  role = aws_iam_role.s3_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "ecs:RunTask"
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action   = "iam:PassRole"
        Effect   = "Allow"
        Resource = aws_iam_role.ecs_task_execution_role.arn
      },
      {
        Action   = "secretsmanager:GetSecretValue"
        Effect   = "Allow"
        Resource = aws_secretsmanager_secret.app_secrets.arn
      },
      {
        Action   = "kms:Decrypt"
        Effect   = "Allow"
        Resource = aws_kms_key.rds.arn
      }
    ]
  })
}

resource "aws_lambda_function" "s3_to_ecs" {
  function_name    = "loopper-s3-to-ecs"
  handler          = "s3_handler.handler"
  runtime          = "nodejs18.x"
  role             = aws_iam_role.s3_lambda_role.arn
  filename         = data.archive_file.s3_zip.output_path
  source_code_hash = data.archive_file.s3_zip.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      ECS_CLUSTER     = jsondecode(aws_secretsmanager_secret_version.app_secrets.secret_string)["ECS_CLUSTER"]
      TASK_DEFINITION = jsondecode(aws_secretsmanager_secret_version.app_secrets.secret_string)["TASK_DEFINITION_3"]
      SUBNETS         = jsondecode(aws_secretsmanager_secret_version.app_secrets.secret_string)["PRIVATE_SUBNETS"]
      SECURITY_GROUP  = jsondecode(aws_secretsmanager_secret_version.app_secrets.secret_string)["ECS_SG"]
    }
  }
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_to_ecs.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.company_docs.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.company_docs.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_to_ecs.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

resource "aws_ecs_task_definition" "task_3" {
  family                   = "loopper-task-3"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  container_definitions    = jsonencode([{
    name  = "loopper-app-3"
    image = "nginx:latest"
    secrets = [
      { name = "DB_HOST", valueFrom = "${aws_secretsmanager_secret.app_secrets.arn}:DB_HOST::" },
      { name = "REDIS_HOST", valueFrom = "${aws_secretsmanager_secret.app_secrets.arn}:REDIS_HOST::" }
    ]
  }])
}

resource "aws_ecs_service" "service_3" {
  name            = "loopper-service-3"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.task_3.arn
  desired_count   = 0
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnet_ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }
}

# ------------------------
# Redis (ElastiCache)
# ------------------------
resource "aws_security_group" "redis_sg" {
  name        = "loopper-redis-sg"
  description = "Allow Redis traffic from ECS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "loopper-redis-subnet-group"
  subnet_ids = module.vpc.private_subnet_ids
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "loopper-redis"
  description                = "Loopper AI Redis Cache"
  node_type                  = "cache.t3.micro"
  port                       = 6379
  parameter_group_name       = "default.redis7"
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis_sg.id]
  engine                     = "redis"
  engine_version             = "7.1"
  num_cache_clusters         = 1
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
}

# ------------------------
# Outputs
# ------------------------
output "api_endpoint" {
  value = aws_apigatewayv2_stage.default.invoke_url
}

output "repo_ai_agent_url" {
  value = aws_ecr_repository.ai_agent.repository_url
}

output "repo_app_server_url" {
  value = aws_ecr_repository.app_server.repository_url
}

output "repo_rag_server_url" {
  value = aws_ecr_repository.rag_server.repository_url
}

output "db_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "redis_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}