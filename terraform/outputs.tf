output "kubernetes_cluster_name" {
  value       = google_container_cluster.primary.name
  description = "GKE Cluster Name"
}

output "kubernetes_cluster_host" {
  value       = google_container_cluster.primary.endpoint
  description = "GKE Cluster Host"
}

output "gcp_region" {
  value       = var.region
  description = "GCP Region"
}

output "gcp_project" {
  value       = var.project_id
  description = "GCP Project ID"
}

output "artifact_registry_repo" {
  value       = google_artifact_registry_repository.systeam_repo.repository_id
  description = "Artifact Registry Repository Name"
}

output "get_credentials_command" {
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region ${var.region} --project ${var.project_id}"
  description = "Command to configure kubectl"
}
