#!/bin/bash
set -euo pipefail

hostnamectl set-hostname SonarQube

apt-get update -y
apt-get install -y python3 python3-pip awscli
