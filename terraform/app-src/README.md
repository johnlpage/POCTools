# Application source (uploaded, not cloned)

This directory is a placeholder. Your application code is assumed to live in
a private repo (not one Terraform can `git clone` on the EC2 instance), so
instead `terraform_data.bootstrap_app` (see `provision.tf`) uploads it
directly from the machine running `terraform apply` via a `file`
provisioner.

For this example, `bootstrap.sh` expects the uploaded tree to contain
`DataGen/` and `memex/` at its root (and `perf-test.sh` additionally expects
`SearchPerfTest/`) - adjust those scripts' `APP_DIR` usage if your own
app's layout differs.

Before running `terraform apply`, either:

1. Check out / copy your app source into this directory, or
2. Point the `app_source_dir` variable at wherever you already have it
   checked out, e.g. in `terraform.tfvars`:

   ```hcl
   app_source_dir = "/Users/you/Documents/Source/your-app"
   ```

Whatever directory `app_source_dir` resolves to is uploaded as-is to
`$HOME/app` on the instance. Re-running `terraform apply` after changing
any file under it re-uploads and re-runs bootstrap.sh against the existing
instance (same pattern as editing bootstrap.sh/remote-setup.sh directly).
