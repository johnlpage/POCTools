# ---------------------------------------------------------------------------
# One-off perf test pass, run only after the entire base setup (memex
# started, healthy, per terraform_data.provision_app in provision.tf) has
# finished. Uploads and runs perf-test.sh, which:
#   1. Sequentially bulk-loads every listings_*.json file via
#      POST /api/listings, timing the whole pass.
#   2. Sequentially reloads listings_0/1/2.json via
#      POST /api/listings?futz=true, twice, timing the whole pass.
#   3. Generates a fresh 10,000-query Atlas Search pool and replays it with
#      32 concurrent threads via SearchPerfTest/run_queries.sh (already
#      present on the box via bootstrap.sh's git clone of the app repo).
#
# This can take a long time (bulk-loading millions of documents plus a
# 10,000-request search load test), hence the generous connection timeout
# below. Edit perf-test.sh and re-run `terraform apply` to re-upload and
# re-run it against the already-running instance (same pattern as
# remote-setup.sh) - safe to re-run since the default REPLACE update
# strategy upserts by _id rather than duplicating documents.
# ---------------------------------------------------------------------------
resource "terraform_data" "perf_test" {
  triggers_replace = [
    filemd5("${path.module}/perf-test.sh"),
  ]

  connection {
    type        = "ssh"
    host        = aws_eip.app.public_ip
    user        = "ec2-user"
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "6h"
  }

  provisioner "file" {
    source      = "${path.module}/perf-test.sh"
    destination = "/home/ec2-user/perf-test.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/ec2-user/perf-test.sh",
      "/home/ec2-user/perf-test.sh",
    ]
  }

  depends_on = [
    terraform_data.provision_app,
  ]
}
