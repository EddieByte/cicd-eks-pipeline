#!/bin/bash
set -euo pipefail

hostnamectl set-hostname Ansible-Control-Node

apt-get update -y
apt-get install -y python3 python3-pip git software-properties-common

# Install awscli via pip to avoid version conflicts with boto3
pip3 install --upgrade awscli boto3 botocore

# Install Ansible
add-apt-repository --yes --update ppa:ansible/ansible
apt-get install -y ansible

# Verify boto3 is accessible to Ansible's Python
python3 -c "import boto3" || { echo 'boto3 import failed'; exit 1; }

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
