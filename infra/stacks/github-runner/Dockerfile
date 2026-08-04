FROM ubuntu:22.04

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

COPY start.sh .
RUN chmod +x start.sh
RUN chown -R githubrunner:githubrunner /home/githubrunner/actions-runner

USER githubrunner

ENTRYPOINT ["./start.sh"]
