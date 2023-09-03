terraform init -reconfigure -backend-config=backend.tf 
terraform plan -var-file=variables.tfvars
terraform apply -var-file=variables.tfvars