output "ecr_repository_url" {
  description = "Paste this into k8s/deployment.yaml as the image URL"
  value       = aws_ecr_repository.gds_app.repository_url
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.gds_cluster.endpoint
}

output "lb_controller_role_arn" {
  description = "Paste into the Helm install command for the LB Controller"
  value       = aws_iam_role.lb_controller_role.arn
}

output "configure_kubectl" {
  description = "Run this after apply to connect kubectl to the cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}"
}

output "ecr_push_commands" {
  description = "Commands to build and push the Flask image to ECR"
  value       = <<-EOT
    aws ecr get-login-password --region ${var.aws_region} \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.gds_app.repository_url}

    docker build -t gds-app ./app
    docker tag  gds-app:latest ${aws_ecr_repository.gds_app.repository_url}:latest
    docker push ${aws_ecr_repository.gds_app.repository_url}:latest
  EOT
}


output "vpc_id" {
  description = "VPC ID — needed for the LB Controller Helm install"
  value       = aws_vpc.gds_vpc.id
}