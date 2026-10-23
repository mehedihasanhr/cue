//! "Copy Share Link": upload a capture to an S3-compatible bucket (AWS S3, Cloudflare R2,
//! MinIO, Backblaze B2…), signed here with SigV4, or to any HTTP endpoint that answers
//! with its link. A port of the Mac's `ShareUploader.swift`.

use crate::secrets;
use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use hmac::{Hmac, KeyInit, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ShareSettings {
    /// "off", "s3" or "custom".
    pub provider: String,
    pub endpoint: String,
    pub region: String,
    pub bucket: String,
    pub prefix: String,
    pub access_key: String,
    /// What goes before the key in the link ("https://cdn.example.com"); empty means the
    /// bucket's own URL.
    pub public_base: String,
    pub custom_url: String,
    /// "PUT" or "POST".
    pub custom_method: String,
    pub custom_header_name: String,
    /// For a JSON answer, where the link is ("url", "data.link"); empty: the body is the
    /// link, or the request URL when the body is empty.
    pub custom_response_key: String,
    /// Names uploads by their capture time; off, a short random name.
    pub dated_names: bool,
}

impl Default for ShareSettings {
    fn default() -> Self {
        Self {
            provider: "off".into(),
            endpoint: String::new(),
            region: "auto".into(),
            bucket: String::new(),
            prefix: "cue/".into(),
            access_key: String::new(),
            public_base: String::new(),
            custom_url: String::new(),
            custom_method: "PUT".into(),
            custom_header_name: "Authorization".into(),
            custom_response_key: String::new(),
            dated_names: true,
        }
    }
}

/// The object name for an upload.
pub fn object_name(settings: &ShareSettings, at: DateTime<Utc>) -> String {
    let random = uuid::Uuid::new_v4().simple().to_string();
    if settings.dated_names {
        format!("{}-{}.png", at.with_timezone(&chrono::Local).format("%Y-%m-%d-%H%M%S"), &random[..4])
    } else {
        format!("{}.png", &random[..10])
    }
}

/// Uploads `png` and returns its public link.
pub async fn upload(settings: &ShareSettings, png: Vec<u8>, name: &str) -> Result<String> {
    match settings.provider.as_str() {
        "s3" => upload_s3(settings, png, name).await,
        "custom" => upload_custom(settings, png, name).await,
        _ => bail!("Set up sharing in Settings › Sharing first."),
    }
}

// MARK: - S3, path style

async fn upload_s3(settings: &ShareSettings, png: Vec<u8>, name: &str) -> Result<String> {
    let secret = secrets::get("share.s3.secretKey").context("Add the bucket's secret key in Settings › Sharing.")?;
    anyhow::ensure!(!settings.bucket.is_empty() && !settings.access_key.is_empty(), "Finish setting up the bucket in Settings › Sharing.");
    let host = settings
        .endpoint
        .trim()
        .split("://")
        .last()
        .unwrap_or_default()
        .trim_matches('/')
        .to_string();
    anyhow::ensure!(!host.is_empty(), "The endpoint URL is not valid.");
    let key = format!("{}/{}", settings.prefix.trim_matches('/'), name).trim_matches('/').to_string();
    let path = format!("/{}/{}", settings.bucket, key);
    let region = if settings.region.is_empty() { "auto" } else { &settings.region };

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let payload_hash = hex::encode(Sha256::digest(&png));
    let headers: BTreeMap<String, String> = [
        ("content-type", "image/png".to_string()),
        ("host", host.clone()),
        ("x-amz-acl", "public-read".to_string()),
        ("x-amz-content-sha256", payload_hash.clone()),
        ("x-amz-date", amz_date.clone()),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    let authorization = sign(&SigningRequest {
        method: "PUT",
        path: &path,
        query: "",
        headers: &headers,
        payload_hash: &payload_hash,
        amz_date: &amz_date,
        region,
        service: "s3",
        access_key: &settings.access_key,
        secret_key: &secret,
    });

    let url = format!("https://{host}{}", uri_encode(&path, true));
    let mut request = reqwest::Client::new().put(&url).body(png);
    for (name, value) in &headers {
        if name != "host" {
            request = request.header(name, value);
        }
    }
    let response = request.header("Authorization", authorization).send().await.context("Could not reach the bucket")?;
    check(response).await?;

    let base = settings.public_base.trim().trim_end_matches('/');
    Ok(if base.is_empty() { url } else { format!("{base}/{key}") })
}

pub struct SigningRequest<'a> {
    pub method: &'a str,
    pub path: &'a str,
    pub query: &'a str,
    /// Lower-case names; every one is signed.
    pub headers: &'a BTreeMap<String, String>,
    pub payload_hash: &'a str,
    pub amz_date: &'a str,
    pub region: &'a str,
    pub service: &'a str,
    pub access_key: &'a str,
    pub secret_key: &'a str,
}

/// The `Authorization` header for an AWS Signature Version 4 request.
pub fn sign(request: &SigningRequest) -> String {
    let canonical_headers: String = request.headers.iter().map(|(k, v)| format!("{k}:{}\n", v.trim())).collect();
    let signed_headers = request.headers.keys().cloned().collect::<Vec<_>>().join(";");
    let canonical_request = [
        request.method,
        &uri_encode(request.path, true),
        request.query,
        &canonical_headers,
        &signed_headers,
        request.payload_hash,
    ]
    .join("\n");
    let date = &request.amz_date[..8];
    let scope = format!("{date}/{}/{}/aws4_request", request.region, request.service);
    let string_to_sign = format!(
        "AWS4-HMAC-SHA256\n{}\n{scope}\n{}",
        request.amz_date,
        hex::encode(Sha256::digest(canonical_request.as_bytes()))
    );
    let key = signing_key(request.secret_key, date, request.region, request.service);
    let signature = hex::encode(hmac(&key, &string_to_sign));
    format!(
        "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed_headers}, Signature={signature}",
        request.access_key
    )
}

pub fn signing_key(secret: &str, date: &str, region: &str, service: &str) -> Vec<u8> {
    let key = hmac(format!("AWS4{secret}").as_bytes(), date);
    let key = hmac(&key, region);
    let key = hmac(&key, service);
    hmac(&key, "aws4_request")
}

fn hmac(key: &[u8], message: &str) -> Vec<u8> {
    let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(key).expect("HMAC takes any key length");
    mac.update(message.as_bytes());
    mac.finalize().into_bytes().to_vec()
}

/// RFC 3986 encoding, as SigV4 wants it: unreserved characters kept, and `/` kept in paths.
fn uri_encode(value: &str, keep_slashes: bool) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            b'/' if keep_slashes => "/".to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

// MARK: - Custom endpoint

async fn upload_custom(settings: &ShareSettings, png: Vec<u8>, name: &str) -> Result<String> {
    let mut url = settings.custom_url.trim().to_string();
    anyhow::ensure!(url.starts_with("http://") || url.starts_with("https://"), "The endpoint URL is not valid.");
    let post = settings.custom_method.eq_ignore_ascii_case("POST");
    // "{name}" in the URL takes the file name; a PUT without it gets the name appended.
    if url.contains("{name}") {
        url = url.replace("{name}", name);
    } else if !post && !url.rsplit('/').next().unwrap_or_default().contains('.') {
        url = format!("{}/{name}", url.trim_end_matches('/'));
    }
    let client = reqwest::Client::new();
    let mut request = if post {
        let boundary = format!("cue-{}", uuid::Uuid::new_v4().simple());
        let mut form = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: image/png\r\n\r\n"
        )
        .into_bytes();
        form.extend_from_slice(&png);
        form.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
        client
            .post(&url)
            .header("Content-Type", format!("multipart/form-data; boundary={boundary}"))
            .body(form)
    } else {
        client.put(&url).header("Content-Type", "image/png").body(png)
    };
    if let Some(value) = secrets::get("share.custom.headerValue") {
        if !settings.custom_header_name.is_empty() {
            request = request.header(settings.custom_header_name.as_str(), value);
        }
    }
    let response = request.send().await.context("Could not reach the endpoint")?;
    let body = check(response).await?;
    link_from(&body, &url, &settings.custom_response_key)
}

async fn check(response: reqwest::Response) -> Result<Vec<u8>> {
    let status = response.status();
    let body = response.bytes().await.map(|b| b.to_vec()).unwrap_or_default();
    if !status.is_success() {
        let text = String::from_utf8_lossy(&body);
        let text: String = text.chars().take(120).collect();
        bail!("The server answered {}{}", status.as_u16(), if text.is_empty() { String::new() } else { format!(": {text}") });
    }
    Ok(body)
}

/// The link in an endpoint's answer.
pub fn link_from(body: &[u8], request_url: &str, key: &str) -> Result<String> {
    let text = String::from_utf8_lossy(body).trim().to_string();
    let json: Option<serde_json::Value> = serde_json::from_slice(body).ok();
    if !key.is_empty() {
        let mut node = json.as_ref();
        for part in key.split('.') {
            node = node.and_then(|n| n.get(part));
        }
        return node.and_then(|n| n.as_str()).map(String::from).context("The server did not return a link.");
    }
    if text.is_empty() {
        return Ok(request_url.to_string());
    }
    if text.starts_with("http://") || text.starts_with("https://") {
        return Ok(text);
    }
    if let Some(json) = json {
        for candidate in ["url", "link", "href"] {
            if let Some(link) = json.get(candidate).and_then(|v| v.as_str()) {
                return Ok(link.to_string());
            }
        }
    }
    bail!("The server did not return a link.")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// AWS's own example of deriving a signing key.
    #[test]
    fn derives_the_signing_key() {
        let key = signing_key("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20120215", "us-east-1", "iam");
        assert_eq!(hex::encode(key), "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d");
    }

    /// AWS's S3 "PUT Object" signing example.
    #[test]
    fn signs_like_aws() {
        let headers: BTreeMap<String, String> = [
            ("date", "Fri, 24 May 2013 00:00:00 GMT"),
            ("host", "examplebucket.s3.amazonaws.com"),
            ("x-amz-content-sha256", "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"),
            ("x-amz-date", "20130524T000000Z"),
            ("x-amz-storage-class", "REDUCED_REDUNDANCY"),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        let authorization = sign(&SigningRequest {
            method: "PUT",
            path: "/test$file.text",
            query: "",
            headers: &headers,
            payload_hash: "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
            amz_date: "20130524T000000Z",
            region: "us-east-1",
            service: "s3",
            access_key: "AKIAIOSFODNN7EXAMPLE",
            secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        });
        assert!(authorization.ends_with("Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"), "{authorization}");
    }

    #[test]
    fn finds_the_link_in_an_answer() {
        assert_eq!(link_from(b"https://x.test/a.png\n", "u", "").unwrap(), "https://x.test/a.png");
        assert_eq!(link_from(br#"{"data":{"link":"https://i.test/1"}}"#, "u", "data.link").unwrap(), "https://i.test/1");
        assert_eq!(link_from(br#"{"url":"https://i.test/2"}"#, "u", "").unwrap(), "https://i.test/2");
        assert_eq!(link_from(b"", "https://put.test/a.png", "").unwrap(), "https://put.test/a.png");
        assert!(link_from(b"ok", "u", "").is_err());
    }
}
