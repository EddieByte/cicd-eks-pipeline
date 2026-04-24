# Jenkins Master Setup

## Instance Details
- Type: t3.micro (free-tier)
- OS: Ubuntu 22.04
- Region: us-east-1
- Hostname: Jenkins-Master

### Issue 1 — Jenkins repo GPG key outdated
- Error: NO_PUBKEY 7198F4B714ABFC68
- Fix: Switched from jenkins.io-2023.key to jenkins.io-2026.key
- Working repo: https://pkg.jenkins.io/debian (not debian-stable)
- Commands used:
  sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
    https://pkg.jenkins.io/debian/jenkins.io-2026.key
  echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] \
    https://pkg.jenkins.io/debian binary/" | sudo tee \
    /etc/apt/sources.list.d/jenkins.list > /dev/null
    
## Resolution
- Installed openjdk-21-jdk and set as default with update-alternatives
- Jenkins started successfully after Java upgrade


### Issue 2 — Jenkins failed to start after install
- Error: Start request repeated too quickly / exit-code failure
- Root cause: Pending kernel upgrade blocked service start
- Fix: sudo reboot — Jenkins started cleanly after reboot

### Issue 3 — Jenkins requires Java 21 minimum
- Error: Running with Java 17, which is older than minimum required (Java 21)
- Supported versions: [21, 25]
- Fix: sudo apt install openjdk-21-jdk -y
        sudo update-alternatives --set java \
          /usr/lib/jvm/java-21-openjdk-amd64/bin/java
- Diagnosed via: sudo journalctl -u jenkins.service --no-pager -n 50

## Jenkins Configuration
- Admin user created
- Suggested plugins installed
- URL: http://<jenkins-master-public-ip>:8080

## Plugins Installed
- Eclipse Temurin Installer
- SonarQube Scanner
- SonarQuality Gates
- NodeJS
- Docker
- Docker Pipeline
- CloudBees Docker Build and Publish
- OWASP Dependency-Check

## Global Tools Configured
- JDK: Java21 (Adoptium, auto-install)
- Maven: Maven3 (3.9.x, auto-install)

## Credentials Added
- ID: github | Type: Username + PAT | GitHub access

## Agent Node
- Connected via SSH
- Label: Jenkins-Agent
- Verified online in Jenkins UI

## First Pipeline Job
- Job name: registerapp-pipeline
- Repo: https://github.com/EddieByte/registerapp-html
- Result: SUCCESS (Build #2)
- Stages passing: Cleanup → Checkout → Build → Test

## Pipeline Fix — pom.xml Java version
- Error: Source option 7 is no longer supported. Use 8 or later
- Root cause: pom.xml had <source>1.7</source> <target>1.7</target>
- Fix: Updated both values to 11 in root pom.xml
- Commit: fix: update Maven compiler source and target from 1.7 to
  11 for Java 21 compatibility

## Key Lessons Learned
- Jenkins 2.558+ requires Java 21 — Java 17 is no longer supported
- Always diagnose service failures with:
  sudo journalctl -u jenkins.service --no-pager -n 50
- Jenkins repo keys change — check jenkins.io for current key URL
- Old tutorial pom.xml files often target Java 7 — update to 11+
- Never edit XML in GitHub web editor — use VS Code locally to
  avoid breaking tag nesting
- Reboot after kernel upgrade warnings before starting services