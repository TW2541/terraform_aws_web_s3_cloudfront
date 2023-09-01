# Define input variables
variable "bucket_name" {}
variable "organization" {}
variable "aws_credential_path" {}
variable "aws_config_path" {}
variable "bucket_tag_name" {}

# Configure required Terraform providers and S3 backend for state storage
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Configure AWS provider with region and credentials
provider "aws" {
  shared_config_files      = [var.aws_config_path]
  shared_credentials_files = [var.aws_credential_path]
  profile                  = "default"
}

# Define an S3 bucket resource with tags
resource "aws_s3_bucket" "deploy_bucket" {
  bucket = var.bucket_name

  tags = {
    Name         = "${var.bucket_tag_name} Bucket"
    Organization = var.organization
  }
}

# Configure ownership controls for the S3 bucket
resource "aws_s3_bucket_ownership_controls" "deploy_bucket_ownership_controls" {
  depends_on = [aws_s3_bucket.deploy_bucket]

  bucket = aws_s3_bucket.deploy_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Configure ACL for the S3 bucket
resource "aws_s3_bucket_acl" "deploy_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.deploy_bucket_ownership_controls]

  bucket = aws_s3_bucket.deploy_bucket.id
  acl    = "private"
}

# Configure website configuration for the S3 bucket
resource "aws_s3_bucket_website_configuration" "deploy_bucket_web_config" {
  depends_on = [aws_s3_bucket.deploy_bucket]

  bucket = aws_s3_bucket.deploy_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

# Create a dependency chain for S3 bucket-related resources
resource "null_resource" "s3_dependencies" {
  depends_on = [
    aws_s3_bucket_acl.deploy_bucket_acl,
    aws_s3_bucket_website_configuration.deploy_bucket_web_config
  ]
}

# Copy static files to the S3 bucket after dependencies are met
resource "null_resource" "deploy_static_files" {
  depends_on = [null_resource.s3_dependencies]

  provisioner "local-exec" {
    command = "aws s3 sync ../build/ s3://${aws_s3_bucket.deploy_bucket.id}"
  }
}
