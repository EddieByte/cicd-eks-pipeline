# Use the same Java generation that the cloud Jenkins configuration expects.
FROM jenkins/jenkins:lts-jdk21

# Copy the repository's shared plugin manifest into the image.
COPY ansible/roles/jenkins_master/files/plugins.txt /usr/share/jenkins/ref/plugins.txt

# Install plugins during image build so startup tests the real dependency set.
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Tell Jenkins to load the local, non-EC2 JCasC configuration at startup.
ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc_configs/jenkins.yaml

# Copy the local JCasC file after plugin installation.
COPY docker/jenkins-local/jenkins.yaml /usr/share/jenkins/ref/casc_configs/jenkins.yaml
