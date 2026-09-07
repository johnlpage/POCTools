locals {
  # plantimestamp() is stable and known at plan time. Combining provider-level
  # default_tags with a tag value that's only known *after* apply (e.g. a
  # time_static resource on a fresh deploy with no prior state) causes AWS
  # provider errors like "Provider produced inconsistent final plan ... new
  # element appeared" partway through apply.
  auto_expire_time = timeadd(plantimestamp(), "48h")

  common_tags = {
    owner     = var.tag_owner
    expire_on = coalesce(var.tag_expire_on, local.auto_expire_time)
    purpose   = var.tag_purpose
  }
}

# AWS provider credentials are picked up from the standard AWS credential
# chain (env vars, shared config/profile, or instance/role credentials).
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }

  # Some resources in this account get tagged out-of-band by an
  # infosec/compliance automation shortly after creation. Without this,
  # every subsequent plan shows spurious drift ("tags changed") for tags
  # Terraform never set and doesn't manage.
  ignore_tags {
    keys = [
      "mongodb:infosec:creationTime",
      "mongodb:infosec:lastModifiedTime",
      "mongodb:infosec:creatorIAMRole",
      "mongodb:infosec:creatorIAMUser",
      "mongodb:infosec:creator",
      "mongodb:infosec:WhatIsThis",
    ]
  }
}

# MongoDB Atlas provider credentials are picked up from the standard
# environment variables MONGODB_ATLAS_PUBLIC_KEY / MONGODB_ATLAS_PRIVATE_KEY
# (or MONGODB_ATLAS_ACCESS_TOKEN for programmatic API tokens). Do not hardcode
# credentials here or in tfvars files.
provider "mongodbatlas" {}
