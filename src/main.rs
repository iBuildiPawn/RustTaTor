use anyhow::{Context, Result};
use clap::Parser;
use reqwest::Proxy;
use serde::Deserialize;
use std::{time::Duration, net::TcpStream};
use tokio::time;
use tracing::{info, warn, error};
use std::io::{Write, BufRead, BufReader};
use anyhow::{anyhow};
use std::fs;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use rand::Rng;
use hex;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Interval in seconds between IP switches
    #[arg(short, long, default_value_t = 60)]
    interval: u64,

    /// Tor SOCKS port
    #[arg(short = 's', long, default_value_t = 9052)]
    port: u16,

    /// Tor control port
    #[arg(short = 'c', long, default_value_t = 9063)]
    control_port: u16,

    /// Tor control password (hashed)
    #[arg(short = 'p', long)]
    password: Option<String>,
}

#[derive(Debug, Deserialize)]
struct IpInfo {
    ip: String,
}

#[derive(Debug, Deserialize)]
struct GeoInfo {
    country_name: Option<String>,
    country_code: Option<String>,
    city: Option<String>,
    #[allow(dead_code)]
    region: Option<String>,
}

#[derive(Debug)]
struct Circuit {
    id: String,
    status: String,
    path: Vec<String>,
    purpose: String,
}

struct TorControl {
    stream: TcpStream,
    reader: BufReader<TcpStream>,
}

impl TorControl {
    fn new(control_port: u16) -> Result<Self> {
        let stream = TcpStream::connect(format!("127.0.0.1:{}", control_port))
            .context("Failed to connect to Tor control port")?;
        let reader = BufReader::new(stream.try_clone()?);
        Ok(Self { stream, reader })
    }

    fn get_protocol_info(&mut self) -> Result<Vec<String>> {
        self.send_command("PROTOCOLINFO")?;
        self.read_response()
    }

    fn authenticate(&mut self, _password: Option<String>) -> Result<()> {
        // First get protocol info
        let proto_info = self.get_protocol_info()?;
        info!("Protocol info response: {:?}", proto_info);

        // Parse authentication methods from PROTOCOLINFO response
        let mut methods = Vec::new();
        let mut cookie_file = None;
        
        for line in &proto_info {
            if line.contains("AUTH METHODS=") {
                if let Some(methods_str) = line.split("METHODS=").nth(1) {
                    methods = methods_str
                        .split(',')
                        .map(|s| s.trim().trim_matches(|c| c == '"' || c == ' '))
                        .collect();
                }
                if line.contains("COOKIEFILE=") {
                    if let Some(file) = line.split("COOKIEFILE=\"").nth(1) {
                        cookie_file = Some(file.trim_end_matches('"').to_string());
                    }
                }
            }
        }

        info!("Supported auth methods: {:?}", methods);
        if let Some(file) = &cookie_file {
            info!("Cookie file: {}", file);
        }

        // Try COOKIE authentication first
        if let Some(cookie_path) = cookie_file.clone() {
            if methods.contains(&"COOKIE") {
                info!("Attempting COOKIE authentication");
                
                // Read the cookie file
                let cookie_data = match fs::read(&cookie_path) {
                    Ok(data) => {
                        info!("Successfully read cookie file, length: {}", data.len());
                        info!("Cookie data (hex): {}", hex::encode(&data));
                        data
                    }
                    Err(e) => {
                        warn!("Failed to read cookie file: {}", e);
                        return Err(anyhow!("Failed to read cookie file: {}", e));
                    }
                };

                // Send the authentication command with the cookie data
                let auth_cmd = format!(
                    "AUTHENTICATE {}",
                    hex::encode(&cookie_data).to_uppercase()
                );
                info!("Sending authentication command: {}", auth_cmd);
                self.send_command(&auth_cmd)?;
                let response = self.read_response()?;
                info!("Authentication response: {:?}", response);
                
                if response.iter().any(|line| line == "OK") {
                    info!("Successfully authenticated with COOKIE");
                    return Ok(());
                }
                warn!("COOKIE authentication failed, response: {:?}", response);
            }

            // Try SAFECOOKIE authentication if COOKIE failed
            if methods.contains(&"SAFECOOKIE") {
                info!("Attempting SAFECOOKIE authentication");
                
                // Read the cookie file
                let cookie_data = match fs::read(&cookie_path) {
                    Ok(data) => {
                        info!("Successfully read cookie file, length: {}", data.len());
                        info!("Cookie data (hex): {}", hex::encode(&data));
                        data
                    }
                    Err(e) => {
                        warn!("Failed to read cookie file: {}", e);
                        return Err(anyhow!("Failed to read cookie file: {}", e));
                    }
                };

                // Generate client nonce
                let mut client_nonce = vec![0u8; 32];
                rand::thread_rng().fill(&mut client_nonce[..]);
                let client_nonce_hex = hex::encode(&client_nonce).to_uppercase();
                info!("Generated client nonce (hex): {}", client_nonce_hex);

                // Send AUTHCHALLENGE command with our nonce
                let auth_cmd = format!("AUTHCHALLENGE SAFECOOKIE {}", client_nonce_hex);
                info!("Sending AUTHCHALLENGE command: {}", auth_cmd);
                self.send_command(&auth_cmd)?;
                let response = self.read_response()?;
                info!("AUTHCHALLENGE response: {:?}", response);
                
                // Parse the server hash and nonce from response
                let (server_hash, server_nonce) = match response.iter().find(|line| line.contains("SERVERHASH=")) {
                    Some(line) => {
                        info!("Found AUTHCHALLENGE line: {}", line);
                        let parts: Vec<&str> = line.split(' ').collect();
                        info!("Split parts: {:?}", parts);
                        
                        let server_hash = parts.iter()
                            .find(|p| p.starts_with("SERVERHASH="))
                            .and_then(|p| Some(&p[11..]))
                            .ok_or_else(|| anyhow!("Missing SERVERHASH in response"))?;
                            
                        let server_nonce = parts.iter()
                            .find(|p| p.starts_with("SERVERNONCE="))
                            .and_then(|p| Some(&p[12..]))
                            .ok_or_else(|| anyhow!("Missing SERVERNONCE in response"))?;
                            
                        info!("Server hash: {}", server_hash);
                        info!("Server nonce: {}", server_nonce);
                        
                        match (hex::decode(server_nonce), hex::decode(server_hash)) {
                            (Ok(nonce), Ok(hash)) => {
                                info!("Decoded server nonce length: {}", nonce.len());
                                info!("Decoded server hash length: {}", hash.len());
                                (hash, nonce)
                            }
                            _ => {
                                warn!("Failed to decode server nonce or hash");
                                return Err(anyhow!("Failed to decode server nonce or hash"));
                            }
                        }
                    }
                    None => {
                        warn!("Failed to get server nonce from AUTHCHALLENGE response");
                        return Err(anyhow!("Failed to get server nonce from AUTHCHALLENGE response"));
                    }
                };

                // Compute HMAC
                let mut auth_input = Vec::new();
                auth_input.extend_from_slice(&cookie_data);
                auth_input.extend_from_slice(&client_nonce);
                auth_input.extend_from_slice(&server_nonce);
                info!("Auth input length: {}", auth_input.len());
                info!("Auth input (hex): {}", hex::encode(&auth_input).to_uppercase());

                let mut mac = match Hmac::<Sha256>::new_from_slice(b"Tor safe cookie authentication server-to-controller hash") {
                    Ok(mac) => mac,
                    Err(e) => {
                        warn!("Failed to create HMAC: {}", e);
                        return Err(anyhow!("Failed to create HMAC: {}", e));
                    }
                };
                mac.update(&auth_input);
                let computed_server_hash = mac.finalize().into_bytes();
                info!("Computed server hash (hex): {}", hex::encode(&computed_server_hash).to_uppercase());
                info!("Received server hash (hex): {}", hex::encode(&server_hash).to_uppercase());

                // Verify server hash
                if computed_server_hash.as_slice() != server_hash {
                    warn!("Server hash verification failed");
                    return Err(anyhow!("Server hash verification failed"));
                }
                info!("Server hash verified successfully");

                // Compute client hash
                let mut mac = match Hmac::<Sha256>::new_from_slice(b"Tor safe cookie authentication controller-to-server hash") {
                    Ok(mac) => mac,
                    Err(e) => {
                        warn!("Failed to create HMAC: {}", e);
                        return Err(anyhow!("Failed to create HMAC: {}", e));
                    }
                };
                mac.update(&auth_input);
                let client_hash = mac.finalize().into_bytes();
                info!("Client hash (hex): {}", hex::encode(&client_hash).to_uppercase());

                // Send the authentication command
                let auth_cmd = format!(
                    "AUTHENTICATE {}",
                    hex::encode(client_hash).to_uppercase()
                );
                info!("Sending authentication command: {}", auth_cmd);
                self.send_command(&auth_cmd)?;
                let response = self.read_response()?;
                info!("Authentication response: {:?}", response);
                
                if response.iter().any(|line| line == "OK") {
                    info!("Successfully authenticated with SAFECOOKIE");
                    return Ok(());
                }
                warn!("SAFECOOKIE authentication failed, response: {:?}", response);
            }
        }

        // Try null authentication as last resort
        if methods.contains(&"NULL") || methods.is_empty() {
            info!("Attempting null authentication");
            self.send_command("AUTHENTICATE")?;
            let response = self.read_response()?;
            if response.iter().any(|line| line == "OK") {
                info!("Successfully authenticated with null authentication");
                return Ok(());
            }
        }

        Err(anyhow!("Failed to authenticate with Tor control port"))
    }

    fn send_command(&mut self, cmd: &str) -> Result<()> {
        self.stream.write_all(format!("{}\r\n", cmd).as_bytes())?;
        Ok(())
    }

    fn read_response(&mut self) -> Result<Vec<String>> {
        let mut response = Vec::new();
        let mut line = String::new();
        let mut is_data = false;
        
        loop {
            line.clear();
            self.reader.read_line(&mut line)?;
            let trimmed = line.trim();
            info!("Raw response line: {}", trimmed);
            
            if trimmed.starts_with("250+") {
                is_data = true;
                response.push(trimmed[4..].to_string());
            } else if trimmed.starts_with("250-") {
                response.push(trimmed[4..].to_string());
            } else if trimmed.starts_with("250 ") {
                response.push(trimmed[4..].to_string());
                break;
            } else if trimmed.starts_with("515 ") || trimmed.starts_with("551 ") || trimmed.starts_with("550 ") {
                return Err(anyhow::anyhow!("Tor control error: {}", trimmed));
            } else if is_data && !trimmed.is_empty() {
                response.push(trimmed.to_string());
            } else if trimmed.starts_with("AUTHCHALLENGE ") {
                response.push(trimmed.to_string());
            }
        }
        
        Ok(response)
    }

    fn get_circuit_info(&mut self) -> Result<Vec<Circuit>> {
        self.send_command("GETINFO circuit-status")?;
        let response = self.read_response()?;
        
        let mut circuits = Vec::new();
        for line in response {
            if line.starts_with("circuit-status=") {
                continue;
            }
            
            // Parse circuit information
            let mut parts = line.split_whitespace();
            let id = parts.next().unwrap_or("").to_string();
            let status = parts.next().unwrap_or("").to_string();
            
            if let Some(path_str) = parts.next() {
                let path: Vec<String> = path_str.split(',')
                    .map(|s| {
                        if let Some(idx) = s.find('~') {
                            s[1..idx].to_string()
                        } else {
                            s[1..].to_string()
                        }
                    })
                    .collect();
                
                let purpose = parts.find(|p| p.starts_with("PURPOSE="))
                    .map(|p| p.replace("PURPOSE=", ""))
                    .unwrap_or_else(|| "UNKNOWN".to_string());
                
                circuits.push(Circuit {
                    id,
                    status,
                    path,
                    purpose,
                });
            }
        }
        
        Ok(circuits)
    }

    async fn switch_identity(&mut self) -> Result<()> {
        // Close all circuits first
        self.send_command("SIGNAL CLEARDNSCACHE")?;
        self.read_response()?;
        
        // Request new identity
        self.send_command("SIGNAL NEWNYM")?;
        self.read_response()?;

        // Wait for the new circuit to be established
        time::sleep(Duration::from_secs(10)).await;
        Ok(())
    }

    fn get_node_info(&mut self, node_id: &str) -> Result<(String, String)> {
        self.send_command(&format!("GETINFO ns/id/{}", node_id))?;
        let response = self.read_response()?;
        
        for line in response {
            if line.contains("r ") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() > 3 {
                    // Return (nickname, country)
                    return Ok((parts[1].to_string(), parts[3].to_string()));
                }
            }
        }
        
        Ok((node_id[..6].to_string(), "??".to_string()))
    }

    async fn wait_for_circuits(&mut self) -> Result<()> {
        for _ in 0..30 {
            let circuits = self.get_circuit_info()?;
            if circuits.iter().any(|c| c.status == "BUILT" && c.purpose.contains("GENERAL")) {
                return Ok(());
            }
            time::sleep(Duration::from_secs(1)).await;
        }
        Err(anyhow::anyhow!("Timeout waiting for circuits to be built"))
    }
}

#[derive(Debug, Deserialize)]
struct TorCheckResponse {
    #[serde(rename = "IsTor")]
    is_tor: bool,
}

async fn verify_tor_connection(client: &reqwest::Client) -> Result<bool> {
    info!("Attempting to get IP through proxy...");
    // First try to get our IP through the proxy
    let ip_response = match client
        .get("https://api.ipify.org?format=json")
        .timeout(Duration::from_secs(10))
        .send()
        .await {
            Ok(resp) => {
                info!("Successfully connected to IP service");
                resp
            },
            Err(e) => {
                warn!("Failed to connect to IP service: {}", e);
                return Err(anyhow!("Failed to connect to IP service: {}", e));
            }
        };

    let _ip_text = match ip_response.text().await {
        Ok(text) => {
            info!("Successfully got IP response: {}", text);
            text
        },
        Err(e) => {
            warn!("Failed to get IP response text: {}", e);
            return Err(anyhow!("Failed to get IP response text: {}", e));
        }
    };

    info!("Verifying if IP is a Tor exit node...");
    // Then verify if it's a Tor exit node
    let tor_check = match client
        .get("https://check.torproject.org/api/ip")
        .timeout(Duration::from_secs(10))
        .send()
        .await {
            Ok(resp) => {
                info!("Successfully connected to Tor check service");
                resp
            },
            Err(e) => {
                warn!("Failed to connect to Tor check service: {}", e);
                return Err(anyhow!("Failed to connect to Tor check service: {}", e));
            }
        };

    match tor_check.json::<TorCheckResponse>().await {
        Ok(response) => {
            if response.is_tor {
                info!("✓ Successfully verified Tor connection");
                Ok(true)
            } else {
                warn!("Connection is not using Tor");
                Ok(false)
            }
        }
        Err(e) => {
            warn!("Failed to parse Tor check response: {}", e);
            Ok(false)
        }
    }
}

async fn get_ip_info(client: &reqwest::Client) -> Result<(String, Option<GeoInfo>, bool)> {
    // First get the IP address
    let ip_info = client
        .get("https://api.ipify.org?format=json")
        .send()
        .await?
        .json::<IpInfo>()
        .await?;

    // Check if it's a Tor exit node
    let is_tor = verify_tor_connection(client).await?;

    // Then try to get location info
    let geo_info = match client
        .get(&format!("https://ipapi.co/{}/json/", ip_info.ip))
        .send()
        .await
    {
        Ok(response) => match response.json::<GeoInfo>().await {
            Ok(info) => Some(info),
            Err(e) => {
                warn!("Failed to parse location info: {}", e);
                None
            }
        },
        Err(e) => {
            warn!("Failed to fetch location info: {}", e);
            None
        }
    };

    Ok((ip_info.ip, geo_info, is_tor))
}

async fn verify_tor_proxy(port: u16) -> Result<bool> {
    // Try to connect to the SOCKS proxy first
    match TcpStream::connect(format!("127.0.0.1:{}", port)) {
        Ok(_) => {
            info!("✓ Successfully connected to Tor SOCKS proxy on port {}", port);
            Ok(true)
        }
        Err(e) => {
            error!("❌ Failed to connect to Tor SOCKS proxy: {}", e);
            error!("Please make sure Tor is running and the SOCKS port {} is correct", port);
            Ok(false)
        }
    }
}

async fn create_tor_client(port: u16) -> Result<reqwest::Client> {
    let proxy_url = format!("socks5://127.0.0.1:{}", port);
    info!("Creating Tor client with proxy: {}", proxy_url);
    
    let proxy = Proxy::all(&proxy_url)
        .context("Failed to create proxy configuration")?;
    info!("Successfully created proxy configuration");
    
    let client = reqwest::Client::builder()
        .proxy(proxy)
        .timeout(Duration::from_secs(30))
        .danger_accept_invalid_certs(true)
        .build()
        .context("Failed to build client")?;
    info!("Successfully built client with proxy configuration");

    // Verify Tor connection
    info!("Verifying Tor connection...");
    let mut retries = 3;
    while retries > 0 {
        match verify_tor_connection(&client).await {
            Ok(true) => {
                info!("✓ Successfully connected to Tor network");
                return Ok(client);
            }
            Ok(false) => {
                warn!("Attempt {} failed: Connection is not using Tor", 4 - retries);
                retries -= 1;
                if retries > 0 {
                    info!("Waiting 10 seconds before retry...");
                    time::sleep(Duration::from_secs(10)).await;
                }
            }
            Err(e) => {
                warn!("Attempt {} failed: {}", 4 - retries, e);
                retries -= 1;
                if retries > 0 {
                    info!("Waiting 10 seconds before retry...");
                    time::sleep(Duration::from_secs(10)).await;
                }
            }
        }
    }

    Err(anyhow::anyhow!("Failed to establish Tor connection"))
}

fn format_location(geo: &GeoInfo) -> String {
    let country = geo.country_name
        .as_ref()
        .or(geo.country_code.as_ref())
        .map(|s| s.as_str())
        .unwrap_or("Unknown");
    
    let city = geo.city
        .as_ref()
        .map(|s| s.as_str())
        .unwrap_or("Unknown");
    
    format!("{}, {}", city, country)
}

fn format_circuit_path(_circuit: &Circuit, nodes: &[(String, String)]) -> String {
    let mut path = String::new();
    for (i, (name, country)) in nodes.iter().enumerate() {
        if i > 0 {
            path.push_str(" → ");
        }
        path.push_str(&format!("{} [{}]", name, country));
    }
    path
}

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt::init();

    println!("\x1b[31m{}\x1b[0m", r#"
██████╗ ██╗   ██╗███████╗████████╗████████╗ █████╗ ████████╗ ██████╗ ██████╗ 
██╔══██╗██║   ██║██╔════╝╚══██╔══╝╚══██╔══╝██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗
██████╔╝██║   ██║███████╗   ██║      ██║   ███████║   ██║   ██║   ██║██████╔╝
██╔══██╗██║   ██║╚════██║   ██║      ██║   ██╔══██║   ██║   ██║   ██║██╔══██╗
██║  ██║╚██████╔╝███████║   ██║      ██║   ██║  ██║   ██║   ╚██████╔╝██║  ██║
╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝      ╚═╝   ╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝
    "#);
    println!("\x1b[33m{}\x1b[0m", "Anonymous Internet Access Through Tor");
    println!("\x1b[32m{}\x1b[0m", "Version 0.1.0");
    println!();

    let args = Args::parse();
    
    // Verify Tor SOCKS proxy is accessible
    info!("Verifying Tor SOCKS proxy connection...");
    if !verify_tor_proxy(args.port).await? {
        return Err(anyhow::anyhow!("Cannot proceed without Tor SOCKS proxy connection"));
    }
    
    // Initialize Tor control connection
    info!("Connecting to Tor control port...");
    let mut tor_control = TorControl::new(args.control_port)
        .context("Failed to connect to Tor control port")?;
    
    // Authenticate with Tor control port
    info!("Authenticating with Tor control port...");
    tor_control.authenticate(args.password.clone())
        .context("Failed to authenticate with Tor control port")?;
    
    // Get original IP without Tor
    info!("Checking original IP...");
    let regular_client = reqwest::Client::new();
    match get_ip_info(&regular_client).await {
        Ok((ip, geo_info, is_tor)) => {
            match geo_info {
                Some(geo) => {
                    info!(
                        "Original IP: {} ({}) [{}]",
                        ip,
                        format_location(&geo),
                        if is_tor { "Tor" } else { "Direct" }
                    );
                }
                None => {
                    info!("Original IP: {} (Location unavailable) [{}]", 
                        ip,
                        if is_tor { "Tor" } else { "Direct" }
                    );
                }
            }
        }
        Err(e) => {
            warn!("Failed to get original IP: {}", e);
        }
    }

    // Create initial Tor client
    info!("Initializing Tor client...");
    let mut tor_client = create_tor_client(args.port).await?;
    info!("✓ Tor client initialized successfully");

    // Wait for circuits to be built
    info!("Waiting for Tor circuits to be established...");
    if let Err(e) = tor_control.wait_for_circuits().await {
        error!("Failed to establish Tor circuits: {}", e);
        return Err(e);
    }
    info!("✓ Tor circuits established successfully");
    
    loop {
        // Get circuit information
        match tor_control.get_circuit_info() {
            Ok(circuits) => {
                let built_circuits: Vec<_> = circuits.iter()
                    .filter(|c| c.status == "BUILT" && c.purpose.contains("GENERAL"))
                    .collect();

                if !built_circuits.is_empty() {
                    info!("🌐 Active Tor Circuits:");
                    for circuit in built_circuits {
                        let mut node_info = Vec::new();
                        for node in &circuit.path {
                            match tor_control.get_node_info(node) {
                                Ok((name, country)) => node_info.push((name, country)),
                                Err(_) => node_info.push((node[..6].to_string(), "??".to_string())),
                            }
                        }
                        
                        info!("  └─ Circuit #{}", circuit.id);
                        info!("     {}", format_circuit_path(circuit, &node_info));
                    }
                } else {
                    warn!("No active Tor circuits found!");
                }
            }
            Err(e) => warn!("Failed to get circuit info: {}", e),
        }

        // Get current IP through Tor
        match get_ip_info(&tor_client).await {
            Ok((ip, geo_info, is_tor)) => {
                match geo_info {
                    Some(geo) => {
                        info!(
                            "Current IP: {} ({}) [{}]",
                            ip,
                            format_location(&geo),
                            if is_tor { "✓ Tor" } else { "⚠ Direct" }
                        );
                    }
                    None => {
                        info!(
                            "Current IP: {} (Location unavailable) [{}]",
                            ip,
                            if is_tor { "✓ Tor" } else { "⚠ Direct" }
                        );
                    }
                }
            }
            Err(e) => {
                warn!("Failed to get IP info: {}", e);
            }
        }

        // Switch identity
        info!("🔄 Switching Tor identity...");
        if let Err(e) = tor_control.switch_identity().await {
            warn!("Failed to switch identity: {}", e);
        } else {
            info!("Identity switch requested, establishing new circuit...");
            
            // Wait for new circuits to be built
            if let Err(e) = tor_control.wait_for_circuits().await {
                warn!("Failed to establish new circuits: {}", e);
                continue;
            }
            
            // Create a new Tor client to force using the new circuit
            match create_tor_client(args.port).await {
                Ok(new_client) => {
                    tor_client = new_client;
                    info!("✓ New Tor circuit established");
                }
                Err(e) => warn!("Failed to create new Tor client: {}", e),
            }
        }

        // Wait for the specified interval
        time::sleep(Duration::from_secs(args.interval)).await;
    }
}
