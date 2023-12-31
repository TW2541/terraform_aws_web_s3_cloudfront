# Define input variables
variable "bucket_name" {}
variable "organization" {}
variable "aws_credential_path" {}
variable "aws_config_path" {}
variable "bucket_tag_name" {}
variable "domain_name" {}
variable "domain_name_hosted_zone_id" {}
variable "oac_id" {}
variable "root_domain_name" {}

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

resource "aws_route53_record" "acm_record" {
  depends_on = [aws_acm_certificate.ssl_certificate]
  provider        = aws.northVirginia

  for_each = {
    for dvo in aws_acm_certificate.ssl_certificate.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 300
  type            = each.value.type
  zone_id         = var.domain_name_hosted_zone_id
}

resource "aws_acm_certificate_validation" "ssl_certificate_validation" {
  depends_on = [aws_route53_record.acm_record]

  provider        = aws.northVirginia
  certificate_arn = aws_acm_certificate.ssl_certificate.arn
  
}

# Define a local variable for the CloudFront origin ID
locals {
  s3_origin_id = "myS3Origin"
}

resource "aws_cloudfront_origin_access_control" "s3_oac" {
  name                              = "myS3OAC"
  description                       = "OAC for S3"
  origin_access_control_origin_type = "s3"
  signing_protocol                  = "sigv4"
  signing_behavior                  = "always"
}

# Create an AWS CloudFront distribution
resource "aws_cloudfront_distribution" "s3_distribution" {
  # Depend on the ACM certificate validation before creating the CloudFront distribution
  depends_on = [aws_acm_certificate_validation.ssl_certificate_validation, aws_cloudfront_origin_access_control.s3_oac]

  # Configure the CloudFront distribution's origin settings
  origin {
    domain_name              = aws_s3_bucket.deploy_bucket.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
    origin_id                = local.s3_origin_id
  }

  # Enable the CloudFront distribution and other settings
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "This is a CloudFront distribution for ${var.bucket_tag_name} website"
  default_root_object = "index.html"

  # Configure aliases for the CloudFront distribution
  aliases = ["${var.domain_name}"]

  # Configure default cache behavior
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    compress = true

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
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

resource "aws_s3_bucket_policy" "allow_access_from_cloudfront" {
  depends_on = [aws_cloudfront_distribution.s3_distribution]

  bucket = aws_s3_bucket.deploy_bucket.id
  policy = jsonencode({
        "Version": "2008-10-17",
        "Id": "PolicyForCloudFrontPrivateContent",
        "Statement": [
            {
                "Sid": "AllowCloudFrontServicePrincipal",
                "Effect": "Allow",
                "Principal": {
                    "Service": "cloudfront.amazonaws.com"
                },
                "Action": "s3:GetObject",
                "Resource": "${aws_s3_bucket.deploy_bucket.arn}/*",
                "Condition": {
                    "StringEquals": {
                      "AWS:SourceArn": "${aws_cloudfront_distribution.s3_distribution.arn}"
                    }
                }
            }
        ]
      })
}

# Create an Alias DNS record for the root domain pointing to CloudFront distribution
resource "aws_route53_record" "alias_cloudfront" {
  depends_on = [aws_cloudfront_distribution.s3_distribution]

  zone_id = var.domain_name_hosted_zone_id
  name    = var.domain_name
  type    = "A"

  # Configure an alias to the CloudFront distribution
  alias {
    name                   = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
    evaluate_target_health = true
  }
}

# Create an Alias DNS record for the www subdomain pointing to the root domain's Alias record
resource "aws_route53_record" "alias_www" {
  depends_on = [aws_route53_record.alias_cloudfront]

  zone_id = var.domain_name_hosted_zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  # Configure an alias to the root domain's Alias record
  alias {
    name                   = var.domain_name
    zone_id                = var.domain_name_hosted_zone_id
    evaluate_target_health = true
  }
}
