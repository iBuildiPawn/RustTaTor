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
    exit 2
fi

# Store the actual user who ran sudo
ACTUAL_USER=$SUDO_USER
if [ -z "$ACTUAL_USER" ]; then
    print_error "Could not determine the actual user"
    exit 1
fi

# Get the actual user's home directory
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

print_status "Setting up RustTaTor..."

# Update package list
print_status "Updating package list..."
apt-get update

# Install prerequisites
print_status "Installing prerequisites..."
PREREQUISITES=(
    "build-essential"
    "pkg-config"
    "libssl-dev"
    "curl"
    "git"
    "net-tools"
    "systemd"
    "tor"
)

for pkg in "${PREREQUISITES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        print_status "Installing $pkg..."
        apt-get install -y "$pkg"
        if [ $? -eq 0 ]; then
            print_success "$pkg installed successfully"
        else
            print_error "Failed to install $pkg"
            exit 1
        fi
    else
        print_success "$pkg is already installed"
    fi
done

# Check if Tor is installed
if ! command -v tor &> /dev/null; then
    print_status "Tor is not installed. Installing Tor..."
    apt-get install -y tor
    print_success "Tor installed successfully"
else
    print_success "Tor is already installed"
fi

# Check if Rust is installed for the actual user
if ! su - "$ACTUAL_USER" -c "command -v rustc" &> /dev/null; then
    print_status "Rust is not installed. Installing Rust for $ACTUAL_USER..."
    
    # Install Rust using rustup (as the actual user)
    su - "$ACTUAL_USER" -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
    
    # Add Rust to PATH for this script session
    if [ -f "$USER_HOME/.cargo/env" ]; then
        su - "$ACTUAL_USER" -c "source $USER_HOME/.cargo/env"
        print_success "Rust installed successfully"
    else
        print_error "Failed to install Rust. Please install manually using: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        exit 1
    fi
else
    print_success "Rust is already installed"
    # Update Rust to ensure it's the latest version
    su - "$ACTUAL_USER" -c "rustup update"
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

# Create override.conf with proper permissions
cat > /etc/systemd/system/tor.service.d/override.conf << EOL
[Service]
User=debian-tor
Group=debian-tor
RuntimeDirectory=tor
RuntimeDirectoryMode=0755
EOL

# Backup original torrc if it doesn't exist
if [ ! -f /etc/tor/torrc.backup ]; then
    cp /etc/tor/torrc /etc/tor/torrc.backup
fi

# Configure torrc with more detailed settings
print_status "Generating Tor control password hash..."
TOR_PASS="RustTaTorControlPass123"
TOR_HASH=$(tor --hash-password "${TOR_PASS}" | tail -n 1)

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
EOL

# Set proper permissions for Tor directories
print_status "Setting up Tor directories and permissions..."
mkdir -p /var/lib/tor
mkdir -p /var/log/tor
mkdir -p /run/tor
chown -R debian-tor:debian-tor /var/lib/tor
chown -R debian-tor:debian-tor /var/log/tor
chown -R debian-tor:debian-tor /run/tor
chmod 755 /run/tor

# Add user to debian-tor group for cookie access
print_status "Adding user to debian-tor group..."
usermod -a -G debian-tor "$ACTUAL_USER"
print_success "User added to debian-tor group"

# Ensure Tor service is enabled
print_status "Enabling Tor service..."
systemctl enable tor

# Reload systemd and restart Tor
print_status "Reloading systemd daemon..."
systemctl daemon-reload

print_status "Stopping Tor service..."
systemctl stop tor
sleep 2

print_status "Starting Tor service..."
systemctl start tor
sleep 5

# Verify cookie file permissions after Tor starts
if [ -f "/run/tor/control.authcookie" ]; then
    print_status "Setting cookie file permissions..."
    chown debian-tor:debian-tor /run/tor/control.authcookie
    chmod 640 /run/tor/control.authcookie
    print_success "Cookie file permissions set"
else
    print_error "Cookie file not created by Tor"
    exit 1
fi

# Check if Tor is running
if systemctl is-active --quiet tor; then
    print_success "Tor service is running"
    # Check Tor logs for any issues
    if [ -f "/var/log/tor/notices.log" ]; then
        print_status "Checking Tor logs for issues..."
        if grep -i "error\|warning\|failed" /var/log/tor/notices.log; then
            print_error "Found issues in Tor logs"
            cat /var/log/tor/notices.log
        else
            print_success "No issues found in Tor logs"
        fi
    fi
else
    print_error "Tor service failed to start"
    print_status "Checking Tor logs..."
    journalctl -u tor -n 50
    print_status "Checking Tor process..."
    ps aux | grep tor
    print_status "Checking Tor service status..."
    systemctl status tor
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

# Function to check network interface
check_network() {
    print_status "Checking network interfaces..."
    ip addr show
    print_status "Checking localhost interface..."
    ip addr show lo
    print_status "Checking if localhost is up..."
    ping -c 1 127.0.0.1
}

# Verify SOCKS port is listening
if check_port 9052; then
    print_success "Tor SOCKS port (9052) is listening"
else
    print_error "Tor SOCKS port is not listening"
    print_status "Checking Tor configuration..."
    if [ -f "/var/log/tor/notices.log" ]; then
        cat /var/log/tor/notices.log
    fi
    print_status "Checking Tor process..."
    ps aux | grep tor
    print_status "Checking Tor service status..."
    systemctl status tor
    check_network
    print_status "Waiting a bit longer and trying again..."
    sleep 5
    if check_port 9052; then
        print_success "Tor SOCKS port (9052) is now listening"
    else
        print_error "Tor SOCKS port is still not listening"
        print_status "Attempting to restart Tor service..."
        systemctl restart tor
        sleep 5
        if check_port 9052; then
            print_success "Tor SOCKS port (9052) is now listening"
        else
            print_error "Tor SOCKS port is still not listening"
            print_status "Checking Tor configuration file..."
            cat /etc/tor/torrc
            print_status "Checking Tor service configuration..."
            cat /etc/systemd/system/tor.service.d/override.conf
            print_status "Checking system logs..."
            journalctl -u tor -n 100
            print_status "Checking if port is in use..."
            lsof -i :9052
            print_status "Checking firewall rules..."
            if command -v ufw &> /dev/null; then
                ufw status
            fi
            if command -v iptables &> /dev/null; then
                iptables -L
            fi
            exit 1
        fi
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

# Set up environment variables in user's profile
print_status "Setting up environment variables..."
ENV_FILE="$USER_HOME/.profile"

# Check if we need to add Rust to PATH
if ! grep -q "/.cargo/env" "$ENV_FILE"; then
    cat >> "$ENV_FILE" << EOL

# Rust environment
if [ -f "$USER_HOME/.cargo/env" ]; then
    . "$USER_HOME/.cargo/env"
fi
EOL
    print_success "Added Rust to PATH in $ENV_FILE"
fi

# Add RustTaTor environment variables
if ! grep -q "RUSTATOR_TOR_SOCKS_PORT" "$ENV_FILE"; then
    cat >> "$ENV_FILE" << EOL

# RustTaTor environment
export RUSTATOR_TOR_SOCKS_PORT=9052
export RUSTATOR_TOR_CONTROL_PORT=9053
export RUSTATOR_TOR_CONTROL_PASSWORD="${TOR_PASS}"
EOL
    print_success "Added RustTaTor environment variables to $ENV_FILE"
fi

# Check if project dependencies are installed
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/Cargo.toml" ]; then
    print_status "Building RustTaTor project..."
    # Build the project as the actual user
    cd "$SCRIPT_DIR"
    su - "$ACTUAL_USER" -c "cd $SCRIPT_DIR && cargo build"
    if [ $? -eq 0 ]; then
        print_success "RustTaTor project built successfully"
    else
        print_error "Failed to build RustTaTor project. Please check Cargo.toml and dependencies."
    fi
else
    print_status "Cargo.toml not found. Skipping project build."
fi

print_success "Setup completed successfully!"
print_status "You may need to log out and log back in for group changes to take effect"
print_status "Environment variables have been set in $ENV_FILE"
print_status "To run RustTaTor, use: cargo run -- -s 9052 -c 9053"
