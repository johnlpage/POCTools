variable "aws_region" {
  description = "AWS region to deploy the EC2 instance and align the Atlas cluster region with."
  type        = string
  default     = "us-east-1"
}

variable "atlas_region_name" {
  description = "Atlas region name (Atlas's naming convention, not AWS's) corresponding to aws_region."
  type        = string
  default     = "US_EAST_1"
}

# ---------------------------------------------------------------------------
# MongoDB Atlas
# ---------------------------------------------------------------------------

variable "atlas_project_id" {
  description = "Existing MongoDB Atlas Project ID (groupId) to create the cluster in."
  type        = string
}

variable "atlas_cluster_name" {
  description = "Name of the Atlas cluster as it will appear in the Atlas UI. Cannot be changed after creation without destroying/recreating the cluster."
  type        = string
  default     = "proplist-cluster"
}

variable "atlas_instance_size" {
  description = "Atlas cluster tier / instance size for each shard's electable nodes (e.g. M30, M40, M50)."
  type        = string
  default     = "M30"
}

variable "num_shards" {
  description = "Number of shards. 0 deploys a single REPLICASET (one 3-node electable replica set, no sharding). >=1 deploys a SHARDED cluster with that many shards, each its own 3-node electable replica set of atlas_instance_size. Increasing from 0 to >=1 converts the cluster to SHARDED in-place (no data loss). Atlas does not support converting SHARDED back to REPLICASET at all, so decreasing from >=1 to 0 forces Terraform to destroy and recreate the entire cluster (full data loss)."
  type        = number
  default     = 0

  validation {
    condition     = var.num_shards >= 0
    error_message = "num_shards must be 0 (replica set) or greater (sharded)."
  }
}

variable "atlas_disk_size_gb" {
  description = "Disk size in GB for each shard's electable nodes."
  type        = number
  default     = 10
}

variable "atlas_backup_enabled" {
  description = "Whether to enable Atlas Cloud Backup for the cluster."
  type        = bool
  default     = true
}

variable "db_username" {
  description = "Username for the Atlas database user created for application access from the EC2 instance."
  type        = string
  default     = "propListApp"
}

variable "db_password" {
  description = "Password for the Atlas database user. Supply via TF_VAR_db_password env var or a gitignored *.auto.tfvars file - do not commit this value."
  type        = string
  sensitive   = true
}

variable "db_name" {
  description = "Name of the application database the db_username will be scoped readWrite access to."
  type        = string
  default     = "proplist"
}

# ---------------------------------------------------------------------------
# EC2
# ---------------------------------------------------------------------------

variable "ec2_instance_type" {
  description = "EC2 instance type for the application host. Default is 4 vCPU / 8 GiB RAM (compute-optimized)."
  type        = string
  default     = "c6i.xlarge"
}

variable "ssh_admin_cidr" {
  description = "CIDR block allowed to SSH (port 22) into the EC2 instance. Set this to your own IP in CIDR form, e.g. 203.0.113.10/32."
  type        = string
}

variable "key_pair_name" {
  description = "Name to give the AWS key pair that Terraform generates for SSH access to the EC2 instance."
  type        = string
  default     = "proplist-ec2-key"
}

variable "java_version" {
  description = "Java (Amazon Corretto) major version to install on the EC2 instance via dnf."
  type        = string
  default     = "21"
}

variable "app_source_dir" {
  description = "Local path (on the machine running terraform) to the application source tree to upload to the EC2 instance - must contain DataGen/, memex/ and SearchPerfTest/ at its root. The app code lives in a private repo, not a public one Terraform can clone, so it's uploaded directly instead. Defaults to the app-src/ placeholder directory next to this file; either check the app out there or point this at an existing checkout (see terraform/app-src/README.md)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Common tags applied to AWS resources (merged with the provider-level default_tags in providers.tf)."
  type        = map(string)
  default = {
    Project     = "PropList"
    ManagedBy   = "terraform"
    Environment = "dev"
  }
}

# ---------------------------------------------------------------------------
# Resource tags (provider-level default_tags - see providers.tf). Applied
# automatically to every taggable AWS resource, matching the convention used
# in /Users/jlp/Documents/Source/OIDCTest/terraform/main.tf.
# ---------------------------------------------------------------------------
variable "tag_owner" {
  type        = string
  default     = "john.page"
  description = "Value for the 'owner' default tag applied to all AWS resources"
}

variable "tag_purpose" {
  type        = string
  default     = "other"
  description = "Value for the 'purpose' default tag applied to all AWS resources"
}

variable "tag_expire_on" {
  type        = string
  default     = null
  description = "Value for the 'expire_on' default tag. Leave unset (null) to auto-compute as 48h from plan time; set explicitly to pin/override it."
}
