# ---------------------------------------------------------------------------
# Post-boot application provisioning, split into two stages so the slow,
# Atlas-independent work (package installs, app source upload, DataGen data
# generation, memex build - collectively ~15 min) runs CONCURRENTLY with
# Atlas cluster creation (~10-12 min) instead of sequentially after it.
#
# Stage 1: terraform_data.bootstrap_app - depends ONLY on the EC2
# instance/EIP, not on any mongodbatlas_* resource, so Terraform starts it
# as soon as cloud-init finishes, in parallel with Atlas cluster creation.
# Uploads the app source tree (see local.app_source_dir below - the app
# lives in a private repo, not a public one Terraform can clone, so it's
# uploaded directly from the machine running terraform instead) and runs
# bootstrap.sh (installs, DataGen, memex build).
#
# Stage 2: terraform_data.provision_app - depends on BOTH bootstrap_app and
# the Atlas cluster/user/access-list, so it only starts once everything it
# needs is ready. Runs remote-setup.sh (start memex, health check, bulk
# load) - the only steps that actually require a live Mongo connection.
#
# Edit bootstrap.sh/remote-setup.sh directly (or any file under
# local.app_source_dir) - any edit plus `terraform apply` re-uploads and
# re-runs the relevant stage against the existing instance without needing
# to destroy/recreate anything.
# ---------------------------------------------------------------------------

locals {
  # Local path (on the machine running terraform) to the app source tree
  # that gets uploaded to the instance - see app-src/README.md. Defaults to
  # the app-src/ placeholder dir next to this file; override via the
  # app_source_dir variable to point at an existing checkout elsewhere.
  app_source_dir = coalesce(var.app_source_dir, "${path.module}/app-src")

  # Hash of every file under app_source_dir, used as a triggers_replace
  # input so editing anything in the app source re-uploads/re-runs
  # bootstrap_app, the same way filemd5(bootstrap.sh) does for that file.
  app_source_files = sort(fileset(local.app_source_dir, "**"))
  app_source_hash = md5(join("", [
    for f in local.app_source_files : filemd5("${local.app_source_dir}/${f}")
  ]))
}

resource "terraform_data" "bootstrap_app" {
  triggers_replace = [
    filemd5("${path.module}/bootstrap.sh"),
    local.app_source_hash,
  ]

  connection {
    type        = "ssh"
    host        = aws_eip.app.public_ip
    user        = "ec2-user"
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "10m"
  }

  # Gate on cloud-init being fully finished before doing anything else - this
  # is the "once the instance is up, not cloud-init" boundary.
  provisioner "remote-exec" {
    inline = ["cloud-init status --wait"]
  }

  # Upload the app source tree in place of a git clone (the app lives in a
  # private repo, not a public one Terraform can clone). Trailing slash on
  # the source means "upload the contents of this directory", so whatever
  # local.app_source_dir contains (DataGen/, memex/, SearchPerfTest/ etc.
  # for this example) lands directly under $HOME/app on the instance.
  provisioner "file" {
    source      = "${local.app_source_dir}/"
    destination = "/home/ec2-user/app"
  }

  provisioner "file" {
    source      = "${path.module}/bootstrap.sh"
    destination = "/home/ec2-user/bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/ec2-user/bootstrap.sh",
      "/home/ec2-user/bootstrap.sh",
    ]
  }

  # Deliberately NOT depending on any mongodbatlas_* resource - this is what
  # lets it run concurrently with Atlas cluster creation.
  depends_on = [
    aws_instance.app,
    aws_eip.app,
  ]
}

locals {
  # Full mongodb+srv connection URI with credentials and default database
  # embedded, e.g. mongodb+srv://user:pass@cluster0.xxxxx.mongodb.net/dbname
  mongo_uri = "${replace(
    mongodbatlas_advanced_cluster.this.connection_strings.standard_srv,
    "mongodb+srv://",
    "mongodb+srv://${urlencode(var.db_username)}:${urlencode(var.db_password)}@"
  )}/${var.db_name}?retryWrites=true&w=majority"

  rendered_env = templatefile("${path.module}/templates/env.tpl", {
    mongo_uri    = local.mongo_uri
    db_name      = var.db_name
    db_username  = var.db_username
    cluster_name = mongodbatlas_advanced_cluster.this.name
  })
}

resource "terraform_data" "provision_app" {
  triggers_replace = [
    filemd5("${path.module}/remote-setup.sh"),
    filemd5("${path.module}/shard-listing.js"),
    sha256(local.rendered_env),
  ]

  connection {
    type        = "ssh"
    host        = aws_eip.app.public_ip
    user        = "ec2-user"
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "10m"
  }

  # Gate on cloud-init being fully finished before doing anything else - this
  # is the "once the instance is up, not cloud-init" boundary.
  provisioner "remote-exec" {
    inline = ["cloud-init status --wait"]
  }

  provisioner "file" {
    content     = local.rendered_env
    destination = "/home/ec2-user/.env"
  }

  provisioner "file" {
    source      = "${path.module}/remote-setup.sh"
    destination = "/home/ec2-user/remote-setup.sh"
  }

  provisioner "file" {
    source      = "${path.module}/shard-listing.js"
    destination = "/home/ec2-user/shard-listing.js"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 /home/ec2-user/.env",
      "chmod +x /home/ec2-user/remote-setup.sh",
      "/home/ec2-user/remote-setup.sh",
    ]
  }

  depends_on = [
    aws_instance.app,
    aws_eip.app,
    terraform_data.bootstrap_app,
    mongodbatlas_advanced_cluster.this,
    mongodbatlas_database_user.app,
    mongodbatlas_project_ip_access_list.ec2,
  ]
}
