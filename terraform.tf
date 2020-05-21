terraform {
  backend "s3" {
    bucket = "tf-chip-backend-536a2f00"
    key    = "state/tfe-state-536a2f00"
    region = "us-west-1"
  }

  required_providers {
    aws = ">= 2.7.0"
  }
}