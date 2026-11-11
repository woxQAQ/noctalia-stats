use serde_json::{Map, Value, json};
use std::{
    collections::BTreeMap,
    env,
    ffi::CStr,
    fs,
    io::{self, BufWriter, Write},
    net::{Ipv4Addr, Ipv6Addr},
    path::Path,
    ptr,
    time::Instant,
};

fn monotonic_seconds() -> io::Result<f64> {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: time is a valid writable timespec and CLOCK_MONOTONIC is supported on Linux.
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut time) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(time.tv_sec as f64 + time.tv_nsec as f64 / 1_000_000_000.0)
}

fn processes(proc_root: &Path, include_io: bool) -> io::Result<Value> {
    let started = Instant::now();
    let sampled_at = monotonic_seconds()?;
    // SAFETY: sysconf takes no pointers; positive results are checked before use.
    let (hz, pages) = unsafe {
        (
            libc::sysconf(libc::_SC_CLK_TCK),
            libc::sysconf(libc::_SC_PAGESIZE),
        )
    };
    if hz <= 0 || pages <= 0 {
        return Err(io::Error::other("sysconf failed"));
    }
    let mut rows = Vec::new();
    let (mut denied, mut io_denied) = (0, 0);
    for entry in fs::read_dir(proc_root)?.flatten() {
        let pid = match entry.file_name().to_string_lossy().parse::<u32>() {
            Ok(pid) => pid,
            Err(_) => continue,
        };
        let raw = match fs::read(entry.path().join("stat")) {
            Ok(raw) => raw,
            Err(error) => {
                if error.kind() == io::ErrorKind::PermissionDenied {
                    denied += 1;
                }
                continue;
            }
        };
        let text = String::from_utf8_lossy(&raw);
        let (Some(left), Some(right)) = (text.find('('), text.rfind(')')) else {
            continue;
        };
        if right <= left {
            continue;
        }
        let fields: Vec<_> = text[right + 1..].split_whitespace().collect();
        if fields.len() < 22 {
            continue;
        }
        let (Ok(user), Ok(system), Ok(rss)) = (
            fields[11].parse::<u64>(),
            fields[12].parse::<u64>(),
            fields[21].parse::<i64>(),
        ) else {
            continue;
        };
        let mut row = json!({
            "pid": pid,
            "name": &text[left + 1..right],
            "start": fields[19],
            "cpuSeconds": (user as f64 + system as f64) / hz as f64,
            "rssBytes": (rss.max(0) as u64).saturating_mul(pages as u64),
        });
        if include_io {
            match fs::read_to_string(entry.path().join("io")) {
                Ok(io) => {
                    for line in io.lines() {
                        let Some((key, value)) = line.split_once(':') else {
                            continue;
                        };
                        let output = match key {
                            "read_bytes" => "readBytes",
                            "write_bytes" => "writeBytes",
                            _ => continue,
                        };
                        if let Ok(value) = value.trim().parse::<u64>() {
                            row[output] = json!(value);
                        }
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::PermissionDenied => io_denied += 1,
                Err(_) => {}
            }
        }
        rows.push(row);
    }
    Ok(json!({
        "version": 1, "sampledAt": sampled_at, "scanMs": started.elapsed().as_secs_f64() * 1000.0,
        "denied": denied, "ioDenied": io_denied, "processes": rows,
    }))
}

struct InterfaceList(*mut libc::ifaddrs);
impl Drop for InterfaceList {
    fn drop(&mut self) {
        // SAFETY: the list came from getifaddrs and is freed exactly once.
        unsafe { libc::freeifaddrs(self.0) };
    }
}

fn network(proc_root: &Path) -> io::Result<Value> {
    let mut raw = ptr::null_mut();
    // SAFETY: raw is a valid output pointer; the returned list is owned by InterfaceList.
    if unsafe { libc::getifaddrs(&mut raw) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let list = InterfaceList(raw);
    let mut ipv4: BTreeMap<String, Vec<Ipv4Addr>> = BTreeMap::new();
    let mut cursor = list.0;
    while !cursor.is_null() {
        // SAFETY: each node and its optional sockaddr belong to the live getifaddrs list.
        unsafe {
            let entry = &*cursor;
            if !entry.ifa_name.is_null()
                && !entry.ifa_addr.is_null()
                && (*entry.ifa_addr).sa_family as i32 == libc::AF_INET
            {
                let name = CStr::from_ptr(entry.ifa_name)
                    .to_string_lossy()
                    .into_owned();
                let address = &*(entry.ifa_addr as *const libc::sockaddr_in);
                let address = Ipv4Addr::from(address.sin_addr.s_addr.to_ne_bytes());
                if !address.is_loopback() && !address.is_unspecified() {
                    ipv4.entry(name).or_default().push(address);
                }
            }
            cursor = entry.ifa_next;
        }
    }
    let mut ipv6: BTreeMap<String, Vec<(bool, Ipv6Addr)>> = BTreeMap::new();
    if let Ok(text) = fs::read_to_string(proc_root.join("net/if_inet6")) {
        for line in text.lines() {
            let fields: Vec<_> = line.split_whitespace().collect();
            if fields.len() != 6 || fields[0].len() != 32 || fields[3] != "00" {
                continue;
            }
            let (Ok(bits), Ok(flags)) = (
                u128::from_str_radix(fields[0], 16),
                u32::from_str_radix(fields[4], 16),
            ) else {
                continue;
            };
            // Tentative, deprecated and failed addresses are not useful display candidates.
            if flags & (0x40 | 0x20 | 0x08) != 0 {
                continue;
            }
            let address = Ipv6Addr::from(bits);
            if address.is_loopback() || address.is_unspecified() || address.is_multicast() {
                continue;
            }
            ipv6.entry(fields[5].into())
                .or_default()
                .push((flags & 1 != 0, address));
        }
    }
    let mut result: BTreeMap<String, Value> = BTreeMap::new();
    for (name, addresses) in &mut ipv4 {
        addresses.sort_by_key(|address| (address.is_link_local(), *address));
        if let Some(address) = addresses.first() {
            result.entry(name.clone()).or_insert_with(|| json!({}))["ipv4"] =
                json!(address.to_string());
        }
    }
    for (name, addresses) in &mut ipv6 {
        // Prefer one stable address; privacy addresses remain a fallback, not a list.
        addresses.sort();
        if let Some((_, address)) = addresses.first() {
            result.entry(name.clone()).or_insert_with(|| json!({}))["ipv6"] =
                json!(address.to_string());
        }
    }
    let interfaces: Map<String, Value> = result.into_iter().collect();
    Ok(json!({ "version": 1, "interfaces": interfaces }))
}

fn main() {
    let args: Vec<_> = env::args().skip(1).collect();
    let mut proc_root = Path::new("/proc");
    let mut include_io = false;
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--proc-root" if index + 1 < args.len() => {
                index += 1;
                proc_root = Path::new(&args[index]);
            }
            "--io" => include_io = true,
            _ => {
                eprintln!("unknown or incomplete argument: {}", args[index]);
                std::process::exit(2);
            }
        }
        index += 1;
    }
    let result = match args.first().map(String::as_str) {
        Some("processes") => processes(proc_root, include_io),
        Some("network") => network(proc_root),
        _ => {
            eprintln!(
                "usage: noctalia-stats-collector <processes [--io]|network> [--proc-root PATH]"
            );
            std::process::exit(2);
        }
    };
    match result {
        Ok(value) => {
            let mut out = BufWriter::new(io::stdout().lock());
            if serde_json::to_writer(&mut out, &value).is_err() || writeln!(out).is_err() {
                std::process::exit(1);
            }
        }
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
