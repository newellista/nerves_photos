FROM --platform=linux/amd64 elixir:1.19-otp-27

ARG FWUP_VERSION=1.10.2

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    squashfs-tools \
    libmnl-dev \
    libnl-genl-3-dev \
    libncurses6 \
    libncurses-dev \
    openssh-client \
    curl \
    ca-certificates \
    && curl -fsSL "https://github.com/fhunleth/fwup/releases/download/v${FWUP_VERSION}/fwup_${FWUP_VERSION}_amd64.deb" -o /tmp/fwup.deb \
    && apt-get install -y /tmp/fwup.deb \
    && rm -rf /tmp/fwup.deb /var/lib/apt/lists/*

RUN mix archive.install hex nerves_bootstrap --force

WORKDIR /app
