# Hosting a Multiplayer Minesweeper Lobby Server

This guide explains how to run a dedicated lobby server for Multiplayer Minesweeper.

## Overview

The lobby server handles:
- Player connections
- Room creation and management
- Matchmaking (grouping 3 players into game sessions)

Once 3 players are in a room, the game starts automatically with the room host acting as the game server.

## Quick Start

### Linux

```bash
# Download the server build
wget https://github.com/YOUR_ORG/multiplayer-minesweeper/releases/latest/download/multiplayer-minesweeper-server-linux.zip
unzip multiplayer-minesweeper-server-linux.zip
chmod +x multiplayer-minesweeper-server.x86_64

# Run the server
./multiplayer-minesweeper-server.x86_64 --server --port 7777
```

### Command-Line Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `--server` | Run as dedicated lobby server (headless) | Required |
| `--port PORT` | UDP port to listen on | 7777 |

## Server Requirements

### Hardware

- **CPU:** 1 core minimum (very lightweight)
- **RAM:** 128 MB minimum
- **Storage:** 50 MB for the executable
- **Network:** 1 Mbps upload per 10 concurrent rooms

### Software

- Linux x86_64 (Ubuntu 20.04+, Debian 11+, or similar)
- No additional dependencies (statically linked)

### Network

The server uses **UDP** for all game communication via ENet.

**Required Ports:**
- UDP 7777 (or your custom port)

## Firewall Configuration

### UFW (Ubuntu/Debian)

```bash
sudo ufw allow 7777/udp comment "Multiplayer Minesweeper"
sudo ufw reload
```

### iptables

```bash
sudo iptables -A INPUT -p udp --dport 7777 -j ACCEPT
```

### firewalld (RHEL/CentOS)

```bash
sudo firewall-cmd --permanent --add-port=7777/udp
sudo firewall-cmd --reload
```

## Running as a Service

### systemd Service

Create `/etc/systemd/system/minesweeper-lobby.service`:

```ini
[Unit]
Description=Multiplayer Minesweeper Lobby Server
After=network.target

[Service]
Type=simple
User=minesweeper
Group=minesweeper
WorkingDirectory=/opt/minesweeper
ExecStart=/opt/minesweeper/multiplayer-minesweeper-server.x86_64 --server --port 7777
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
# Create service user
sudo useradd -r -s /bin/false minesweeper

# Install the server
sudo mkdir -p /opt/minesweeper
sudo cp multiplayer-minesweeper-server.x86_64 /opt/minesweeper/
sudo chown -R minesweeper:minesweeper /opt/minesweeper

# Enable and start service
sudo systemctl daemon-reload
sudo systemctl enable minesweeper-lobby
sudo systemctl start minesweeper-lobby

# Check status
sudo systemctl status minesweeper-lobby
sudo journalctl -u minesweeper-lobby -f
```

## Docker Deployment

### Dockerfile

```dockerfile
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY multiplayer-minesweeper-server.x86_64 /app/server

RUN chmod +x /app/server

# Run as non-root user
RUN useradd -r -s /bin/false minesweeper
USER minesweeper

EXPOSE 7777/udp

ENTRYPOINT ["/app/server", "--server"]
CMD ["--port", "7777"]
```

### Build and Run

```bash
# Build the image
docker build -t minesweeper-lobby .

# Run the container
docker run -d \
    --name minesweeper-lobby \
    -p 7777:7777/udp \
    --restart unless-stopped \
    minesweeper-lobby
```

### Docker Compose

```yaml
version: '3.8'

services:
  minesweeper-lobby:
    build: .
    container_name: minesweeper-lobby
    ports:
      - "7777:7777/udp"
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 128M
```

## Cloud Deployment

### AWS EC2

1. Launch a `t3.micro` instance (free tier eligible)
2. Configure security group to allow UDP 7777 inbound
3. Install and run the server as shown above

### DigitalOcean

1. Create a Basic Droplet ($4/month, 512 MB RAM)
2. Configure firewall via Cloud Firewall or UFW
3. Deploy using the systemd service method

### Hetzner Cloud

1. Create a CX11 instance (€3.79/month)
2. Configure firewall rules
3. Deploy using Docker or systemd

## Monitoring

### Server Logs

The server outputs connection and room events:

```
═══════════════════════════════════════════════════════════════
  MULTIPLAYER MINESWEEPER - LOBBY SERVER
  Port: 7777
═══════════════════════════════════════════════════════════════
Lobby server running. Waiting for connections...
[LOBBY] Room created: ABC123
[LOBBY] Room created: XYZ789
[LOBBY] Game starting in room: ABC123
[LOBBY] Room destroyed: ABC123
```

### Health Checks

The server doesn't have a built-in HTTP health endpoint, but you can monitor:

1. **Process running:** `pgrep -f multiplayer-minesweeper-server`
2. **Port listening:** `ss -ulnp | grep 7777`
3. **Connection test:** Use a game client to connect

## Troubleshooting

### Server won't start

- Check if port is already in use: `ss -ulnp | grep 7777`
- Check file permissions: `ls -la multiplayer-minesweeper-server.x86_64`
- Check system logs: `journalctl -u minesweeper-lobby -n 50`

### Players can't connect

- Verify firewall allows UDP 7777
- Check if server is running: `pgrep -f multiplayer-minesweeper-server`
- Test from local network first
- Check NAT/port forwarding if behind router

### High memory usage

The server is lightweight. If memory grows over time:
- Check for resource leaks (file an issue)
- Set up automatic restarts: `systemctl restart minesweeper-lobby`

## Scaling

For large player counts, run multiple lobby servers:

1. Deploy servers in different regions
2. Use DNS round-robin or a load balancer
3. Each server operates independently

**Capacity Estimate:**
- 1 server can handle ~500+ concurrent rooms
- Each room uses ~1 KB of memory
- Network: ~10 KB/s per active room

## Security Considerations

1. **Run as non-root:** Always use a dedicated service user
2. **Firewall:** Only expose the game port
3. **Updates:** Subscribe to releases for security updates
4. **Isolation:** Use Docker or VMs for additional security

## Support

For issues and feature requests, please file an issue on GitHub.

