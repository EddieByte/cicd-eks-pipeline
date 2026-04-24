#!/bin/bash
set -euo pipefail

hostnamectl set-hostname Ansible-Control-Node

apt-get update -y
apt-get install -y python3 python3-pip git awscli software-properties-common

# Install Ansible
add-apt-repository --yes --update ppa:ansible/ansible
apt-get install -y ansible

# Get IMDSv2 token
TOKEN=$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')

REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

# Pull SSH private key from SSM and place it for Ansible to use
mkdir -p /home/ubuntu/.ssh
aws ssm get-parameter \
  --name "${ssm_ssh_key_path}" \
  --with-decryption \
  --query Parameter.Value \
  --output text \
  --region "$REGION" > /home/ubuntu/.ssh/${key_name}.pem

chmod 600 /home/ubuntu/.ssh/${key_name}.pem
chown ubuntu:ubuntu /home/ubuntu/.ssh/${key_name}.pem

# Clone the repo so playbooks are ready
if [ -d "/home/ubuntu/cicd-eks-pipeline/.git" ]; then
  git -C /home/ubuntu/cicd-eks-pipeline pull
else
  rm -rf /home/ubuntu/cicd-eks-pipeline
  git clone ${github_repo} /home/ubuntu/cicd-eks-pipeline
fi
chown -R ubuntu:ubuntu /home/ubuntu/cicd-eks-pipeline

# Install required Ansible collections
sudo -u ubuntu ansible-galaxy collection install -r /home/ubuntu/cicd-eks-pipeline/ansible/requirements.yml
