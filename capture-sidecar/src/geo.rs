//! Local IP intelligence — geolocation + ASN/owner, resolved entirely against
//! bundled MaxMind-format databases (DB-IP City Lite + ASN Lite, CC-BY). NO
//! network calls: a privacy browser must never leak the IPs you're connected to
//! to a geo/OSINT API just to draw a map. External OSINT (WHOIS, reverse-IP)
//! is a separate, user-initiated, gated action — see server::whois.

use maxminddb::{geoip2, Reader};
use std::net::IpAddr;
use std::path::Path;

/// What we can say about a remote IP without touching the network.
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct GeoInfo {
    pub lat: Option<f64>,
    pub lon: Option<f64>,
    pub country: Option<String>,
    #[serde(rename = "countryCode")]
    pub country_code: Option<String>,
    pub city: Option<String>,
    pub asn: Option<u32>,
    /// Autonomous-system organization — the "who owns the block" at routing level.
    pub org: Option<String>,
}

pub struct Geo {
    city: Option<Reader<Vec<u8>>>,
    asn: Option<Reader<Vec<u8>>>,
}

impl Geo {
    /// Load whatever DBs are present in `dir`. Missing DBs degrade gracefully —
    /// the map simply shows fewer facts, never an error.
    pub fn load(dir: &Path) -> Geo {
        let city = Reader::open_readfile(dir.join("dbip-city-lite.mmdb")).ok();
        let asn = Reader::open_readfile(dir.join("dbip-asn-lite.mmdb")).ok();
        if city.is_none() {
            tracing::info!("no city GeoIP DB in {} — map dots disabled", dir.display());
        }
        Geo { city, asn }
    }

    pub fn available(&self) -> bool {
        self.city.is_some() || self.asn.is_some()
    }

    pub fn lookup(&self, ip: &str) -> GeoInfo {
        let mut info = GeoInfo::default();
        let addr: IpAddr = match ip.parse() {
            Ok(a) => a,
            Err(_) => return info,
        };
        if let Some(r) = &self.city {
            if let Ok(c) = r.lookup::<geoip2::City>(addr) {
                if let Some(loc) = c.location {
                    info.lat = loc.latitude;
                    info.lon = loc.longitude;
                }
                if let Some(country) = c.country {
                    info.country_code = country.iso_code.map(|s| s.to_string());
                    info.country = country
                        .names
                        .and_then(|n| n.get("en").map(|s| s.to_string()));
                }
                info.city = c
                    .city
                    .and_then(|ci| ci.names)
                    .and_then(|n| n.get("en").map(|s| s.to_string()));
            }
        }
        if let Some(r) = &self.asn {
            if let Ok(a) = r.lookup::<geoip2::Asn>(addr) {
                info.asn = a.autonomous_system_number;
                info.org = a
                    .autonomous_system_organization
                    .map(|s| s.to_string());
            }
        }
        info
    }
}
