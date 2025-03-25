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

# Install build dependencies
print_status "Installing build dependencies..."
apt-get install -y build-essential pkg-config libssl-dev curl
print_success "Build dependencies installed"

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
HashedControlPassword 16:01234567890ABCDEF01234567890ABCDEF01234567890ABCDEF01234567890ABCDEF
DataDirectory /var/lib/tor
EOL

# Restart Tor to apply new configuration
print_status "Starting Tor service..."
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
export RUSTATOR_TOR_CONTROL_PASSWORD=01234567890ABCDEF01234567890ABCDEF01234567890ABCDEF01234567890ABCDEF
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
