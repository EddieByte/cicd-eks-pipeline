# Jenkins Master Setup

## Instance Details
- Type: t3.micro (free-tier)
- OS: Ubuntu 22.04
- Region: us-east-1
- Hostname: Jenkins-Master

## Issues Encountered
- Jenkins repo GPG key changed — had to use jenkins.io-2026.key
  instead of jenkins.io-2023.key
- Jenkins 2.558 requires Java 21 minimum — Java 17 caused startup failure
  Diagnosed via: sudo journalctl -u jenkins.service --no-pager -n 50

## Resolution
- Installed openjdk-21-jdk and set as default with update-alternatives
- Jenkins started successfully after Java upgrade