//! First-run hardware check: decides whether cleanup defaults to a local
//! model or to the cloud. Weak machines get cloud by default (shown, never
//! silent, during onboarding) and can always switch to local or filter-only.

use crate::cleanup::CleanupMode;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct HardwareInfo {
    pub total_memory_gb: f64,
    pub apple_silicon: bool,
    /// Dedicated GPU memory on Windows/Linux; reported by the shell.
    pub gpu_memory_gb: Option<f64>,
    /// Tokens per second from a short local generation test, if one was run.
    pub measured_tokens_per_sec: Option<f64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    /// Runs a 3–4B cleanup model comfortably.
    Capable,
    /// Local cleanup would be slow; cloud is the default.
    Weak,
}

/// Below this, a dictation's cleanup takes longer than people will wait.
const MIN_TOKENS_PER_SEC: f64 = 20.0;

impl HardwareInfo {
    /// Fill in what the core can see on its own; the shell adds GPU details.
    pub fn detect() -> Self {
        let total_memory = sysinfo::System::new()
            .map(|mut sys| {
                sys.refresh_memory();
                sys.total_memory()
            })
            .unwrap_or(0);
        HardwareInfo {
            total_memory_gb: total_memory as f64 / 1_073_741_824.0,
            apple_silicon: cfg!(all(target_os = "macos", target_arch = "aarch64")),
            gpu_memory_gb: None,
            measured_tokens_per_sec: None,
        }
    }

    pub fn tier(&self) -> Tier {
        // A real measurement beats any spec-sheet guess.
        if let Some(tps) = self.measured_tokens_per_sec {
            return if tps >= MIN_TOKENS_PER_SEC { Tier::Capable } else { Tier::Weak };
        }
        let capable = if self.apple_silicon {
            // Unified memory: the model shares RAM with everything else.
            self.total_memory_gb >= 15.5
        } else {
            self.gpu_memory_gb.is_some_and(|g| g >= 6.0) && self.total_memory_gb >= 15.5
        };
        if capable { Tier::Capable } else { Tier::Weak }
    }

    pub fn default_cleanup_mode(&self) -> CleanupMode {
        match self.tier() {
            Tier::Capable => CleanupMode::Local,
            Tier::Weak => CleanupMode::Cloud,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hw(mem: f64, apple: bool, gpu: Option<f64>, tps: Option<f64>) -> HardwareInfo {
        HardwareInfo { total_memory_gb: mem, apple_silicon: apple, gpu_memory_gb: gpu, measured_tokens_per_sec: tps }
    }

    #[test]
    fn tiers() {
        assert_eq!(hw(16.0, true, None, None).tier(), Tier::Capable);
        assert_eq!(hw(8.0, true, None, None).tier(), Tier::Weak);
        assert_eq!(hw(32.0, false, Some(8.0), None).tier(), Tier::Capable);
        assert_eq!(hw(32.0, false, None, None).tier(), Tier::Weak);
        assert_eq!(hw(8.0, true, None, Some(45.0)).tier(), Tier::Capable);
        assert_eq!(hw(64.0, true, None, Some(5.0)).tier(), Tier::Weak);
        assert_eq!(hw(8.0, true, None, None).default_cleanup_mode(), CleanupMode::Cloud);
    }

    #[test]
    fn detect_reads_memory() {
        assert!(HardwareInfo::detect().total_memory_gb > 1.0);
    }
}
