# MCServerManager

A simple but capable bash script for creating, running, and managing Minecraft servers on Linux.

## Backstory
A friend once bet me an 8GB DDR4 RAM, 20-core Minecraft server if I could set up a LeafMC server in under 5 minutes. I said "no" about ten times. With RAM prices being what they are (or were), the odds of him actually following through seemed close to zero. But eventually, I took the challenge, opened my terminal, fired up a server and got it done (then deleted the server right after).

That experience got me thinking: why not automate this? So I built a bash script to create, backup, delete, and manage Minecraft servers — and decided to make it public for anyone who needs it. Or lands in a situation like me ;)

## Features

- **Multi-software support** — LeafMC, Paper, Purpur, Spigot, Fabric, and Vanilla
- **Named servers** — give each server a name; version and software type are stored in `ServerManager/`
- **Crash detection & auto-restart** — servers restart automatically on crash; after 3 crashes in 10 minutes the watcher gives up and logs the event
- **Crash logs** — all crashes are written to `/opt/mcservers/LOGS/YYYY-MM-DD.log` with timestamps and exit codes
- **Resource monitor** — live CPU % and RAM used vs allocated for a running server
- **Backup & restore** — manual backups with configurable retention (default: keep last 5)
- **Scheduled backups** — set up automatic backups via cron directly from the menu
- **RCON integration** — send commands to running servers without leaving the manager
- **Multi-server orchestration** — Start all / Stop all from the main menu
- **tmux-based** — servers survive terminal disconnects; attach anytime with `tmux attach`

## Dependencies

Install these packages if they're not installed already:

```bash
# On Arch
sudo pacman -S tmux curl openssl tailscale ufw firejail
paru -S mcrcon
```

Also make sure you have Java:

```bash
# On Arch
sudo pacman -S jdk21-openjdk
```

Verify:
```bash
java --version
tmux --version
mcrcon --version
```

## Installation

1. Create the directory and take ownership:
```bash
sudo mkdir -p /opt/mcservers
sudo chown -R $USER:$USER /opt/mcservers
```

2. Download the script:
```bash
curl -o /opt/mcservers/server.sh https://raw.githubusercontent.com/CallMeAlphabet/MCServerManager/refs/heads/main/server.sh
chmod +x /opt/mcservers/server.sh
```

3. Run it:
```bash
/opt/mcservers/server.sh
```

## Directory structure

```
/opt/mcservers/
├── server.sh               ← this script
├── backups/
│   └── <server-name>/      ← .tar.gz backups per server
├── LOGS/
│   └── YYYY-MM-DD.log      ← crash logs
└── <server-name>/
    ├── server.jar
    ├── start.sh
    ├── server.properties
    ├── eula.txt
    ├── .mcserver.conf       ← RCON credentials
    └── ServerManager/
        ├── type             ← e.g. "paper"
        ├── version          ← e.g. "1.21.4"
        ├── backup_keep      ← retention count
        ├── watcher.sh       ← auto-generated crash watcher
        └── stopping         ← flag file for intentional stops
```
