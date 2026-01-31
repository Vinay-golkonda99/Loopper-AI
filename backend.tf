terraform {
  backend "s3" {
    bucket = "loopper-terraform-state-prod"
    key    = "loopper-ai/terraform.tfstate"
    region = "eu-west-1"
    encrypt = true
    dynamodb_table = "terraform-locks"
  }
}
