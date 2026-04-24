#!/bin/bash
set -euo pipefail

hostnamectl set-hostname Jenkins-Master

apt-get update -y
apt-get install -y python3 python3-pip awscli
