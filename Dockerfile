FROM eclipse-temurin:21-jdk

USER root

ARG user=jenkins
ARG group=jenkins
ARG uid=10000
ARG gid=10000
ARG http_port=8080
ARG agent_port=50000
ARG JENKINS_HOME=/var/jenkins_home
ARG TINI_VERSION=v0.19.0
ARG HELM_VERSION=v3.9.0
ARG JENKINS_VERSION=2.526
ARG JENKINS_SHA=e1bd436678abb631d5d30c719240c2753369eeb925ade3a35faf5dfbdecb27b0
ARG JENKINS_URL=https://repo.jenkins-ci.org/public/org/jenkins-ci/main/jenkins-war/${JENKINS_VERSION}/jenkins-war-${JENKINS_VERSION}.war
ARG TERRAFORM_VERSION=1.2.2

ENV JENKINS_HOME=${JENKINS_HOME} \
    JENKINS_SLAVE_AGENT_PORT=${agent_port} \
    TERRAFORM_VERSION=${TERRAFORM_VERSION}

RUN apt-get update && \
    apt-get install --no-install-recommends -y \
        apt-utils bash-completion build-essential vim ca-certificates curl \
        debconf-utils file git gnupg apache2-utils \
        libffi-dev libxslt1-dev libssl-dev libxml2-dev libkrb5-dev \
        openssl python3 python3-dev python3-pip python3-setuptools \
        sudo uuid-dev unzip wget && \
    rm -rf /var/lib/apt/lists/*

COPY bash_profile /var/jenkins_home/.bash_profile

# Terraform (with checksum verification)
RUN wget -q https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS && \
    grep "terraform_${TERRAFORM_VERSION}_linux_amd64.zip" terraform_${TERRAFORM_VERSION}_SHA256SUMS > terraform_SHA256SUMS_linux_amd64 && \
    wget -q https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
    sha256sum -c terraform_SHA256SUMS_linux_amd64 && \
    unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip -d /usr/bin && \
    rm -f terraform_${TERRAFORM_VERSION}_linux_amd64.zip terraform_${TERRAFORM_VERSION}_SHA256SUMS terraform_SHA256SUMS_linux_amd64

# kubectl (with checksum verification)
RUN KUBECTL_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt) && \
    curl -fsSL -o /usr/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl" && \
    curl -fsSL -o /tmp/kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl.sha256" && \
    echo "$(cat /tmp/kubectl.sha256)  /usr/bin/kubectl" | sha256sum -c - && \
    chmod +x /usr/bin/kubectl && rm -f /tmp/kubectl.sha256

# Helm (with checksum verification)
RUN wget -q https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz && \
    wget -q https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum && \
    sha256sum -c helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum && \
    tar -zxf helm-${HELM_VERSION}-linux-amd64.tar.gz && \
    mv linux-amd64/helm /usr/bin/helm && \
    chmod +x /usr/bin/helm && \
    rm -rf linux-amd64 helm-${HELM_VERSION}-linux-amd64.tar.gz helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum

# Jenkins user/group (idempotent)
RUN mkdir -p "${JENKINS_HOME}" && \
    (getent group ${gid} || groupadd -g ${gid} ${group}) && \
    (id -u ${user} >/dev/null 2>&1 || useradd -d "${JENKINS_HOME}" -u ${uid} -g ${gid} -m -s /bin/bash ${user}) && \
    chown -R ${uid}:${gid} "${JENKINS_HOME}" && \
    echo "jenkins ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/jenkins

VOLUME ${JENKINS_HOME}

RUN mkdir -p /usr/share/jenkins/ref/init.groovy.d

# tini (verified)
COPY tini_pub.gpg ${JENKINS_HOME}/tini_pub.gpg
RUN curl -fsSL https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-$(dpkg --print-architecture) -o /sbin/tini && \
    curl -fsSL https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-$(dpkg --print-architecture).asc -o /sbin/tini.asc && \
    gpg --no-tty --import ${JENKINS_HOME}/tini_pub.gpg && \
    gpg --verify /sbin/tini.asc /sbin/tini && \
    rm -rf /sbin/tini.asc /root/.gnupg && \
    chmod +x /sbin/tini

COPY init.groovy /usr/share/jenkins/ref/init.groovy.d/tcp-slave-agent-port.groovy

# Jenkins WAR
ENV JENKINS_VERSION=${JENKINS_VERSION} \
    JENKINS_UC=https://updates.jenkins.io \
    JENKINS_UC_EXPERIMENTAL=https://updates.jenkins.io/experimental \
    JENKINS_INCREMENTALS_REPO_MIRROR=https://repo.jenkins-ci.org/incrementals

RUN curl -fsSL ${JENKINS_URL} -o /usr/share/jenkins/jenkins.war && \
    echo "${JENKINS_SHA}  /usr/share/jenkins/jenkins.war" | sha256sum -c - && \
    chown -R ${user} /usr/share/jenkins/ref

# Ports
EXPOSE ${http_port}
EXPOSE ${agent_port}

ENV COPY_REFERENCE_FILE_LOG=${JENKINS_HOME}/copy_reference_file.log

COPY jenkins-support /usr/local/bin/jenkins-support
COPY jenkins.sh /usr/local/bin/jenkins.sh
# Removed unused tini shim; using verified /sbin/tini only
COPY install-plugins.sh /usr/local/bin/install-plugins.sh

RUN chown -R ${user} /usr/local/bin/jenkins.sh && \
    chmod +x /usr/local/bin/jenkins.sh /usr/local/bin/jenkins-support \
             /usr/local/bin/install-plugins.sh

USER ${user}

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/jenkins.sh"]

# Basic healthcheck to ensure Jenkins is responsive
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD curl -fsS http://localhost:${http_port}/login > /dev/null || exit 1
