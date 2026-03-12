// ============================================================================
//  Morse-Pi — Peer-to-peer networking via UDP beacons.
// ============================================================================
use crate::state;
use std::io::{Read, Write};
use std::net::{SocketAddr, UdpSocket, TcpStream};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

pub const BEACON_PORT: u16 = 5001;

static DEVICE_UUID: once_cell::sync::Lazy<String> = once_cell::sync::Lazy::new(|| {
    uuid::Uuid::new_v4().to_string()
});

#[derive(Debug, Clone)]
pub struct Peer {
    pub uuid: String,
    pub name: String,
    pub ip: String,
    pub port: u16,
    pub last_seen: i64,
}

static PEERS: once_cell::sync::Lazy<Mutex<Vec<Peer>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(Vec::new()));

static CACHED_LOCAL_IP: once_cell::sync::Lazy<Mutex<(String, i64)>> =
    once_cell::sync::Lazy::new(|| Mutex::new(("127.0.0.1".into(), 0)));

pub fn device_uuid() -> &'static str {
    &DEVICE_UUID
}

pub fn get_local_ip() -> String {
    let now = current_millis();
    {
        let cache = CACHED_LOCAL_IP.lock().unwrap();
        if !cache.0.is_empty() && now - cache.1 < 10000 {
            return cache.0.clone();
        }
    }

    // Try to find local IP by connecting to an external address
    let ip = match UdpSocket::bind("0.0.0.0:0") {
        Ok(sock) => {
            match sock.connect("8.8.8.8:80") {
                Ok(_) => sock
                    .local_addr()
                    .map(|a| a.ip().to_string())
                    .unwrap_or_else(|_| "127.0.0.1".into()),
                Err(_) => "127.0.0.1".into(),
            }
        }
        Err(_) => "127.0.0.1".into(),
    };

    let mut cache = CACHED_LOCAL_IP.lock().unwrap();
    cache.0 = ip.clone();
    cache.1 = now;
    ip
}

fn current_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Start beacon sender & listener threads.
pub fn start_beacons() {
    // Force UUID initialization
    let _ = device_uuid();
    thread::spawn(beacon_sender);
    thread::spawn(beacon_listener);
}

fn beacon_sender() {
    let sock = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(_) => return,
    };
    let _ = sock.set_broadcast(true);
    let broadcast_addr: SocketAddr = format!("255.255.255.255:{}", BEACON_PORT)
        .parse()
        .unwrap();

    loop {
        let ip = get_local_ip();
        let device_name = state::STATE.lock().unwrap().settings.device_name.clone();
        let pkt = format!(
            r#"{{"type":"morse_pi_beacon","uuid":"{}","name":"{}","ip":"{}","port":5000}}"#,
            device_uuid(),
            device_name,
            ip,
        );
        let _ = sock.send_to(pkt.as_bytes(), broadcast_addr);
        thread::sleep(Duration::from_secs(3));
    }
}

fn beacon_listener() {
    loop {
        let sock = match UdpSocket::bind(format!("0.0.0.0:{}", BEACON_PORT)) {
            Ok(s) => s,
            Err(_) => {
                thread::sleep(Duration::from_secs(5));
                continue;
            }
        };
        let _ = sock.set_read_timeout(Some(Duration::from_secs(2)));

        loop {
            let mut buf = [0u8; 2048];
            match sock.recv_from(&mut buf) {
                Ok((n, _)) => {
                    process_beacon(&buf[..n]);
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    expire_peers();
                }
                Err(_) => break,
            }
        }
    }
}

fn process_beacon(data: &[u8]) {
    let text = match std::str::from_utf8(data) {
        Ok(s) => s,
        Err(_) => return,
    };
    let uuid_str = match extract_json_string(text, "uuid") {
        Some(s) => s,
        None => return,
    };
    if uuid_str == device_uuid() { return; } // skip self

    let type_str = match extract_json_string(text, "type") {
        Some(s) => s,
        None => return,
    };
    if type_str != "morse_pi_beacon" { return; }

    let name_str = extract_json_string(text, "name").unwrap_or_else(|| "Unknown".into());
    let ip_str = extract_json_string(text, "ip").unwrap_or_else(|| "0.0.0.0".into());

    let mut peers = PEERS.lock().unwrap();

    // Update existing or add new
    if let Some(peer) = peers.iter_mut().find(|p| p.uuid == uuid_str) {
        peer.name = name_str;
        peer.ip = ip_str;
        peer.last_seen = current_millis();
        return;
    }

    if peers.len() < 32 {
        peers.push(Peer {
            uuid: uuid_str,
            name: name_str,
            ip: ip_str,
            port: 5000,
            last_seen: current_millis(),
        });
    }
}

fn expire_peers() {
    let now = current_millis();
    let mut peers = PEERS.lock().unwrap();
    peers.retain(|p| now - p.last_seen <= 15000);
}

fn extract_json_string(data: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\":\"", key);
    let idx = data.find(&needle)?;
    let start = idx + needle.len();
    let rest = &data[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

/// Write peers list as JSON.
pub fn peers_json() -> String {
    let now = current_millis();
    let ip = get_local_ip();
    let device_name = state::STATE.lock().unwrap().settings.device_name.clone();
    let peers = PEERS.lock().unwrap();

    let peer_entries: Vec<String> = peers.iter().map(|p| {
        let ago = (now - p.last_seen) as f64 / 1000.0;
        format!(
            r#"{{"uuid":"{}","name":"{}","ip":"{}","port":{},"last_seen_ago":{:.1}}}"#,
            state::escape_json(&p.uuid),
            state::escape_json(&p.name),
            state::escape_json(&p.ip),
            p.port,
            ago,
        )
    }).collect();

    format!(
        r#"{{"self":{{"uuid":"{}","name":"{}","ip":"{}","port":5000}},"peers":[{}]}}"#,
        state::escape_json(device_uuid()),
        state::escape_json(&device_name),
        state::escape_json(&ip),
        peer_entries.join(","),
    )
}

/// Send an HTTP POST to a peer.
pub fn send_to_peer_http(ip: &str, port: u16, payload: &str) -> Result<(), String> {
    let addr: SocketAddr = format!("{}:{}", ip, port)
        .parse()
        .map_err(|_| "invalid address".to_string())?;

    for attempt in 0..3u32 {
        match TcpStream::connect_timeout(&addr, Duration::from_secs(3)) {
            Ok(mut stream) => {
                let http_req = format!(
                    "POST /receive_morse HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    ip, payload.len(), payload,
                );
                if stream.write_all(http_req.as_bytes()).is_ok() {
                    return Ok(());
                }
            }
            Err(_) => {
                if attempt < 2 {
                    thread::sleep(Duration::from_millis((attempt as u64 + 1) * 300));
                }
            }
        }
    }
    Err("connection failed".into())
}
