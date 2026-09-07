# ---------------------------------------------------------------------------
# Atlas cluster - REPLICASET or SHARDED, driven entirely by `num_shards`.
#
# num_shards = 0 deploys a single REPLICASET (one 3-node electable replica
# set, no sharding). num_shards >= 1 deploys a SHARDED cluster with that
# many shards, each its own 3-node electable replica set at
# `atlas_instance_size` in a single AWS region. Atlas does not support
# single-node replica sets for M10+ dedicated tiers, 3 electable nodes is
# the minimum viable/HA configuration either way.
#
# To change shard count later, update `num_shards` and re-apply.
#
# IMPORTANT - this is ONE-DIRECTIONAL: going from 0 -> >=1 converts the
# cluster from REPLICASET to SHARDED IN-PLACE (Atlas reboots all nodes, no
# destroy/recreate, no data loss - confirmed via direct Atlas API testing).
# Atlas does NOT support converting a SHARDED cluster back to REPLICASET at
# all, even via API/UI. Going from >=1 -> 0 therefore forces Terraform to
# destroy and recreate the entire cluster resource (full data loss) - it is
# not an online operation in that direction.
# ---------------------------------------------------------------------------
locals {
  is_sharded = var.num_shards > 0
  # REPLICASET must have exactly one replication_specs entry.
  effective_shard_count = local.is_sharded ? var.num_shards : 1
}

resource "mongodbatlas_advanced_cluster" "this" {
  project_id     = var.atlas_project_id
  name           = var.atlas_cluster_name
  cluster_type   = local.is_sharded ? "SHARDED" : "REPLICASET"
  backup_enabled = var.atlas_backup_enabled

  # Pinned to MongoDB 8.0 via LTS: Atlas will only apply patch releases
  # within the 8.0 line and will NOT auto-upgrade to the next major/rapid
  # release. mongo_db_major_version is required (and only valid) when
  # version_release_system = "LTS".
  version_release_system = "LTS"
  mongo_db_major_version = "8.0"

  # Cap the oplog at a fixed 16GB instead of Atlas's default of sizing it to
  # hold ~24h of writes - at large-scale load-test throughput, a 24h oplog
  # can grow large enough to fill the disk. See AtlasClusterManager.java
  # (UniBench) for the equivalent raw-API approach (a separate PATCH to
  # .../clusters/{name}/processArgs with {"oplogSizeMB": N}) - the
  # mongodbatlas_advanced_cluster Terraform resource exposes the same
  # setting directly via advanced_configuration, so no separate API call or
  # extra resource is needed here.
  advanced_configuration = {
    oplog_size_mb = 16384
  }

  replication_specs = [
    for shard in range(local.effective_shard_count) : {
      region_configs = [
        {
          electable_specs = {
            instance_size = var.atlas_instance_size
            node_count    = 3
            disk_size_gb  = var.atlas_disk_size_gb
          }
          provider_name = "AWS"
          priority      = 7
          region_name   = var.atlas_region_name
        }
      ]
    }
  ]

  tags = {
    project     = "proplist"
    environment = "dev"
  }
}

# ---------------------------------------------------------------------------
# IP Access List: allow the EC2 instance's Elastic IP to reach the cluster
# over its public connection string (TLS-encrypted).
# ---------------------------------------------------------------------------
resource "mongodbatlas_project_ip_access_list" "ec2" {
  project_id = var.atlas_project_id
  ip_address = aws_eip.app.public_ip
  comment    = "PropList EC2 app instance (${aws_instance.app.id})"
}

# ---------------------------------------------------------------------------
# Application database user used by the EC2 instance to authenticate.
# ---------------------------------------------------------------------------
resource "mongodbatlas_database_user" "app" {
  project_id         = var.atlas_project_id
  username           = var.db_username
  password           = var.db_password
  auth_database_name = "admin"

  # Atlas does not expose "dbOwner" as an assignable database user role (its
  # supported per-database roles are read/readWrite/dbAdmin/enableSharding
  # plus the AnyDatabase variants - Atlas manages user administration
  # itself, so userAdmin isn't offered either). dbOwner is really just
  # readWrite + dbAdmin + userAdmin combined, so granting both readWrite and
  # dbAdmin scoped to db_name is the closest equivalent: full data access
  # (including implicitly creating the database on first write) plus schema
  # administration (creating/dropping indexes, including the Atlas Search
  # indexes memex creates during its preflight startup check).
  roles {
    role_name     = "readWrite"
    database_name = var.db_name
  }

  roles {
    role_name     = "dbAdmin"
    database_name = var.db_name
  }

  # Required to run sh.enableSharding()/sh.shardCollection() (shard-listing.js)
  # - readWrite/dbAdmin alone don't grant the enableSharding privilege
  # action. Atlas requires this role to be scoped to "admin", not db_name,
  # even though the privilege applies cluster-wide to any database. Only
  # relevant/grantable meaningfully when actually deploying a sharded
  # cluster (num_shards > 0) - omitted for a plain REPLICASET.
  dynamic "roles" {
    for_each = local.is_sharded ? [1] : []
    content {
      role_name     = "enableSharding"
      database_name = "admin"
    }
  }

  scopes {
    name = mongodbatlas_advanced_cluster.this.name
    type = "CLUSTER"
  }
}
