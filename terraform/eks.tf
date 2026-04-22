# ============================================================
# EKS CLUSTER
# ============================================================
resource "aws_eks_cluster" "gds_cluster" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = "1.30"
  
  vpc_config {
    subnet_ids              = [aws_subnet.private_1.id, aws_subnet.private_2.id]
    security_group_ids      = [aws_security_group.node_sg.id]
    endpoint_private_access = true
    endpoint_public_access  = true  # Lock down once you have a bastion/VPN
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
  tags       = { Name = "gds-mission-cluster" }
}

# ============================================================
# EKS NODE GROUP  (runs in private subnets)
# ============================================================
resource "aws_eks_node_group" "gds_nodes" {
  cluster_name    = aws_eks_cluster.gds_cluster.name
  node_group_name = "gds-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [aws_subnet.private_1.id, aws_subnet.private_2.id]

  instance_types = ["t3.small"]  # Use a small instance type for cost efficiency; adjust as needed
  
  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }
 
  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
  ]
  tags = { Name = "gds-node-group" }
}
