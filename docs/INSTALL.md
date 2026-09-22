# Install Palworld server: step by step

This guide takes you from nothing to a running Palworld server your friends can join. You
do not need to have used Docker or a command line before. Plan for about half an hour,
most of it waiting for the game to download.

If you already know Docker, the short version is in the [README](../README.md).

## What you need

| | You need |
|---|---|
| Memory (RAM) | 16 GB or more |
| Free disk space | 20 GB or more |

- A computer that can stay switched on while people play. An old PC or a mini PC is fine
  if it has the memory. It does not need a graphics card or a copy of the game.
- Linux (Ubuntu or Debian recommended) or Windows 10/11.
- A wired network connection if you can. Wi-Fi works but causes lag for everyone.

## Step 1: Install Docker

Docker is a free program that runs the server in a sealed box, so it cannot make a mess
of your computer and is easy to remove.

**On Linux**, open a terminal and run these two commands:

```sh
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

Then log out and back in. Check it worked:

```sh
docker --version
```

You should see something like `Docker version 27.x`.

**On Windows**, install [Docker Desktop](https://www.docker.com/products/docker-desktop/),
accept the prompt to enable WSL 2, and restart when asked. Open Docker Desktop once so it
finishes setting up. Then open **PowerShell** and run `docker --version` as above.

## Step 2: Make a folder for your server

This folder holds your server's settings file. Every command in this guide must be run
from inside it.

```sh
mkdir palworld-server
cd palworld-server
```

You should see no message. The prompt now ends in `palworld-server`.

## Step 3: Create the settings file

Create a file named `docker-compose.yml` in that folder and paste this in. On Linux,
`nano docker-compose.yml` opens a simple editor (paste, then Ctrl+O, Enter, Ctrl+X to
save and quit). On Windows, use Notepad and make sure the name does not end in `.txt`.

```yaml
services:
  palworld:
    image: abspwgm/absolute-palworld-server:latest
    container_name: palworld-server
    environment:
      - SERVER_NAME=My Palworld Server
      - SERVER_PASSWORD=
      - ADMIN_PASSWORD=
      - MAX_PLAYERS=32
      - TZ=Etc/UTC
      - BACKUPS_MAX_COUNT=72
    ports:
      - "8211:8211/udp"
      - "27015:27015/udp"
    volumes:
      - palworld-config:/config
      - palworld-server:/opt/palworld/server
    stop_grace_period: 2m
    restart: unless-stopped

volumes:
  palworld-config:
  palworld-server:
```

Change these lines before you go on. Leave everything else alone for now.

| Line | Change it to |
|---|---|
| `SERVER_NAME=My Palworld Server` | The name you want for your server |
| `SERVER_PASSWORD=` | A password your friends type to join, straight after the `=`. Leave it empty for no password |
| `ADMIN_PASSWORD=` | A different, long password only you know. It unlocks the admin commands |
| `TZ=Etc/UTC` | Your time zone from [this list](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones), for example `TZ=Europe/London`. It sets the times shown in the log and in backup names |

> Spaces at the start of each line matter in this file. Keep them exactly as shown.

Every other setting is listed in the [README](../README.md#configuration).

## Step 4: Start the server

```sh
docker compose up -d
```

You should see the image being pulled, then `Container palworld-server  Started`.

The first start downloads the Palworld server from Steam. It is a large download, so
give it time. Watch it work:

```sh
docker compose logs -f
```

You will see `Starting Palworld server update` while it downloads. The download is
finished and the game is being launched when you see:

```
Starting supervisor
```

Press Ctrl+C to stop watching. That does not stop the server.

Now check the server's health:

```sh
docker compose ps
```

The STATUS column shows `(health: starting)` for the first few minutes and then
`(healthy)`. Once it says `(healthy)` the server is ready to join.

## Step 5: Join from your own network

Do this before involving your router, so you know the server itself works.

1. Find the server computer's address: `hostname -I` on Linux, `ipconfig` on Windows
   (look for **IPv4 Address**). It looks like `192.168.1.50`.
2. On the computer you play on, start Palworld and choose **Join Multiplayer Game**.
3. In the box at the bottom of the screen, type the server's address followed by `:8211`,
   for example `192.168.1.50:8211`.
4. If you set a `SERVER_PASSWORD`, tick the password box next to it.
5. Connect, and type the password when the game asks for it. You should load into the
   world.

## Step 6: Let friends join from the internet

Friends outside your home cannot connect until your router forwards the game's ports to
the server computer. Follow the
[port forwarding guide](https://github.com/abspwgm/absolute-game-servers/blob/main/docs/port-forwarding.md)
and use this table when it asks for ports:

| Port | Protocol | What it is for | Forward it? |
|---|---|---|---|
| 8211 | UDP | Game traffic | Yes, forward |
| 27015 | UDP | Steam server query | Yes, forward |
| 25575 | TCP | RCON, the remote admin console | No, keep private. It is switched off by default and the settings file above does not open it |

Then your friends join exactly as you did in Step 5, but with your public address
instead of the home one, for example `203.0.113.25:8211`. The port forwarding guide shows
how to find your public address.

## Looking after your server

| I want to | Command |
|---|---|
| See if it is running | `docker compose ps` |
| Watch the log | `docker compose logs -f` |
| Stop it (saves the world first) | `docker compose down` |
| Start it again | `docker compose up -d` |
| Update the game right now | `docker compose restart` |
| Make a backup right now | `docker compose exec palworld /opt/palworld/scripts/palworld-backup --force` |
| Get our latest fixes | `docker compose pull` then `docker compose up -d` |

**Updates.** The server checks Steam for a new version of the game each time it starts
(`UPDATE_ON_START=true`), which is why a restart is all an update takes. Restarting
disconnects anyone who is playing, so pick a quiet moment.

**Backups.** A backup is made every hour, on the hour, into `/config/backups` inside the
`palworld-config` volume (a volume is Docker's own storage area, which survives updates
and restarts). Each one is a file named like `palworld_20250101_120000.zip`. The
`BACKUPS_MAX_COUNT=72` line in your settings file keeps the newest 72, which is three
days' worth, and removes older ones.

A backup on the same disk does not survive the disk failing. Copy the backups out to the
current folder now and then, and move that copy somewhere else:

```sh
docker compose cp palworld:/config/backups ./backups
```

You should see `Successfully copied` and a new `backups` folder.

**Restoring a backup.**

1. Stop the server, so it cannot overwrite the files you are about to restore:

   ```sh
   docker compose stop
   ```

   You should see `Container palworld-server  Stopped`.

2. List your backups and pick one. The numbers are the date and time it was made:

   ```sh
   docker compose run --rm --entrypoint bash palworld -c "ls -1 /config/backups"
   ```

   You should see names like `palworld_20250101_120000.zip`.

3. Restore it. Replace `palworld_20250101_120000` on the first line with the name you
   picked, without the `.zip`. On Linux, paste the whole block at once:

   ```sh
   BACKUP=palworld_20250101_120000
   docker compose run --rm --entrypoint bash -e BACKUP=$BACKUP palworld -c 'set -e; S=/opt/palworld/server/Pal/Saved; cd /tmp; unzip -q /config/backups/$BACKUP.zip; mv $S/SaveGames $S/SaveGames.before-restore; cp -r /tmp/$BACKUP/SaveGames $S/SaveGames; echo Restored $BACKUP'
   ```

   On Windows PowerShell, use `$env:BACKUP="palworld_20250101_120000"` as the first line
   and `$env:BACKUP` in place of the first `$BACKUP` on the second.

   You should see `Restored palworld_20250101_120000`. Your previous world is kept
   beside it as `SaveGames.before-restore`.

4. Start the server again:

   ```sh
   docker compose up -d
   ```

## When something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| `docker: command not found` | Docker is not installed, or you have not logged out and in since Step 1 | Redo Step 1 |
| `permission denied` talking to Docker | Your user is not in the `docker` group yet | Log out and back in, or put `sudo` in front |
| `yaml:` error on start | The spacing in `docker-compose.yml` was changed | Paste the file again from Step 3 |
| Log stays at `Starting Palworld server update` for a long time | The first download is large | Wait. It picks up where it left off if interrupted |
| `Server update timed out after 900s` | The download did not finish within 15 minutes | Wait. The server restarts by itself and carries on. On a slow connection, add the line `- UPDATE_TIMEOUT=3600` under `environment:` |
| `No server files found, cannot continue` | The download failed before the game was installed | Check your internet connection and free disk space, then run `docker compose restart` |
| `port is already allocated` | Another program is using the game's port | Stop the other server, or change the left-hand number of the port pair |
| STATUS shows `(unhealthy)` | The game is not running inside the container | Run `docker compose logs` and look for lines marked `[ERROR]`. |
| I can join, my friends cannot | Port forwarding | Work through the table at the end of the port forwarding guide |

Still stuck? [Open an issue](https://github.com/abspwgm/absolute-palworld-server/issues/new) and paste the last 50 lines of
`docker compose logs`. Remove your server password first.

## Words used in this guide

- **Container:** the sealed box Docker runs the server in.
- **Image:** the download that a container is started from. Ours is `abspwgm/absolute-palworld-server:latest`.
- **Compose file:** `docker-compose.yml`, the one file holding all your server's settings.
- **Volume:** a storage area Docker manages that the container saves into, so your world
  survives updates and restarts.
- **Port:** a numbered door on a network address. Games listen on specific ones.
- **UDP / TCP:** two ways of sending data. A forwarding rule must use the one the game uses.
- **RCON:** a remote admin console for the game. Anyone who can reach it and guess the
  admin password controls your server, so it stays private.
