// Minimal HTTP/1.1 healthcheck for the xberg API server's `GET /health`
// route. Deliberately dependency-free (std only) so it compiles with a
// single `rustc` invocation and can be copied into the distroless
// `ultralight` image, which has no shell and no curl/wget to exec instead
// (`ultralight`'s Dockerfile). `ocrlight` uses the same binary for
// consistency, even though its Debian base could run curl.
//
// Usage: xberg-healthcheck [host:port] [path]
//   Defaults to 127.0.0.1:8000 /health -- loopback always reaches this same
//   container's server regardless of the `host` xberg itself is configured
//   to bind (see docker/mount_config/*.toml [server].host).
//
// Exits 0 on any 2xx response status, 1 otherwise (connection failure,
// timeout, non-2xx status, or a malformed response), printing a one-line
// reason to stderr so `docker logs`/`docker inspect` show why.

use std::env;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::exit;
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(3);
// Only the status line matters; cap how much of the response we read so a
// slow or unexpectedly large /health payload can't stall the healthcheck.
const MAX_RESPONSE_PREFIX: usize = 512;

fn main() {
    let mut args = env::args().skip(1);
    let addr = args.next().unwrap_or_else(|| "127.0.0.1:8000".to_string());
    let path = args.next().unwrap_or_else(|| "/health".to_string());

    if let Err(err) = check(&addr, &path) {
        eprintln!("xberg-healthcheck: {addr}{path}: {err}");
        exit(1);
    }
}

fn check(addr: &str, path: &str) -> Result<(), String> {
    let mut stream = TcpStream::connect(addr).map_err(|e| format!("connect failed: {e}"))?;
    stream.set_read_timeout(Some(TIMEOUT)).ok();
    stream.set_write_timeout(Some(TIMEOUT)).ok();

    let request = format!("GET {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n\r\n");
    stream
        .write_all(request.as_bytes())
        .map_err(|e| format!("write failed: {e}"))?;

    let mut buf = [0u8; MAX_RESPONSE_PREFIX];
    let mut filled = 0;
    while filled < buf.len() {
        let n = stream
            .read(&mut buf[filled..])
            .map_err(|e| format!("read failed: {e}"))?;
        if n == 0 {
            break;
        }
        filled += n;
        if buf[..filled].windows(2).any(|w| w == b"\r\n") {
            break;
        }
    }

    let status_line = buf[..filled]
        .split(|&b| b == b'\n')
        .next()
        .ok_or("empty response")?;
    let status_line = String::from_utf8_lossy(status_line);

    // "HTTP/1.1 200 OK\r" -- accept any 2xx status code.
    let ok = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok())
        .is_some_and(|code| (200..300).contains(&code));

    if ok {
        Ok(())
    } else {
        Err(format!("unexpected response: {}", status_line.trim()))
    }
}
