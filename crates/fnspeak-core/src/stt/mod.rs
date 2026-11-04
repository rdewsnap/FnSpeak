//! Speech-to-text engines behind one interface.
//!
//! Whisper accepts a starting prompt, which is how vocabulary reaches the
//! transcriber. Parakeet is faster and rarely invents text but has no prompt;
//! its vocabulary fixes happen afterwards. The benchmark decides the default.

#[cfg(feature = "parakeet")]
mod parakeet;
#[cfg(feature = "whisper")]
mod whisper;

#[cfg(feature = "parakeet")]
pub use parakeet::{ParakeetConfig, ParakeetEngine};
#[cfg(feature = "whisper")]
pub use whisper::{WhisperConfig, WhisperEngine};

/// All engines take 16 kHz mono f32 samples.
pub const SAMPLE_RATE: u32 = 16_000;

#[derive(Debug, thiserror::Error)]
pub enum SttError {
    #[error("failed to load speech model: {0}")]
    Load(String),
    #[error("transcription failed: {0}")]
    Transcribe(String),
}

#[derive(Clone, Debug, Default)]
pub struct SttHints {
    /// Vocabulary most likely to come up, best first.
    pub vocabulary: Vec<String>,
}

pub trait SttEngine: Send {
    fn name(&self) -> &'static str;
    fn transcribe(&mut self, audio: &[f32], hints: &SttHints) -> Result<String, SttError>;

    /// Transcribe a clip that continues `preceding`, the text already
    /// transcribed from the audio just before it. Engines with a prompt use it
    /// to keep chunks of one dictation coherent; the rest ignore it.
    fn transcribe_continuing(&mut self, audio: &[f32], hints: &SttHints, preceding: &str) -> Result<String, SttError> {
        let _ = preceding;
        self.transcribe(audio, hints)
    }
}

/// Below this RMS level a clip is treated as silence. Whisper in particular
/// "hears" things in silence ("Thank you."), so silent clips never reach it.
const SILENCE_RMS: f32 = 0.004;

pub fn is_silent(audio: &[f32]) -> bool {
    if audio.is_empty() {
        return true;
    }
    let rms = (audio.iter().map(|s| s * s).sum::<f32>() / audio.len() as f32).sqrt();
    rms < SILENCE_RMS
}

/// Phrases speech models are known to invent from noise, mostly picked up
/// from video subtitles in their training data.
const PHANTOM_PHRASES: &[&str] = &[
    "thank you",
    "thank you.",
    "thanks for watching!",
    "thanks for watching.",
    "thank you for watching.",
    "you",
    "bye.",
    "[blank_audio]",
    "[music]",
    "(music)",
];

/// Clean up engine output: trim, and drop it entirely if it's a known
/// phantom phrase from a short clip.
pub fn sanitize(text: &str, audio_seconds: f32) -> String {
    let text = text.trim();
    if audio_seconds < 3.0 && PHANTOM_PHRASES.contains(&text.to_lowercase().as_str()) {
        return String::new();
    }
    text.to_string()
}

/// Fixed output, for tests and for scoring transcripts produced elsewhere.
pub struct FixedTranscript(pub String);

impl SttEngine for FixedTranscript {
    fn name(&self) -> &'static str {
        "fixed"
    }

    fn transcribe(&mut self, _audio: &[f32], _hints: &SttHints) -> Result<String, SttError> {
        Ok(self.0.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_detection() {
        assert!(is_silent(&[]));
        assert!(is_silent(&vec![0.001; 16_000]));
        let tone: Vec<f32> = (0..16_000).map(|i| (i as f32 * 0.05).sin() * 0.2).collect();
        assert!(!is_silent(&tone));
    }

    #[test]
    fn drops_phantoms_only_on_short_clips() {
        assert_eq!(sanitize(" Thank you. ", 1.0), "");
        assert_eq!(sanitize("Thank you.", 6.0), "Thank you.");
        assert_eq!(sanitize(" ship it ", 1.0), "ship it");
    }
}
