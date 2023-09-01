variable "bucket_name" {}

backend "s3" {
    bucket = "tf-state-${var.bucket_name}"
    key    = "terraform.tfstate"
    region = "ap-southeast-1"
}