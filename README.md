# 🌐 RustTaTor

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
git clone https://github.com/yourusername/rusttator.git
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

If you prefer to set up manually instead of using the setup script:

1. Install Tor:
```bash
sudo apt-get update
sudo apt-get install tor
```

2. Configure Tor (`/etc/tor/torrc`):
```
SocksPort 9052
ControlPort 9053
CookieAuthentication 1
CookieAuthFile /var/lib/tor/control_auth_cookie
CookieAuthFileGroupReadable 1
DataDirectory /var/lib/tor
```

3. Set up permissions:
```bash
sudo groupadd tor-control
sudo usermod -a -G tor-control $USER
sudo chown -R $USER:$USER /var/lib/tor
sudo chmod 750 /var/lib/tor
sudo chown $USER:tor-control /var/lib/tor/control_auth_cookie
sudo chmod 640 /var/lib/tor/control_auth_cookie
```

4. Configure Tor service:
```bash
sudo mkdir -p /etc/systemd/system/tor.service.d/
echo -e "[Service]\nUser=$USER\nGroup=$USER" | sudo tee /etc/systemd/system/tor.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart tor
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