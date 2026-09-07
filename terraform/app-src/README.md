# Application source (uploaded, not cloned)

This directory is a placeholder. The application code (the private `ListTest`
app - `DataGen/`, `memex/`, `SearchPerfTest/`, etc.) is **not** in a public
repo, so Terraform no longer `git clone`s it on the EC2 instance. Instead,
`terraform_data.bootstrap_app` (see `provision.tf`) uploads it directly from
the machine running `terraform apply` via a `file` provisioner.

Before running `terraform apply`, either:

1. Check out / copy the app source into this directory (so it contains
   `DataGen/`, `memex/`, `SearchPerfTest/` at its root), or
2. Point the `app_source_dir` variable at wherever you already have it
   checked out, e.g. in `terraform.tfvars`:

   ```hcl
   app_source_dir = "/Users/you/Documents/Source/ListTest"
   ```

Whatever directory `app_source_dir` resolves to is uploaded as-is to
`$HOME/ListTest` on the instance. Re-running `terraform apply` after
changing any file under it re-uploads and re-runs bootstrap.sh against the
existing instance (same pattern as editing bootstrap.sh/remote-setup.sh
directly).
