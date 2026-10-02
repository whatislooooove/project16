FROM debian:bookworm-slim

ARG REHLDS_VERSION=3.13.0.788
ARG METAMOD_VERSION=1.3.0.149
ARG REGAMEDLL_VERSION=5.26.0.668
ARG REAPI_VERSION=5.24.0.300
ARG REUNION_VERSION=0.2.0.25
ARG YAPB_VERSION=4.4.957
ARG AMXX_BRANCH=1.10

ENV HLDS_DIR=/opt/hlds \
    REHLDS_URL=https://github.com/rehlds/ReHLDS/releases/download/${REHLDS_VERSION}/rehlds-bin-${REHLDS_VERSION}.zip \
    METAMOD_URL=https://github.com/rehlds/Metamod-R/releases/download/${METAMOD_VERSION}/metamod-bin-${METAMOD_VERSION}.zip \
    REGAMEDLL_URL=https://github.com/rehlds/ReGameDLL_CS/releases/download/${REGAMEDLL_VERSION}/regamedll-bin-${REGAMEDLL_VERSION}.zip \
    REAPI_URL=https://github.com/rehlds/ReAPI/releases/download/${REAPI_VERSION}/reapi-bin-${REAPI_VERSION}.zip \
    REUNION_URL=https://github.com/rehlds/ReUnion/releases/download/${REUNION_VERSION}/reunion-${REUNION_VERSION}.zip \
    YAPB_URL=https://github.com/yapb/yapb/releases/download/${YAPB_VERSION}/yapb-${YAPB_VERSION}-linux.tar.xz \
    AMXX_BASE_URL=https://www.amxmodx.org/amxxdrop/${AMXX_BRANCH}/amxmodx-latest-base-linux.tar.gz \
    AMXX_CSTRIKE_URL=https://www.amxmodx.org/amxxdrop/${AMXX_BRANCH}/amxmodx-latest-cstrike-linux.tar.gz \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    CPU_MHZ=2300

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        lib32gcc-s1 \
        libstdc++6:i386 \
        locales \
        rsync \
        unzip \
        xz-utils \
    && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -r steam && useradd -r -g steam -m -d /opt/steam steam \
    && mkdir -p /opt/steamcmd /opt/hlds /custom \
    && chown -R steam:steam /opt/steam /opt/steamcmd /opt/hlds /custom

USER steam
WORKDIR /opt/steamcmd

RUN curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz \
    && mkdir -p /opt/steam/.steam \
    && ln -s /opt/steamcmd/linux32 /opt/steam/.steam/sdk32

COPY --chown=steam:steam scripts/hlds.install /opt/steamcmd/hlds.install

# SteamCMD app 90 often needs a second pass before cstrike files appear.
RUN ./steamcmd.sh +runscript /opt/steamcmd/hlds.install \
    && ./steamcmd.sh +runscript /opt/steamcmd/hlds.install \
    && test -x /opt/hlds/hlds_run \
    && ln -sf /opt/steamcmd/linux32/steamclient.so /opt/hlds/steamclient.so

COPY --chown=steam:steam scripts/install-mods.sh /opt/steamcmd/install-mods.sh
RUN chmod +x /opt/steamcmd/install-mods.sh && /opt/steamcmd/install-mods.sh

# Project overlay: configs, AMXX plugins, YaPB graphs — Windows binaries stay out via .dockerignore
COPY --chown=steam:steam ../server/cstrike /opt/hlds/cstrike

USER root
COPY scripts/entrypoint.sh /usr/local/bin/cs16-entrypoint
RUN chmod +x /usr/local/bin/cs16-entrypoint /opt/steamcmd/install-mods.sh \
    && chown -R steam:steam /opt/hlds \
    && sed -i 's|^gamedll_linux.*|gamedll_linux "addons/metamod/metamod_i386.so"|' /opt/hlds/cstrike/liblist.gam

USER steam
WORKDIR /opt/hlds

EXPOSE 27015/tcp 27015/udp

ENTRYPOINT ["cs16-entrypoint"]
