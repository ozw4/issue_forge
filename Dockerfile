# syntax=docker/dockerfile:1
# check=error=true

FROM nvcr.io/nvidia/pytorch:24.12-py3 AS develop

ARG USERNAME=dcuser
ARG UID=1000
ARG GID=1000
ARG NODE_MAJOR=22
ARG ftp_proxy
ARG http_proxy
ARG https_proxy
ARG no_proxy
ARG FTP_PROXY
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG APT_HTTP_PROXY=http://172.21.11.152:13142
ARG APT_MIRROR=http://ftp.udx.icscoe.jp/Linux/ubuntu/
ARG PIP_INDEX_URL=http://172.21.11.152:13141/root/pypi/+simple/
ARG PIP_TRUSTED_HOST=172.21.11.152

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/bin:/home/${USERNAME}/.local/bin:/home/${USERNAME}/.local/pipx/bin:${PATH} \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    ftp_proxy=${ftp_proxy} \
    http_proxy=${http_proxy} \
    https_proxy=${https_proxy} \
    no_proxy=${no_proxy} \
    FTP_PROXY=${FTP_PROXY} \
    HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY}

RUN <<'SHELL' bash -eux
sed -i.bak -r "s@http://(jp\.)?archive\.ubuntu\.com/ubuntu/?@${APT_MIRROR}@g" /etc/apt/sources.list.d/ubuntu.sources

cat > /etc/apt/apt.conf.d/05proxy <<APTPROXY
Acquire::http { Proxy "${APT_HTTP_PROXY}"; }
Acquire::https { Proxy "${APT_HTTP_PROXY}"; }
APTPROXY

addgroup --gid "${GID}" "${USERNAME}"
adduser --disabled-password --gecos '' --shell '/bin/bash' --uid "${UID}" --gid "${GID}" "${USERNAME}"

echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' | debconf-set-selections

mkdir -p /home/${USERNAME}/.config/pip
cat > /home/${USERNAME}/.config/pip/pip.conf <<PIPCONF
[global]
index-url = ${PIP_INDEX_URL}
trusted-host = ${PIP_TRUSTED_HOST}
disable-pip-version-check = true
PIPCONF

chown -R "${UID}:${GID}" /home/${USERNAME}/.config
SHELL

RUN --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        fontconfig \
        git \
        git-lfs \
        gnupg \
        jq \
        less \
        ninja-build \
        openssh-client \
        procps \
        ripgrep \
        shellcheck \
        ttf-mscorefonts-installer \
        unzip \
    && git lfs install --system \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        nodejs \
        gh \
    && npm install -g @openai/codex \
    && npm cache clean --force \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && fc-cache -fv

USER ${USERNAME}

RUN --mount=type=bind,source=.devcontainer/requirements-dev.txt,target=/tmp/requirements-dev.txt \
    python3 -m pip install --user --no-dependencies torchaudio \
    && python3 -m pip install --user pipx \
    && python3 -m pip install --user -r /tmp/requirements-dev.txt \
    && python3 -m pipx ensurepath

COPY --chown=${UID}:${GID} ruff.toml /home/${USERNAME}/ruff.toml

WORKDIR /workspace

RUN python3 -m pip show kaggle kagglehub >/dev/null \
    && command -v kaggle >/dev/null \
    && kaggle --version \
    && command -v gh >/dev/null \
    && gh --version >/dev/null \
    && command -v codex >/dev/null \
    && codex --help >/dev/null

CMD ["/bin/bash"]
