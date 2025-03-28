#!/bin/bash

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Version requirements
MIN_RUST_VERSION="1.70.0"
MIN_UBUNTU_VERSION="22.04"
MIN_MEMORY_MB=1024
MIN_DISK_SPACE_MB=1000

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

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

# Function to check system requirements
check_system_requirements() {
    print_status "Checking system requirements..."
    
    # Check Ubuntu version
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" = "ubuntu" ]; then
            if [ "$(printf '%s\n' "$MIN_UBUNTU_VERSION" "$VERSION_ID" | sort -V | head -n1)" != "$MIN_UBUNTU_VERSION" ]; then
                print_error "Ubuntu version $VERSION_ID is not supported. Minimum version required: $MIN_UBUNTU_VERSION"
                exit 1
            fi
        else
            print_error "This script is designed for Ubuntu systems"
            exit 1
        fi
    else
        print_error "Could not determine OS version"
        exit 1
    fi

    # Check memory
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_mem" -lt "$MIN_MEMORY_MB" ]; then
        print_error "Insufficient memory. Required: ${MIN_MEMORY_MB}MB, Available: ${total_mem}MB"
        exit 1
    fi

    # Check disk space
    free_space=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt "$MIN_DISK_SPACE_MB" ]; then
        print_error "Insufficient disk space. Required: ${MIN_DISK_SPACE_MB}MB, Available: ${free_space}MB"
        exit 1
    fi
}

# Function to backup file
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        cp "$file" "${file}.backup.$(date +%Y%m%d_%H%M%S)"
        if [ $? -ne 0 ]; then
            print_error "Failed to backup $file"
            exit 1
        fi
    fi
}

# Function to restore backup
restore_backup() {
    local file="$1"
    local latest_backup=$(ls -t "${file}.backup."* 2>/dev/null | head -n1)
    if [ -n "$latest_backup" ]; then
        cp "$latest_backup" "$file"
        if [ $? -ne 0 ]; then
            print_error "Failed to restore backup for $file"
            exit 1
        fi
    fi
}

# Function to check if a port is in use
check_port_in_use() {
    local port="$1"
    if lsof -i ":$port" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Function to generate secure password
generate_secure_password() {
    local length=32
    tr -dc 'A-Za-z0-9!#$%&()*+,-./:;<=>?@[\]^_`{|}~' < /dev/urandom | head -c "$length"
}

# Function to validate Tor configuration
validate_tor_config() {
    local torrc="$1"
    if [ ! -f "$torrc" ]; then
        print_error "Tor configuration file not found: $torrc"
        return 1
    fi

    # Check for required settings
    local required_settings=(
        "SocksPort"
        "ControlPort"
        "CookieAuthentication"
        "DataDirectory"
        "RunAsDaemon"
    )

    for setting in "${required_settings[@]}"; do
        if ! grep -q "^$setting" "$torrc"; then
            print_error "Missing required Tor setting: $setting"
            return 1
        fi
    done

    return 0
}

# Function to check for existing Tor processes
check_existing_tor() {
    if pgrep -x "tor" > /dev/null; then
        print_error "Tor is already running. Please stop it before running this script."
        print_status "You can stop Tor using: sudo systemctl stop tor"
        exit 1
    fi
}

# Function to verify Tor connectivity
verify_tor_connectivity() {
    print_status "Verifying Tor connectivity..."
    
    # Check if Tor service is running
    if ! systemctl is-active --quiet tor; then
        print_error "Tor service is not running"
        return 1
    fi

    # Check if Tor ports are listening
    if ! check_port_in_use 9052; then
        print_error "Tor SOCKS port (9052) is not listening"
        return 1
    fi

    if ! check_port_in_use 9053; then
        print_error "Tor Control port (9053) is not listening"
        return 1
    fi

    # Check Tor logs for issues
    if [ -f "/var/log/tor/notices.log" ]; then
        if grep -i "error\|warning\|failed" /var/log/tor/notices.log; then
            print_error "Found issues in Tor logs"
            cat /var/log/tor/notices.log
            return 1
        fi
    fi

    # Test Tor connectivity using curl
    print_status "Testing Tor connectivity..."
    if ! curl --socks5-hostname 127.0.0.1:9052 -s https://check.torproject.org/api/ip | grep -q "IsTor\":true"; then
        print_error "Failed to connect through Tor"
        print_status "Checking Tor configuration..."
        cat /etc/tor/torrc
        print_status "Checking Tor service status..."
        systemctl status tor
        return 1
    fi

    print_success "Tor connectivity verified"
    return 0
}

# Parse command line arguments
DRY_RUN=false
SKIP_TOR=false
SKIP_RUST=false
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-tor)
            SKIP_TOR=true
            shift
            ;;
        --skip-rust)
            SKIP_RUST=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            print_info "Usage: $0 [--dry-run] [--skip-tor] [--skip-rust] [--skip-build]"
            exit 1
            ;;
    esac
done

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

# Check system requirements
check_system_requirements

# Check for existing Tor processes
check_existing_tor

print_status "Setting up RustTaTor..."

# Update package list
print_status "Updating package list..."
if [ "$DRY_RUN" = false ]; then
    apt-get update
fi

# Install prerequisites with version checking
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
        if [ "$DRY_RUN" = false ]; then
            apt-get install -y "$pkg"
            if [ $? -eq 0 ]; then
                print_success "$pkg installed successfully"
            else
                print_error "Failed to install $pkg"
                exit 1
            fi
        else
            print_info "Would install $pkg"
        fi
    else
        print_success "$pkg is already installed"
    fi
done

# Check if Tor is installed
if ! command -v tor &> /dev/null; then
    print_status "Tor is not installed. Installing Tor..."
    if [ "$DRY_RUN" = false ]; then
        apt-get install -y tor
        print_success "Tor installed successfully"
    else
        print_info "Would install Tor"
    fi
else
    print_success "Tor is already installed"
fi

# Check if Rust is installed for the actual user
if ! su - "$ACTUAL_USER" -c "command -v rustc" &> /dev/null; then
    print_status "Rust is not installed. Installing Rust for $ACTUAL_USER..."
    
    if [ "$DRY_RUN" = false ]; then
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
        print_info "Would install Rust"
    fi
else
    print_success "Rust is already installed"
    # Update Rust to ensure it's the latest version
    if [ "$DRY_RUN" = false ]; then
        su - "$ACTUAL_USER" -c "rustup update"
    fi
fi

# Create tor-control group if it doesn't exist
if ! getent group tor-control > /dev/null; then
    print_status "Creating tor-control group..."
    if [ "$DRY_RUN" = false ]; then
        groupadd tor-control
        print_success "tor-control group created"
    else
        print_info "Would create tor-control group"
    fi
fi

# Add user to tor-control group
print_status "Adding user to tor-control group..."
if [ "$DRY_RUN" = false ]; then
    usermod -a -G tor-control "$ACTUAL_USER"
    print_success "User added to tor-control group"
else
    print_info "Would add user to tor-control group"
fi

# Configure Tor service
if [ "$SKIP_TOR" = false ]; then
    print_status "Configuring Tor service..."

    # Backup original torrc
    backup_file "/etc/tor/torrc"

    # Generate secure password
    TOR_PASS=$(generate_secure_password)
    TOR_HASH=$(tor --hash-password "${TOR_PASS}" | tail -n 1)

    if [ "$DRY_RUN" = false ]; then
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

        # Configure torrc with more detailed settings
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

        # Set proper permissions for Tor directories
        mkdir -p /var/lib/tor
        mkdir -p /var/log/tor
        mkdir -p /run/tor
        chown -R debian-tor:debian-tor /var/lib/tor
        chown -R debian-tor:debian-tor /var/log/tor
        chown -R debian-tor:debian-tor /run/tor
        chmod 755 /run/tor

        # Add user to debian-tor group for cookie access
        usermod -a -G debian-tor "$ACTUAL_USER"

        # Validate Tor configuration
        if ! validate_tor_config "/etc/tor/torrc"; then
            print_error "Invalid Tor configuration"
            restore_backup "/etc/tor/torrc"
            exit 1
        fi

        # Ensure Tor service is enabled
        systemctl enable tor

        # Reload systemd and restart Tor
        systemctl daemon-reload
        systemctl stop tor
        sleep 2
        systemctl start tor
        sleep 5

        # Verify cookie file permissions after Tor starts
        if [ -f "/run/tor/control.authcookie" ]; then
            chown debian-tor:debian-tor /run/tor/control.authcookie
            chmod 640 /run/tor/control.authcookie
        else
            print_error "Cookie file not created by Tor"
            restore_backup "/etc/tor/torrc"
            exit 1
        fi

        # Verify Tor connectivity
        if ! verify_tor_connectivity; then
            print_error "Failed to verify Tor connectivity"
            print_status "Attempting to fix Tor configuration..."
            
            # Check if ports are in use by other services
            if check_port_in_use 9052; then
                print_status "Port 9052 is in use. Checking process..."
                lsof -i :9052
            fi
            if check_port_in_use 9053; then
                print_status "Port 9053 is in use. Checking process..."
                lsof -i :9053
            fi

            # Check firewall rules
            if command -v ufw &> /dev/null; then
                print_status "Checking UFW rules..."
                ufw status
            fi
            if command -v iptables &> /dev/null; then
                print_status "Checking iptables rules..."
                iptables -L
            fi

            # Check system logs
            print_status "Checking system logs..."
            journalctl -u tor -n 100

            print_error "Please check the above information and fix any issues"
            print_status "You may need to:"
            print_status "1. Stop any services using ports 9052 or 9053"
            print_status "2. Configure firewall to allow Tor traffic"
            print_status "3. Check system logs for more details"
            exit 1
        fi
    else
        print_info "Would configure Tor service"
    fi
fi

# Set up environment variables in user's profile
print_status "Setting up environment variables..."
ENV_FILE="$USER_HOME/.profile"

if [ "$DRY_RUN" = false ]; then
    # Backup profile file
    backup_file "$ENV_FILE"

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
else
    print_info "Would update environment variables"
fi

# Build the project
if [ "$SKIP_BUILD" = false ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/Cargo.toml" ]; then
        print_status "Building RustTaTor project..."
        if [ "$DRY_RUN" = false ]; then
            cd "$SCRIPT_DIR"
            su - "$ACTUAL_USER" -c "cd $SCRIPT_DIR && cargo build"
            if [ $? -eq 0 ]; then
                print_success "RustTaTor project built successfully"
            else
                print_error "Failed to build RustTaTor project. Please check Cargo.toml and dependencies."
                exit 1
            fi
        else
            print_info "Would build RustTaTor project"
        fi
    else
        print_status "Cargo.toml not found. Skipping project build."
    fi
fi

print_success "Setup completed successfully!"
print_status "You may need to log out and log back in for group changes to take effect"
print_status "Environment variables have been set in $ENV_FILE"
print_status "To run RustTaTor, use: cargo run -- -s 9052 -c 9053"

if [ "$DRY_RUN" = true ]; then
    print_info "This was a dry run. No changes were made to the system."
fi
