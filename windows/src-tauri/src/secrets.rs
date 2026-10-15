//! Secrets — a bucket's secret key, an endpoint's token — in Windows Credential Manager,
//! never in the settings file.

const SERVICE: &str = "Klik";

/// The names a secret can be stored under.
pub const NAMES: [&str; 2] = ["share.s3.secretKey", "share.custom.headerValue"];

pub fn get(name: &str) -> Option<String> {
    keyring::Entry::new(SERVICE, name).ok()?.get_password().ok().filter(|value| !value.is_empty())
}

pub fn set(name: &str, value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(NAMES.contains(&name), "Unknown secret {name}");
    let entry = keyring::Entry::new(SERVICE, name)?;
    if value.is_empty() {
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(error.into()),
        }
    } else {
        entry.set_password(value).map_err(Into::into)
    }
}
