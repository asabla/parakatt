//! Provider-specific Keychain references. Rust never writes a secret to Keychain.
use crate::{config::Config, llm::LegacyCredential, CoreError};
use sha2::{Digest, Sha256};
use std::path::Path;

pub fn account(provider: &str, key: &str) -> String {
    format!(
        "llm-api-key-{provider}-migrated-{:x}",
        Sha256::digest(key.as_bytes())
    )
}
pub fn pending(config: &Config, directory: &Path) -> Vec<LegacyCredential> {
    fn collect(config: &Config, profile: Option<String>, output: &mut Vec<LegacyCredential>) {
        for (provider, key) in [
            ("openai", &config.llm.openai.api_key),
            ("anthropic", &config.llm.anthropic.api_key),
        ] {
            if let Some(key) = key {
                output.push(LegacyCredential {
                    provider: provider.into(),
                    api_key: key.clone(),
                    account: account(provider, key),
                    profile: profile.clone(),
                });
            }
        }
    }
    let mut output = Vec::new();
    collect(config, None, &mut output);
    for profile in Config::list_profiles(directory) {
        match Config::load_profile(directory, &profile) {
            Ok(config) => collect(&config, Some(profile), &mut output),
            Err(_) => log::warn!("An unreadable profile was retained during credential migration"),
        }
    }
    output
}
pub fn migrate(config: &Config, credential: &LegacyCredential) -> Result<Config, CoreError> {
    let mut updated = config.clone();
    let (key, reference) = match credential.provider.as_str() {
        "openai" => (
            &mut updated.llm.openai.api_key,
            &mut updated.llm.openai.credential_account,
        ),
        "anthropic" => (
            &mut updated.llm.anthropic.api_key,
            &mut updated.llm.anthropic.credential_account,
        ),
        _ => return Err(CoreError::ConfigError("Unknown credential provider".into())),
    };
    if key.as_deref() != Some(&credential.api_key)
        || account(&credential.provider, &credential.api_key) != credential.account
    {
        return Err(CoreError::ConfigError(
            "Credential changed during migration; source retained".into(),
        ));
    }
    *reference = Some(credential.account.clone());
    *key = None;
    Ok(updated)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn distinct_profile_credentials_keep_distinct_provider_references() {
        let directory = tempfile::tempdir().unwrap();
        let mut active = Config::default();
        active.llm.openai.api_key = Some("active-secret".into());
        let mut profile = Config::default();
        profile.llm.openai.api_key = Some("profile-secret".into());
        profile.llm.anthropic.api_key = Some("anthropic-secret".into());
        profile
            .write_migrated_profile(directory.path(), "work")
            .unwrap();
        let jobs = pending(&active, directory.path());
        assert_eq!(jobs.len(), 3);
        assert_ne!(jobs[0].account, jobs[1].account);
        let migrated = migrate(&profile, &jobs[1]).unwrap();
        assert!(migrated.llm.openai.api_key.is_none());
        assert_eq!(
            migrated.llm.openai.credential_account.as_ref(),
            Some(&jobs[1].account)
        );
        assert_eq!(
            migrated.llm.anthropic.api_key.as_deref(),
            Some("anthropic-secret")
        );
        assert!(migrate(&active, &jobs[1]).is_err());
        migrated
            .write_migrated_profile(directory.path(), "work")
            .unwrap();
        assert_eq!(pending(&active, directory.path()).len(), 2);
    }
}
