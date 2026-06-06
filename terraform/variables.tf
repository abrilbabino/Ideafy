variable "project_id" {
  description = "The GCP project ID"
  type        = string
  default     = "project-1944cf83-7f15-4f33-89b"
}

variable "region" {
  description = "The region to deploy to"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "The name of the GKE cluster"
  type        = string
  default     = "systeam-gke-cluster"
}
