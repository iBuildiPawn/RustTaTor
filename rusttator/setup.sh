#!/bin/bash

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${YELLOW}[*]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check if script is run with sudo
if [ "$EUID" -ne 0 ]; then
    print_error "Please run this script with sudo"
    exit 1
fi

# Store the actual user who ran sudo
ACTUAL_USER=$SUDO_USER
if [ -z "$ACTUAL_USER" ]; then
    print_error "Could not determine the actual user"
    exit 1
fi

print_status "Setting up RustTaTor..."

# Check if Tor is installed
if ! command -v tor &> /dev/null; then
    print_status "Tor is not installed. Installing Tor..."
    apt-get update
    apt-get install -y tor
    print_success "Tor installed successfully"
fi

# Create tor-control group if it doesn't exist
if ! getent group tor-control > /dev/null; then
    print_status "Creating tor-control group..."
    groupadd tor-control
    print_success "tor-control group created"
fi

# Add user to tor-control group
print_status "Adding user to tor-control group..."
usermod -a -G tor-control "$ACTUAL_USER"
print_success "User added to tor-control group"

# Configure Tor service
print_status "Configuring Tor service..."

# Create Tor service override directory
mkdir -p /etc/systemd/system/tor.service.d/

# Create override.conf
cat > /etc/systemd/system/tor.service.d/override.conf << EOL
[Service]
User=$ACTUAL_USER
Group=$ACTUAL_USER
EOL

# Backup original torrc if it doesn't exist
if [ ! -f /etc/tor/torrc.backup ]; then
    cp /etc/tor/torrc /etc/tor/torrc.backup
fi

# Configure torrc
cat > /etc/tor/torrc << EOL
SocksPort 9052
ControlPort 9053
CookieAuthentication 1
CookieAuthFile /var/lib/tor/control_auth_cookie
CookieAuthFileGroupReadable 1
DataDirectory /var/lib/tor
EOL

# Set correct permissions
print_status "Setting permissions..."
chown -R "$ACTUAL_USER:$ACTUAL_USER" /var/lib/tor
chmod 750 /var/lib/tor
chown "$ACTUAL_USER:tor-control" /var/lib/tor/control_auth_cookie
chmod 640 /var/lib/tor/control_auth_cookie

# Reload systemd and restart Tor
print_status "Restarting Tor service..."
systemctl daemon-reload
systemctl restart tor
sleep 2

# Check if Tor is running
if systemctl is-active --quiet tor; then
    print_success "Tor service is running"
else
    print_error "Tor service failed to start"
    print_status "Checking Tor logs..."
    journalctl -u tor -n 50
    exit 1
fi

# Verify SOCKS port is listening
if netstat -tuln | grep -q ":9052 "; then
    print_success "Tor SOCKS port (9052) is listening"
else
    print_error "Tor SOCKS port is not listening"
    exit 1
fi

# Verify Control port is listening
if netstat -tuln | grep -q ":9053 "; then
    print_success "Tor Control port (9053) is listening"
else
    print_error "Tor Control port is not listening"
    exit 1
fi

print_success "Setup completed successfully!"
print_status "You may need to log out and log back in for group changes to take effect"
print_status "To run RustTaTor, use: cargo run -- -s 9052 -c 9053" 