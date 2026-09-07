output "atlas_cluster_name" {
  description = "Name of the Atlas cluster."
  value       = mongodbatlas_advanced_cluster.this.name
}

output "atlas_connection_string_srv" {
  description = "Standard SRV connection string for the Atlas cluster (public endpoint)."
  value       = mongodbatlas_advanced_cluster.this.connection_strings.standard_srv
}

output "atlas_num_shards" {
  description = "Current number of shards deployed."
  value       = var.num_shards
}

output "ec2_public_ip" {
  description = "Static public (Elastic) IP of the EC2 app instance."
  value       = aws_eip.app.public_ip
}

output "ec2_instance_id" {
  description = "Instance ID of the EC2 app instance."
  value       = aws_instance.app.id
}

output "ssh_private_key_path" {
  description = "Local path to the generated SSH private key file."
  value       = local_sensitive_file.private_key.filename
}

output "ssh_command" {
  description = "Command to SSH into the EC2 instance."
  value       = "ssh -i ${local_sensitive_file.private_key.filename} -L 8080:localhost:8080 ec2-user@${aws_eip.app.public_ip}"
}

output "provision_hint" {
  description = "Reminder about the post-boot provisioning stage."
  value       = "terraform_data.provision_app runs remote-setup.sh on the instance after cloud-init finishes. Edit terraform/remote-setup.sh and re-run 'terraform apply' to re-upload and re-run it. Requires ssh_admin_cidr to still match your current public IP."
}
