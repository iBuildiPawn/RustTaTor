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
else
    print_success "Tor installed successfully"
fi

# Install required tools
print_status "Checking and installing required tools..."
if ! command -v netstat &> /dev/null; then
    apt-get install -y net-tools
    print_success "net-tools (netstat) installed"
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
User=debian-tor
Group=debian-tor
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

# Restart Tor to generate the cookie file
print_status "Starting Tor service to generate cookie file..."
systemctl restart tor
sleep 3

# Set correct permissions
print_status "Setting permissions..."
# Make sure the directory and cookie file exist before modifying permissions
if [ -d "/var/lib/tor" ]; then
    # Ensure the tor service user (usually debian-tor) owns the directory
    chown -R debian-tor:debian-tor /var/lib/tor
    chmod 750 /var/lib/tor
    
    # Add the tor-control group as a supplementary group to the cookie file
    if [ -f "/var/lib/tor/control_auth_cookie" ]; then
        # Change group of cookie file to tor-control
        chgrp tor-control /var/lib/tor/control_auth_cookie
        chmod 640 /var/lib/tor/control_auth_cookie
        print_success "Permissions set correctly"
    else
        print_error "Cookie file not found. Tor might not be configured correctly."
        journalctl -u tor -n 20
    fi
else
    print_error "Tor data directory not found"
    exit 1
fi

# Reload systemd and restart Tor
print_status "Restarting Tor service..."
systemctl daemon-reload
systemctl restart tor
sleep 3

# Check if Tor is running
if systemctl is-active --quiet tor; then
    print_success "Tor service is running"
else
    print_error "Tor service failed to start"
    print_status "Checking Tor logs..."
    journalctl -u tor -n 50
    exit 1
fi

# Function to check if a port is listening
check_port() {
    local port=$1
    local command="netstat"
    local args="-tuln"
    
    # If netstat is not available, try ss
    if ! command -v netstat &> /dev/null; then
        if command -v ss &> /dev/null; then
            command="ss"
            args="-tuln"
        else
            print_error "Neither netstat nor ss is available. Install net-tools or iproute2."
            return 1
        fi
    fi
    
    if $command $args | grep -q ":$port "; then
        return 0
    else
        return 1
    fi
}

# Verify SOCKS port is listening
if check_port 9052; then
    print_success "Tor SOCKS port (9052) is listening"
else
    print_error "Tor SOCKS port is not listening"
    print_status "Waiting a bit longer and trying again..."
    sleep 5
    if check_port 9052; then
        print_success "Tor SOCKS port (9052) is now listening"
    else
        print_error "Tor SOCKS port is still not listening"
        exit 1
    fi
fi

# Verify Control port is listening
if check_port 9053; then
    print_success "Tor Control port (9053) is listening"
else
    print_error "Tor Control port is not listening"
    print_status "Waiting a bit longer and trying again..."
    sleep 5
    if check_port 9053; then
        print_success "Tor Control port (9053) is now listening"
    else
        print_error "Tor Control port is still not listening"
        exit 1
    fi
fi

print_success "Setup completed successfully!"
print_status "You may need to log out and log back in for group changes to take effect"
print_status "To run RustTaTor, use: cargo run -- -s 9052 -c 9053" 