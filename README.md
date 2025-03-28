# 🌐 RustRotateTor

```
██████╗ ██╗   ██╗███████╗████████╗████████╗ █████╗ ████████╗ ██████╗ ██████╗ 
██╔══██╗██║   ██║██╔════╝╚══██╔══╝╚══██╔══╝██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗
██████╔╝██║   ██║███████╗   ██║      ██║   ███████║   ██║   ██║   ██║██████╔╝
██╔══██╗██║   ██║╚════██║   ██║      ██║   ██╔══██║   ██║   ██║   ██║██╔══██╗
██║  ██║╚██████╔╝███████║   ██║      ██║   ██║  ██║   ██║   ╚██████╔╝██║  ██║
╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝      ╚═╝   ╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝
```

> 🔒 **Stay Anonymous. Stay Safe.**

A blazingly fast Rust-powered Tor controller with automatic IP switching, real-time tracking, and secure circuit management.

## 🚀 Quick Start

### 1. Run Setup Script
```bash
# Clone the repository
git clone https://github.com/iBuildiPawn/RustTaTor.git
cd rusttator

# Run the setup script (requires sudo)
sudo ./setup.sh

# Log out and log back in for group changes to take effect
```

### 2. Run RustTaTor
```bash
cd rusttator
cargo run -- -s 9052 -c 9053
```

## 🚀 Features

- 🔄 Automatic IP rotation
- 🌍 Real-time geolocation tracking
- 🔒 Secure circuit management
- 🖥️ Command-line interface
- 🚦 Traffic monitoring
- 🔐 Cookie authentication

## 🛠️ Manual Setup (Alternative)

If you prefer to set up manually instead of using the setup script, follow these steps:

### 1. System Requirements
- Ubuntu 22.04 or later
- Minimum 1GB RAM
- Minimum 1GB free disk space
- Required packages:
  ```bash
  sudo apt-get update
  sudo apt-get install build-essential pkg-config libssl-dev curl git net-tools systemd tor
  ```

### 2. Install Rust
```bash
# Install Rust using rustup
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# Add Rust to your PATH
source $HOME/.cargo/env

# Verify installation
rustc --version  # Should be 1.70.0 or later
```

### 3. Configure Tor

1. Create Tor service override directory:
```bash
sudo mkdir -p /etc/systemd/system/tor.service.d/
```

2. Create service override file:
```bash
cat > /etc/systemd/system/tor.service.d/override.conf << EOL
[Service]
User=debian-tor
Group=debian-tor
RuntimeDirectory=tor
RuntimeDirectoryMode=0755
EOL
```

3. Configure Tor (`/etc/tor/torrc`):
```bash
cat > /etc/tor/torrc << EOL
SocksPort 127.0.0.1:9052
ControlPort 127.0.0.1:9053
CookieAuthentication 1
CookieAuthFile /run/tor/control.authcookie
CookieAuthFileGroupReadable 1
DataDirectory /var/lib/tor
Log notice file /var/log/tor/notices.log
Log info file /var/log/tor/info.log
RunAsDaemon 1
User debian-tor
# Additional settings for better connectivity
MaxCircuitDirtiness 600
CircuitBuildTimeout 30
LearnCircuitBuildTimeout 0
EnforceDistinctSubnets 1
# Exit nodes configuration
ExitNodes {us},{ca},{gb},{de},{fr},{nl},{se},{no},{dk},{fi}
StrictNodes 1
# Connection settings
ConnectionPadding auto
ReducedConnectionPadding 0
# DNS settings
DNSPort 127.0.0.1:9053
EOL
```

### 4. Set Up Permissions

1. Create required groups and add user:
```bash
sudo groupadd tor-control
sudo usermod -a -G tor-control $USER
sudo usermod -a -G debian-tor $USER
```

2. Create and set permissions for Tor directories:
```bash
sudo mkdir -p /var/lib/tor
sudo mkdir -p /var/log/tor
sudo mkdir -p /run/tor

sudo chown -R debian-tor:debian-tor /var/lib/tor
sudo chown -R debian-tor:debian-tor /var/log/tor
sudo chown -R debian-tor:debian-tor /run/tor
sudo chmod 755 /run/tor
```

### 5. Start Tor Service

```bash
# Reload systemd and restart Tor
sudo systemctl daemon-reload
sudo systemctl stop tor
sudo systemctl start tor
sudo systemctl enable tor

# Wait for Tor to start
sleep 5
```

### 6. Verify Installation

1. Check Tor service status:
```bash
sudo systemctl status tor
```

2. Verify Tor connectivity:
```bash
curl --socks5-hostname 127.0.0.1:9052 -s https://check.torproject.org/api/ip
```

3. Check Tor logs for issues:
```bash
sudo cat /var/log/tor/notices.log
```

### 7. Set Up Environment Variables

Add these to your `~/.profile`:
```bash
# RustTaTor environment
export RUSTATOR_TOR_SOCKS_PORT=9052
export RUSTATOR_TOR_CONTROL_PORT=9053
export RUSTATOR_TOR_CONTROL_PASSWORD="$(tor --hash-password "your_secure_password" | tail -n 1)"
```

### 8. Build the Project

```bash
cd rusttator
cargo build
```

## 🔧 Usage

Basic usage:
```bash
cargo run -- -s 9052 -c 9053
```

Custom ports:
```bash
cargo run -- -s <socks_port> -c <control_port>
```

## 🔒 Security Notes

- ⚠️ Keep your Tor service updated
- 🛡️ Never expose control ports to the internet
- 📜 Use responsibly and in accordance with local laws
- 🔒 Default configuration prioritizes security
- 📜 Monitor system logs for unauthorized access attempts
- 🔐 Use strong passwords for Tor control
- 🛡️ Regularly check Tor logs for security issues
- 🔒 Keep your system and dependencies updated

## 🤝 Contributing

Contributions are welcome! Please feel free to submit pull requests.

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## 📜 License

This project is licensed under the MIT License - see the LICENSE file for details.

---

**⚠️ Disclaimer:** This tool is for educational and research purposes only. Use responsibly and in accordance with all applicable laws and regulations.

---
<div align="center">
🔒 <i>With great power comes great responsibility.</i> 🔒
</div> 