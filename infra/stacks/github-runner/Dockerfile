FROM ubuntu:22.04

ARG RUNNER_VERSION=2.336.0

RUN apt-get update \
  && apt-get install -y --no-install-recommends curl tar jq sudo git ca-certificates libicu-dev gh make gnupg \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
  && chmod a+r /etc/apt/keyrings/docker.asc \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable" > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -m githubrunner
WORKDIR /home/githubrunner/actions-runner

# Download the runner at build time, not at container start. Both tiers share
# this image, so the ~215 MB tarball is fetched once instead of once per
# container — with 10 runners that is the difference between 215 MB and 2.1 GB
# of downloads, and it keeps first-boot registration inside the health gate's
# timeout on a modest uplink.
RUN curl -fL -o /tmp/actions-runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
  && tar xzf /tmp/actions-runner.tar.gz -C /home/githubrunner/actions-runner \
  && rm /tmp/actions-runner.tar.gz

COPY start.sh .
RUN chmod +x start.sh
RUN chown -R githubrunner:githubrunner /home/githubrunner/actions-runner

USER githubrunner

ENTRYPOINT ["./start.sh"]
