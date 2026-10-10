FROM ubuntu:24.04 AS build
ENV DEBIAN_FRONTEND=noninteractive \
    POETRY_VIRTUALENVS_IN_PROJECT=true \
    PATH=/usr/local/go/bin:/root/.foundry/bin:/root/.local/bin:$PATH
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git jq openssl python3 python3-dev python3-venv pipx build-essential xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://nodejs.org/dist/v20.18.1/node-v20.18.1-linux-x64.tar.xz | tar -C /usr/local --strip-components=1 -xJ
RUN curl -fsSL https://go.dev/dl/go1.24.6.linux-amd64.tar.gz | tar -C /usr/local -xz
ARG FOUNDRY_VERSION=v1.8.5
RUN curl -fsSL https://foundry.paradigm.xyz | bash && foundryup --install ${FOUNDRY_VERSION}
RUN pipx install poetry

ARG BSC_VERSION=v1.7.8
RUN curl -fsSL https://github.com/bnb-chain/bsc/releases/download/${BSC_VERSION}/geth_linux -o /usr/local/bin/geth \
    && chmod +x /usr/local/bin/geth

ARG NODE_DEPLOY_COMMIT=292c25955807227b8f43e01bdc4ae57b3b884c0e
RUN git clone https://github.com/bnb-chain/node-deploy /node-deploy \
    && cd /node-deploy && git checkout -q ${NODE_DEPLOY_COMMIT} \
    && git submodule update --init --recursive genesis \
    && . ./.env && cd genesis && git reset -q --hard "$GENESIS_COMMIT"
WORKDIR /node-deploy/genesis
RUN poetry install --no-root && npm install --omit=dev --no-audit --no-fund
RUN rm -rf lib/forge-std \
    && git clone -q --depth 1 --branch v1.7.3 https://github.com/foundry-rs/forge-std lib/forge-std \
    && rm -rf lib/forge-std/lib/ds-test \
    && git clone -q --depth 1 https://github.com/dapphub/ds-test lib/forge-std/lib/ds-test \
    && cp -r contracts /node-deploy/contracts.pristine \
    && rm -rf .git test
RUN cd /node-deploy/create-validator && go build -o /usr/local/bin/create-validator .

COPY nadcab-dpos-genesis.sh nadcab-dpos-node.sh /usr/local/bin/
# Smoke run: proves the toolchain works and caches both solc versions in the image.
RUN CHAIN_ID=7714000 MINT=0x0000000000000000000000000000000000000001 SUPPLY=1000000 OUT=/tmp/smoke \
      nadcab-dpos-genesis.sh && rm -rf /tmp/smoke

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates jq openssl python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/node /usr/local/bin/geth /usr/local/bin/create-validator \
     /usr/local/bin/nadcab-dpos-genesis.sh /usr/local/bin/nadcab-dpos-node.sh /usr/local/bin/
COPY --from=build /root/.foundry/bin/forge /usr/local/bin/forge
COPY --from=build /root/.local/share/svm /root/.local/share/svm
COPY --from=build /node-deploy/contracts.pristine /node-deploy/contracts.pristine
COPY --from=build /node-deploy/genesis /node-deploy/genesis
WORKDIR /node-deploy
