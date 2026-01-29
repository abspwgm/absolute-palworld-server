# =============================================================================
# Absolute Palworld Server - Dockerfile
# Multi-stage build for containerized Palworld dedicated server
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Base image with dependencies
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS base

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    lib32gcc-s1 \
    lib32stdc++6 \
    ca-certificates \
    curl \
    wget \
    procps \
    jq \
    zip \
    unzip \
    cron \
    tini \
    supervisor \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Stage 2: SteamCMD installation
# -----------------------------------------------------------------------------
FROM base AS steamcmd

# Create steamcmd directory and install
RUN mkdir -p /opt/steamcmd \
    && cd /opt/steamcmd \
    && curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar zxvf - \
    && chmod +x /opt/steamcmd/steamcmd.sh \
    && /opt/steamcmd/steamcmd.sh +quit || true

# -----------------------------------------------------------------------------
# Stage 3: Final runtime image
# -----------------------------------------------------------------------------
FROM base AS runtime

# Copy steamcmd from builder stage
COPY --from=steamcmd /opt/steamcmd /opt/steamcmd
COPY --from=steamcmd /root/Steam /root/Steam

# Create palworld user for running the server
RUN groupadd -g 1000 palworld \
    && useradd -u 1000 -g palworld -m -s /bin/bash palworld

# Create required directories
RUN mkdir -p /opt/palworld/server \
    && mkdir -p /config/settings \
    && mkdir -p /config/backups \
    && mkdir -p /var/log/palworld \
    && mkdir -p /var/run/palworld \
    && chown -R palworld:palworld /opt/palworld \
    && chown -R palworld:palworld /config \
    && chown -R palworld:palworld /var/log/palworld \
    && chown -R palworld:palworld /var/run/palworld

# Copy scripts
COPY scripts/ /opt/palworld/scripts/

# Fix line endings (in case of Windows CRLF) and set permissions
RUN find /opt/palworld/scripts -type f -exec sed -i 's/\r$//' {} \; \
    && chmod +x /opt/palworld/scripts/*

# Copy supervisor configuration
COPY config/supervisord.conf /etc/supervisor/conf.d/palworld.conf
RUN sed -i 's/\r$//' /etc/supervisor/conf.d/palworld.conf

# Environment variables with defaults
ENV SERVER_NAME="My Palworld Server" \
    SERVER_PORT=8211 \
    SERVER_DESCRIPTION="" \
    SERVER_PASSWORD="" \
    ADMIN_PASSWORD="" \
    SERVER_PUBLIC=true \
    SERVER_ARGS="" \
    # Game settings
    MAX_PLAYERS=32 \
    DIFFICULTY=None \
    DAY_TIME_SPEED_RATE=1.0 \
    NIGHT_TIME_SPEED_RATE=1.0 \
    EXP_RATE=1.0 \
    PAL_CAPTURE_RATE=1.0 \
    PAL_SPAWN_NUM_RATE=1.0 \
    PAL_DAMAGE_RATE_ATTACK=1.0 \
    PAL_DAMAGE_RATE_DEFENSE=1.0 \
    PLAYER_DAMAGE_RATE_ATTACK=1.0 \
    PLAYER_DAMAGE_RATE_DEFENSE=1.0 \
    PLAYER_STOMACH_DECREASE_RATE=1.0 \
    PLAYER_STAMINA_DECREASE_RATE=1.0 \
    PLAYER_AUTO_HP_REGEN_RATE=1.0 \
    PLAYER_AUTO_HP_REGEN_RATE_IN_SLEEP=1.0 \
    BUILD_OBJECT_DAMAGE_RATE=1.0 \
    BUILD_OBJECT_DETERIORATION_DAMAGE_RATE=1.0 \
    COLLECTION_DROP_RATE=1.0 \
    COLLECTION_OBJECT_HP_RATE=1.0 \
    COLLECTION_OBJECT_RESPAWN_SPEED_RATE=1.0 \
    ENEMY_DROP_ITEM_RATE=1.0 \
    DEATH_PENALTY=All \
    ENABLE_PLAYER_TO_PLAYER_DAMAGE=false \
    ENABLE_FRIENDLY_FIRE=false \
    ENABLE_INVADER_ENEMY=true \
    ACTIVE_UNKO=false \
    ENABLE_AIM_ASSIST_PAD=true \
    ENABLE_AIM_ASSIST_KEYBOARD=false \
    DROP_ITEM_MAX_NUM=3000 \
    DROP_ITEM_MAX_NUM_UNKO=100 \
    BASE_CAMP_MAX_NUM=128 \
    BASE_CAMP_WORKER_MAX_NUM=15 \
    DROP_ITEM_ALIVE_MAX_HOURS=1.0 \
    AUTO_RESET_GUILD_NO_ONLINE_PLAYERS=false \
    AUTO_RESET_GUILD_TIME_NO_ONLINE_PLAYERS=72.0 \
    GUILD_PLAYER_MAX_NUM=20 \
    PAL_EGG_DEFAULT_HATCHING_TIME=72.0 \
    WORK_SPEED_RATE=1.0 \
    IS_MULTIPLAY=false \
    IS_PVP=false \
    CAN_PICKUP_OTHER_GUILD_DEATH_PENALTY_DROP=false \
    ENABLE_NON_LOGIN_PENALTY=true \
    ENABLE_FAST_TRAVEL=true \
    IS_START_LOCATION_SELECT_BY_MAP=true \
    EXIST_PLAYER_AFTER_LOGOUT=false \
    ENABLE_DEFENSE_OTHER_GUILD_PLAYER=false \
    COOP_PLAYER_MAX_NUM=4 \
    SERVER_PLAYER_MAX_NUM=32 \
    # RCON settings
    RCON_ENABLED=false \
    RCON_PORT=25575 \
    # Update settings
    UPDATE_ON_START=true \
    UPDATE_TIMEOUT=900 \
    UPDATE_CRON="" \
    UPDATE_IF_IDLE=true \
    STEAMCMD_ARGS="validate" \
    # Backup settings
    BACKUPS_ENABLED=true \
    BACKUPS_CRON="0 * * * *" \
    BACKUPS_DIRECTORY=/config/backups \
    BACKUPS_MAX_AGE=3 \
    BACKUPS_MAX_COUNT=0 \
    BACKUPS_ZIP=true \
    BACKUPS_IF_IDLE=false \
    # Permission settings
    PUID=1000 \
    PGID=1000 \
    PERMISSIONS_UMASK=022 \
    # System
    TZ=Etc/UTC \
    # Log filtering
    LOG_FILTER_EMPTY=true \
    LOG_FILTER_UTF8=true \
    LOG_FILTER_CONTAINS=""

# Expose Palworld ports
# 8211/udp - Game traffic
# 27015/udp - Steam server queries
# 25575/tcp - RCON (optional)
EXPOSE 8211/udp 27015/udp 25575/tcp

# Volume mounts
# /config - Persistent data (saves, backups, settings)
# /opt/palworld/server - Server files (can be cached)
VOLUME ["/config", "/opt/palworld/server"]

# Health check - verify server is responding
HEALTHCHECK --interval=60s --timeout=10s --start-period=300s --retries=3 \
    CMD /opt/palworld/scripts/healthcheck || exit 1

# Use tini as init system for proper signal handling
ENTRYPOINT ["/usr/bin/tini", "--"]

# Start bootstrap script
CMD ["/opt/palworld/scripts/bootstrap"]
