# Define input variables
variable "bucket_name" {}
variable "organization" {}
variable "aws_credential_path" {}
variable "aws_config_path" {}
variable "bucket_tag_name" {}
variable "domain_name" {}

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

# Configure another AWS provider in North Virginia region and credentials
provider "aws" {
  alias                    = "northVirginia"
  region                   = "us-east-1"
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

# Define an ACM SSL certificate resource
resource "aws_acm_certificate" "ssl_certificate" {
  provider          = aws.northVirginia
  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = {
    Name         = "${var.bucket_tag_name} SSL Cert"
    Organization = var.organization
  }

  # Specify that a new certificate should be created before the old one is destroyed
  lifecycle {
    create_before_destroy = true
  }
}

# Define ACM certificate validation using Route 53 records
resource "aws_acm_certificate_validation" "cert_validation" {
  provider   = aws.northVirginia
  depends_on = [aws_acm_certificate.ssl_certificate]

  certificate_arn = aws_acm_certificate.ssl_certificate.arn

  # Get the FQDNs of Route 53 validation records for the certificate
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# Define a local variable for the CloudFront origin ID
locals {
  s3_origin_id = "myS3Origin"
}

# Create an AWS CloudFront distribution
resource "aws_cloudfront_distribution" "s3_distribution" {
  # Depend on the ACM certificate validation before creating the CloudFront distribution
  depends_on = [aws_acm_certificate_validation.cert_validation]

  # Configure the CloudFront distribution's origin settings
  origin {
    domain_name              = aws_s3_bucket.deploy_bucket.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.default.id
    origin_id                = local.s3_origin_id
  }

  # Enable the CloudFront distribution and other settings
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "This is a CloudFront distribution for ${var.bucket_tag_name} website"
  default_root_object = "index.html"

  # Configure aliases for the CloudFront distribution
  aliases = ["${var.domain_name}", "www.${var.domain_name}"]

  # Configure default cache behavior
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    compress = true

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  # Configure price class and geo restrictions
  price_class = "PriceClass_200"
  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["TH", "US"]
    }
  }

  # Configure tags for the CloudFront distribution
  tags = {
    Name         = "${var.bucket_tag_name} Cloudfront Distribution"
    Organization = var.organization
  }

  # Configure viewer certificate settings
  viewer_certificate {
    cloudfront_default_certificate = true
    acm_certificate_arn            = aws_acm_certificate.ssl_certificate.arn
    ssl_support_method             = "sni-only"
    minimum_protocol_version       = "TLSv1"
  }
}

