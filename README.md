# Absolute Palworld Server

A production-ready Docker container for hosting Palworld dedicated servers with automatic updates, backups, and comprehensive configuration options.

## Features

- **Easy Setup**: Get a Palworld server running with a single `docker compose up -d` command
- **Automatic Updates**: Server files are automatically updated on container start
- **Scheduled Backups**: Configurable automatic backups with retention policies
- **Full Configuration**: All server settings configurable via environment variables
- **Health Monitoring**: Built-in health checks for container orchestration
- **Log Filtering**: Clean, readable logs with configurable filtering
- **Graceful Shutdown**: Proper world saving on container stop

## Quick Start

### Prerequisites

- Docker and Docker Compose installed
- At least 16GB RAM available
- 20GB+ disk space for server files

### 1. Create a docker-compose.yml

```yaml
services:
  palworld:
    image: ghcr.io/fireaimready/absolute-palworld-server:latest
    container_name: palworld-server
    environment:
      - SERVER_NAME=My Palworld Server
      - SERVER_PASSWORD=mypassword
      - ADMIN_PASSWORD=adminpass
      - MAX_PLAYERS=32
    ports:
      - "8211:8211/udp"
      - "27015:27015/udp"
    volumes:
      - palworld-config:/config
      - palworld-server:/opt/palworld/server
    restart: unless-stopped

volumes:
  palworld-config:
  palworld-server:
```

### 2. Start the Server

```bash
docker compose up -d
```

### 3. View Logs

```bash
docker compose logs -f
```

### 4. Stop the Server

```bash
docker compose down
```

## Configuration

All configuration is done through environment variables in `docker-compose.yml`.

### Server Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_NAME` | My Palworld Server | Server name in browser |
| `SERVER_PORT` | 8211 | Game port (UDP) |
| `SERVER_DESCRIPTION` | (empty) | Server description |
| `SERVER_PASSWORD` | (empty) | Server password |
| `ADMIN_PASSWORD` | (empty) | Admin/RCON password |
| `SERVER_PUBLIC` | true | List in server browser |
| `MAX_PLAYERS` | 32 | Maximum players |

### Game Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `DIFFICULTY` | None | None, Normal, Difficult |
| `DAY_TIME_SPEED_RATE` | 1.0 | Day time multiplier |
| `NIGHT_TIME_SPEED_RATE` | 1.0 | Night time multiplier |
| `EXP_RATE` | 1.0 | Experience multiplier |
| `PAL_CAPTURE_RATE` | 1.0 | Capture rate multiplier |
| `PAL_SPAWN_NUM_RATE` | 1.0 | Pal spawn rate |
| `DEATH_PENALTY` | All | None, Item, ItemAndEquipment, All |
| `IS_PVP` | false | Enable PvP |
| `ENABLE_FRIENDLY_FIRE` | false | Enable friendly fire |
| `WORK_SPEED_RATE` | 1.0 | Work speed multiplier |

### Update Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `UPDATE_ON_START` | true | Update server on start |
| `UPDATE_TIMEOUT` | 900 | Update timeout (seconds) |
| `UPDATE_CRON` | (empty) | Cron schedule for updates |
| `UPDATE_IF_IDLE` | true | Only update when empty |

### Backup Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUPS_ENABLED` | true | Enable backups |
| `BACKUPS_CRON` | 0 * * * * | Backup schedule (hourly) |
| `BACKUPS_DIRECTORY` | /config/backups | Backup location |
| `BACKUPS_MAX_AGE` | 3 | Delete backups older than X days |
| `BACKUPS_MAX_COUNT` | 0 | Max backups (0 = unlimited) |
| `BACKUPS_ZIP` | true | Compress backups |

### RCON Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `RCON_ENABLED` | false | Enable RCON |
| `RCON_PORT` | 25575 | RCON port (TCP) |

### Permission Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | 1000 | User ID for file ownership |
| `PGID` | 1000 | Group ID for file ownership |
| `TZ` | Etc/UTC | Container timezone |

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8211 | UDP | Game traffic |
| 27015 | UDP | Steam server queries |
| 25575 | TCP | RCON (if enabled) |

## Volumes

| Path | Description |
|------|-------------|
| `/config` | Save files, backups, settings |
| `/opt/palworld/server` | Server files (can be cached) |

## Manual Backup

```bash
docker exec palworld-server /opt/palworld/scripts/palworld-backup --force
```

## Manual Update

```bash
docker exec palworld-server /opt/palworld/scripts/palworld-updater --force
```

## Building from Source

### Clone the Repository

```bash
git clone https://github.com/fireaimready/absolute-palworld-server.git
cd absolute-palworld-server
```

### Build and Run

```bash
docker compose up -d --build
```

### Run E2E Tests

```bash
./tests/run_e2e.sh
```

## Architecture

```
absolute-palworld-server/
├── Dockerfile              # Multi-stage build
├── docker-compose.yml      # Production configuration
├── docker-compose.test.yml # Testing configuration
├── config/
│   └── supervisord.conf    # Process management
├── scripts/
│   ├── bootstrap           # Container initialization
│   ├── common              # Shared functions
│   ├── palworld-server     # Server start/stop
│   ├── palworld-updater    # SteamCMD updates
│   ├── palworld-backup     # Backup management
│   ├── palworld-logfilter  # Log filtering
│   └── healthcheck         # Health monitoring
├── tests/
│   ├── run_e2e.sh          # Test runner
│   ├── test_helpers.sh     # Test utilities
│   └── e2e/                # Individual tests
└── .github/
    └── workflows/
        └── e2e.yml         # CI/CD pipeline
```

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please open an issue or pull request.

## Acknowledgments

- [Palworld](https://www.pocketpair.jp/palworld) by Pocket Pair
- Inspired by [absolute-valheim-server](https://github.com/fireaimready/absolute-valheim-server)
