provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}

provider "aws" {
  alias  = "us-west-1"
  region = "us-west-1"
}

data "aws_availability_zones" "east-azs" {
  provider = aws.us-east-1
  state    = "available"
}

module "east-vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "east-vpc"
  cidr = "10.0.0.0/16"

  # Grab entire set of names if needed from data source
  azs = [data.aws_availability_zones.east-azs.names[0], data.aws_availability_zones.east-azs.names[1], data.aws_availability_zones.east-azs.names[2]]

  # Use cidrsubnet function with for_each to create the right number of subnets
  #   public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  public_subnets = [
    for az in data.aws_availability_zones.east-azs.names :
    cidrsubnet("10.0.0.0/16", 8, index(data.aws_availability_zones.east-azs.names, az) + 101)
  ]

  providers = {
    aws = aws.us-east-1
  }
}

data "aws_availability_zones" "west-azs" {
  provider = aws.us-west-1
  state    = "available"
}

module "west-vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "west-vpc"
  cidr = "10.1.0.0/16"

  # Grab entire set of names if needed from data source
  azs = [data.aws_availability_zones.west-azs.names[0], data.aws_availability_zones.west-azs.names[1]]

  # Use cidrsubnet function with for_each to create the right number of subnets
  #   public_subnets  = ["10.1.101.0/24", "10.1.102.0/24", "10.1.103.0/24"]
  public_subnets = [
    for az in data.aws_availability_zones.west-azs.names :
    cidrsubnet("10.1.0.0/16", 8, index(data.aws_availability_zones.west-azs.names, az) + 101)
  ]

  providers = {
    aws = aws.us-west-1
  }
}

resource "aws_vpc_peering_connection" "peer" {
  provider    = aws.us-east-1
  vpc_id      = module.east-vpc.vpc_id
  peer_vpc_id = module.west-vpc.vpc_id
  peer_region = "us-west-1"
  auto_accept = false
}

# Accepter's side of the connection.
resource "aws_vpc_peering_connection_accepter" "peer" {
  provider                  = aws.us-west-1
  vpc_peering_connection_id = aws_vpc_peering_connection.peer.id
  auto_accept               = true
}

resource "aws_default_security_group" "east-vpc" {
  provider = aws.us-east-1
  vpc_id   = module.east-vpc.vpc_id

  ingress {
    protocol    = -1
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_default_security_group" "west-vpc" {
  provider = aws.us-west-1
  vpc_id   = module.west-vpc.vpc_id

  ingress {
    protocol    = -1
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_route" "east-vpc" {
  provider = aws.us-east-1
  for_each = {
    for cidrroute in local.us-east-1-routes : "${cidrroute.cidr_block}.${cidrroute.route_table_id}" => cidrroute
  }
  # Need to create a route for every combination of route_table_id on module.east-vpc.public_route_table_ids with every cidr_block on module.west-vpc.public_cidr_blocks. Look into setproduct function. Using setproduct, element, and length, this can be done dynamically
  # count                     = 1
  route_table_id            = each.value.route_table_id
  destination_cidr_block    = each.value.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.peer.id
}

resource "aws_route" "west-vpc" {
  provider = aws.us-west-1
  for_each = {
    for cidrroute in local.us-west-1-routes : "${cidrroute.cidr_block}.${cidrroute.route_table_id}" => cidrroute
  }
  # Need to create a route for every combination of route_table_id on module.west-vpc.public_route_table_ids with every cidr_block on module.east-vpc.public_cidr_blocks. Look into setproduct function. Using setproduct, element, and length, this can be done dynamically
  # count                     = 1
  route_table_id            = each.value.route_table_id
  destination_cidr_block    = each.value.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.peer.id
}

resource "aws_kms_key" "kms-tfe-key" {
  provider    = aws.us-west-1
  description = "KMS TFE key"
}

resource "aws_route53_zone" "r53-hosted-zone" {
  name = "chipkyleobservian2.com."
}

resource "aws_key_pair" "pub-keypair" {
  provider = aws.us-west-1

  key_name   = "id_rsa"
  public_key = var.public_key
}

module "tfe" {
  source = "./modules/terraform-chip-tfe-is-terraform-aws-ptfe-v4-quick-install-master"
  providers = {
    aws = aws.us-west-1
  }

  friendly_name_prefix = "kyle-chip"
  common_tags = {
    "Environment" = "CHIPMay2020"
    "Tool"        = "Terraform"
    "Owner"       = "KyleEastman"
  }
  tfe_hostname               = "tfe.${aws_route53_zone.r53-hosted-zone.name}"
  tfe_license_file_path      = "./terraform-chip.rli"
  tfe_release_sequence       = "414"
  tfe_initial_admin_username = "tfe-local-admin"
  tfe_initial_admin_email    = "kyle@observian.com"
  tfe_initial_admin_pw       = "ThisAintSecure123!"
  tfe_initial_org_name       = "observian-org"
  tfe_initial_org_email      = "kyle@observian.com"
  vpc_id                     = module.east-vpc.vpc_id
  alb_subnet_ids             = module.east-vpc.public_subnets
  ec2_subnet_ids             = module.east-vpc.private_subnets
  route53_hosted_zone_name   = aws_route53_zone.r53-hosted-zone.name
  kms_key_arn                = aws_kms_key.kms-tfe-key.arn
  ingress_cidr_alb_allow     = ["0.0.0.0/0"]
  ingress_cidr_ec2_allow     = [var.home_ip]
  ssh_key_pair               = aws_key_pair.pub-keypair.key_name
  rds_subnet_ids             = module.east-vpc.private_subnets
  #   instance_size              = "t2.small"
  #   rds_instance_size          = "t2.small"
}

output "tfe_url" {
  value = module.tfe.tfe_url
}

output "tfe_admin_console_url" {
  value = module.tfe.tfe_admin_console_url
}

locals {
  east-cidr = "10.0.0.0/16"
  west-cidr = "10.1.0.0/16"
  us-west-1-routes = [
    for pair in setproduct(module.west-vpc.public_subnets_cidr_blocks, module.east-vpc.public_route_table_ids) : {
      cidr_block     = pair[0]
      route_table_id = pair[1]
    }
  ]
  us-east-1-routes = [
    for pair in setproduct(module.east-vpc.public_subnets_cidr_blocks, module.west-vpc.public_route_table_ids) : {
      cidr_block     = pair[0]
      route_table_id = pair[1]
    }
  ]
}
