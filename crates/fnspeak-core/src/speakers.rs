//! Telling the voices on the far side of a call apart.
//!
//! Each utterance from the system-audio stream is turned into a voice
//! fingerprint (a speaker embedding) and compared with the voices heard so
//! far in this meeting. A close match joins that voice; anything else starts
//! a new one. Voices are numbered in the order they first speak: "Speaker 1",
//! "Speaker 2". Nothing here knows names, and nothing is kept past the
//! meeting: the fingerprints live in memory and go with the session.

use crate::stt::SAMPLE_RATE;
use std::path::Path;

/// Cosine similarity at or above which an utterance joins a voice already
/// heard. Lower merges different people into one speaker; higher splits one
/// person into several.
///
/// UNTUNED: this can't be set properly without real meeting recordings.
/// 0.5 is sherpa-onnx's default for speaker verification, checked only
/// against a few clean clips with the CAM++ model the app downloads: three
/// real speakers scored 0.65 to 0.88 against themselves and at most 0.46
/// against each other (0.43 and 0.42 when cut to 2 s pieces), so 0.5 sat in
/// the gap. Two similar synthetic voices scored 0.7 and were merged. Call
/// audio (codecs, noise suppression, short turns) will score differently;
/// revisit with the `real_clips_group_by_speaker` test below.
pub const SPEAKER_MATCH_THRESHOLD: f32 = 0.5;

/// Utterances shorter than this aren't fingerprinted: a "yeah" or "mm-hm"
/// doesn't carry enough voice to compare, and would start a phantom speaker.
/// They go to whoever spoke last on the far side. The length includes the
/// padding the segmenter keeps around speech (about 400 ms).
pub const MIN_FINGERPRINT_MS: u32 = 1500;

/// Past this many voices, new ones join their nearest match. A call rarely
/// has more people talking, and a runaway count means the threshold is off.
pub const MAX_SPEAKERS: usize = 12;

/// "Speaker 3" for the third voice heard.
pub fn speaker_label(index: usize) -> String {
    format!("Speaker {}", index + 1)
}

/// Turns one utterance (16 kHz mono) into a voice fingerprint, or `None`
/// when it can't.
pub trait VoiceEmbedder: Send {
    fn embed(&mut self, audio: &[f32]) -> Option<Vec<f32>>;
}

/// One voice heard in a meeting.
#[derive(Clone, Debug, PartialEq)]
pub struct Voice {
    pub label: String,
    /// Unit-length average of the voice's fingerprints. What a later step
    /// would compare with remembered voices to put a name to the label.
    pub embedding: Vec<f32>,
    /// How many utterances were fingerprinted into it.
    pub utterances: usize,
}

/// Says who on the far side spoke an utterance.
pub trait SpeakerLabeller: Send {
    /// A label to store instead of "others", or `None` to leave it.
    fn label(&mut self, audio: &[f32]) -> Option<String>;

    /// The voices heard so far, in the order they first spoke.
    fn voices(&self) -> Vec<Voice> {
        Vec::new()
    }
}

struct Cluster {
    /// Sum of unit-length fingerprints; its direction is the centroid.
    sum: Vec<f32>,
    count: usize,
}

/// Groups utterances by voice as they arrive.
pub struct VoiceLabeller {
    embedder: Box<dyn VoiceEmbedder>,
    threshold: f32,
    clusters: Vec<Cluster>,
    /// The far-side voice that spoke last.
    last: Option<usize>,
}

impl VoiceLabeller {
    pub fn new(embedder: Box<dyn VoiceEmbedder>) -> Self {
        Self::with_threshold(embedder, SPEAKER_MATCH_THRESHOLD)
    }

    pub fn with_threshold(embedder: Box<dyn VoiceEmbedder>, threshold: f32) -> Self {
        VoiceLabeller { embedder, threshold, clusters: Vec::new(), last: None }
    }

    fn assign(&mut self, embedding: &[f32]) -> usize {
        let best = self
            .clusters
            .iter()
            .enumerate()
            .filter(|(_, c)| c.sum.len() == embedding.len())
            .map(|(i, c)| (i, cosine(&c.sum, embedding)))
            .max_by(|a, b| a.1.total_cmp(&b.1));
        match best {
            Some((i, score)) if score >= self.threshold => {
                let cluster = &mut self.clusters[i];
                cluster.sum.iter_mut().zip(embedding).for_each(|(s, e)| *s += e);
                cluster.count += 1;
                i
            }
            // Full: the nearest voice takes it, but isn't pulled towards it.
            Some((i, _)) if self.clusters.len() >= MAX_SPEAKERS => i,
            _ => {
                self.clusters.push(Cluster { sum: embedding.to_vec(), count: 1 });
                self.clusters.len() - 1
            }
        }
    }
}

impl SpeakerLabeller for VoiceLabeller {
    fn label(&mut self, audio: &[f32]) -> Option<String> {
        let long_enough = audio.len() as u64 * 1000 >= MIN_FINGERPRINT_MS as u64 * SAMPLE_RATE as u64;
        let embedding = if long_enough { self.embedder.embed(audio).and_then(normalized) } else { None };
        if let Some(embedding) = embedding {
            self.last = Some(self.assign(&embedding));
        }
        // Too short or unreadable: whoever spoke last, if anyone has.
        self.last.map(speaker_label)
    }

    fn voices(&self) -> Vec<Voice> {
        self.clusters
            .iter()
            .enumerate()
            .map(|(i, c)| Voice { label: speaker_label(i), embedding: normalized(c.sum.clone()).unwrap_or_default(), utterances: c.count })
            .collect()
    }
}

fn normalized(mut v: Vec<f32>) -> Option<Vec<f32>> {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if v.is_empty() || !norm.is_finite() || norm <= f32::EPSILON {
        return None;
    }
    v.iter_mut().for_each(|x| *x /= norm);
    Some(v)
}

pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let norms = a.iter().map(|x| x * x).sum::<f32>().sqrt() * b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norms > f32::EPSILON {
        dot / norms
    } else {
        0.0
    }
}

/// Fingerprints with a sherpa-onnx speaker-embedding model. The model is
/// loaded on first use, on the meeting's worker thread, so starting a
/// meeting doesn't wait for it.
#[cfg(feature = "parakeet")]
pub struct SherpaEmbedder {
    model: std::path::PathBuf,
    extractor: Option<sherpa_rs::speaker_id::EmbeddingExtractor>,
    failed: bool,
}

#[cfg(feature = "parakeet")]
impl SherpaEmbedder {
    pub fn new(model: impl Into<std::path::PathBuf>) -> Self {
        SherpaEmbedder { model: model.into(), extractor: None, failed: false }
    }
}

#[cfg(feature = "parakeet")]
impl VoiceEmbedder for SherpaEmbedder {
    fn embed(&mut self, audio: &[f32]) -> Option<Vec<f32>> {
        use sherpa_rs::speaker_id::{EmbeddingExtractor, ExtractorConfig};
        if self.failed {
            return None;
        }
        if self.extractor.is_none() {
            let config = ExtractorConfig { model: self.model.to_string_lossy().into_owned(), ..Default::default() };
            match EmbeddingExtractor::new(config) {
                Ok(extractor) => self.extractor = Some(extractor),
                Err(e) => {
                    log::warn!("speaker model wouldn't load, far-side speakers stay unseparated: {e}");
                    self.failed = true;
                    return None;
                }
            }
        }
        self.extractor.as_mut()?.compute_speaker_embedding(audio.to_vec(), SAMPLE_RATE).ok()
    }
}

/// A truncated download isn't a model; sherpa-onnx aborts on one.
#[cfg(feature = "parakeet")]
const MIN_MODEL_BYTES: u64 = 1_000_000;

/// The labeller for a meeting, given where the speaker-embedding model
/// should be. `None` when this build has no model runtime or the file isn't
/// there, and then the far side stays "others".
pub fn voice_labeller(model: Option<&Path>) -> Option<Box<dyn SpeakerLabeller>> {
    #[cfg(feature = "parakeet")]
    {
        let model = model?;
        let size = std::fs::metadata(model).ok().filter(|m| m.is_file())?.len();
        if size < MIN_MODEL_BYTES {
            return None;
        }
        Some(Box::new(VoiceLabeller::new(Box::new(SherpaEmbedder::new(model)))))
    }
    #[cfg(not(feature = "parakeet"))]
    {
        let _ = model;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reads the fingerprint straight out of the audio's first three samples.
    struct FirstSamples;
    impl VoiceEmbedder for FirstSamples {
        fn embed(&mut self, audio: &[f32]) -> Option<Vec<f32>> {
            (audio[0] >= 0.0).then(|| audio[..3].to_vec())
        }
    }

    fn utterance(voice: [f32; 3], ms: u32) -> Vec<f32> {
        let mut audio = vec![0.0; (ms * SAMPLE_RATE / 1000) as usize];
        audio[..3].copy_from_slice(&voice);
        audio
    }

    const ANA: [f32; 3] = [1.0, 0.1, 0.0];
    const ANA_AGAIN: [f32; 3] = [0.9, 0.0, 0.2];
    const BEN: [f32; 3] = [0.0, 1.0, 0.1];
    const CAT: [f32; 3] = [0.1, 0.0, 1.0];
    const UNREADABLE: [f32; 3] = [-1.0, 0.0, 0.0];

    fn labeller() -> VoiceLabeller {
        VoiceLabeller::new(Box::new(FirstSamples))
    }

    #[test]
    fn groups_similar_voices_and_numbers_them_in_order() {
        let mut l = labeller();
        let said = [ANA, BEN, ANA_AGAIN, CAT, BEN, ANA];
        let labels: Vec<String> = said.iter().map(|v| l.label(&utterance(*v, 3000)).unwrap()).collect();
        assert_eq!(labels, ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 3", "Speaker 2", "Speaker 1"]);

        let voices = l.voices();
        assert_eq!(voices.iter().map(|v| v.utterances).collect::<Vec<_>>(), [3, 2, 1]);
        assert_eq!(voices[1].label, "Speaker 2");
        // Centroids come back unit length, ready to compare.
        for v in &voices {
            assert!((cosine(&v.embedding, &v.embedding) - 1.0).abs() < 1e-5);
            assert!((v.embedding.iter().map(|x| x * x).sum::<f32>() - 1.0).abs() < 1e-5);
        }
        assert!(cosine(&voices[0].embedding, &ANA) > 0.95);
    }

    #[test]
    fn short_utterances_go_to_whoever_spoke_last() {
        let mut l = labeller();
        // Nobody has spoken yet: nothing to inherit, and no speaker is made up.
        assert_eq!(l.label(&utterance(BEN, 600)), None);
        assert_eq!(l.label(&utterance(ANA, 3000)).as_deref(), Some("Speaker 1"));
        // Ben's "yeah" is too short to tell from Ana, so it stays with her.
        assert_eq!(l.label(&utterance(BEN, 600)).as_deref(), Some("Speaker 1"));
        assert_eq!(l.voices().len(), 1);
        assert_eq!(l.voices()[0].utterances, 1);
        assert_eq!(l.label(&utterance(BEN, MIN_FINGERPRINT_MS)).as_deref(), Some("Speaker 2"));
        assert_eq!(l.label(&utterance(ANA, MIN_FINGERPRINT_MS - 1)).as_deref(), Some("Speaker 2"));
    }

    #[test]
    fn unreadable_audio_inherits_too() {
        let mut l = labeller();
        assert_eq!(l.label(&utterance(UNREADABLE, 3000)), None);
        assert_eq!(l.label(&utterance(ANA, 3000)).as_deref(), Some("Speaker 1"));
        assert_eq!(l.label(&utterance(UNREADABLE, 3000)).as_deref(), Some("Speaker 1"));
        // A silent fingerprint (all zeros) can't be compared either.
        assert_eq!(l.label(&utterance([0.0; 3], 3000)).as_deref(), Some("Speaker 1"));
        assert_eq!(l.voices().len(), 1);
    }

    #[test]
    fn threshold_decides_between_joining_and_splitting() {
        let near_ana = [1.0, 0.8, 0.0]; // cosine with ANA is about 0.84
        let mut strict = VoiceLabeller::with_threshold(Box::new(FirstSamples), 0.9);
        strict.label(&utterance(ANA, 3000));
        assert_eq!(strict.label(&utterance(near_ana, 3000)).as_deref(), Some("Speaker 2"));
        let mut loose = VoiceLabeller::with_threshold(Box::new(FirstSamples), 0.8);
        loose.label(&utterance(ANA, 3000));
        assert_eq!(loose.label(&utterance(near_ana, 3000)).as_deref(), Some("Speaker 1"));
    }

    #[test]
    fn stops_inventing_speakers_at_the_cap() {
        struct OneHot;
        impl VoiceEmbedder for OneHot {
            fn embed(&mut self, audio: &[f32]) -> Option<Vec<f32>> {
                let mut v = vec![0.0; MAX_SPEAKERS + 5];
                v[audio[0] as usize] = 1.0;
                Some(v)
            }
        }
        let mut l = VoiceLabeller::new(Box::new(OneHot));
        for i in 0..MAX_SPEAKERS + 5 {
            l.label(&utterance([i as f32, 0.0, 0.0], 3000));
        }
        assert_eq!(l.voices().len(), MAX_SPEAKERS);
    }

    #[test]
    fn no_labeller_without_a_model() {
        assert!(voice_labeller(None).is_none());
        assert!(voice_labeller(Some(Path::new("/nonexistent/speaker.onnx"))).is_none());
        // A stub of a file (an interrupted download) doesn't count as a model.
        let dir = tempfile::tempdir().unwrap();
        let stub = dir.path().join("speaker.onnx");
        std::fs::write(&stub, b"not a model").unwrap();
        assert!(voice_labeller(Some(&stub)).is_none());
        assert!(voice_labeller(Some(dir.path())).is_none());
    }

    /// Not run by default: needs the model and some clips. Prints how real
    /// voices score against each other and how the labeller groups them, for
    /// choosing SPEAKER_MATCH_THRESHOLD.
    ///
    ///   FNSPEAK_SPEAKER_MODEL=/path/to/model.onnx FNSPEAK_SPEAKER_CLIPS=/folder/of/wavs \
    ///     cargo test -p fnspeak-core --features parakeet real_clips -- --ignored --nocapture
    ///
    /// Clips are 16 kHz mono 16-bit WAVs named `<speaker>-<anything>.wav`.
    /// FNSPEAK_SPEAKER_CLIP_MS cuts them into pieces of that length first,
    /// to see how short turns score.
    #[cfg(feature = "parakeet")]
    #[test]
    #[ignore]
    fn real_clips_group_by_speaker() {
        let (Ok(model), Ok(clips)) = (std::env::var("FNSPEAK_SPEAKER_MODEL"), std::env::var("FNSPEAK_SPEAKER_CLIPS")) else {
            panic!("set FNSPEAK_SPEAKER_MODEL and FNSPEAK_SPEAKER_CLIPS");
        };
        let piece_ms: Option<usize> = std::env::var("FNSPEAK_SPEAKER_CLIP_MS").ok().and_then(|v| v.parse().ok());
        let mut files: Vec<_> = std::fs::read_dir(&clips).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|e| e == "wav")).collect();
        files.sort();

        // (speaker, clip name, audio)
        let mut turns: Vec<(String, String, Vec<f32>)> = Vec::new();
        for file in &files {
            let name = file.file_stem().unwrap().to_string_lossy().into_owned();
            let who = name.split('-').next().unwrap().to_string();
            let audio = read_wav(file);
            match piece_ms {
                Some(ms) => {
                    let len = ms * SAMPLE_RATE as usize / 1000;
                    for (i, piece) in audio.chunks(len).filter(|c| c.len() == len).enumerate() {
                        turns.push((who.clone(), format!("{name}#{i}"), piece.to_vec()));
                    }
                }
                None => turns.push((who, name, audio)),
            }
        }
        assert!(!turns.is_empty(), "no clips in {clips}");

        let mut embedder = SherpaEmbedder::new(&model);
        let started = std::time::Instant::now();
        let embeddings: Vec<Vec<f32>> = turns.iter().map(|t| embedder.embed(&t.2).and_then(normalized).expect("embedding")).collect();
        let seconds: f32 = turns.iter().map(|t| t.2.len() as f32 / SAMPLE_RATE as f32).sum();
        println!("{} turns, {seconds:.0} s of audio, fingerprinted in {:?} (model load included), {} dims", turns.len(), started.elapsed(), embeddings[0].len());

        let (mut same, mut different) = (Vec::new(), Vec::new());
        for i in 0..turns.len() {
            for j in i + 1..turns.len() {
                let score = cosine(&embeddings[i], &embeddings[j]);
                if turns[i].0 == turns[j].0 { same.push(score) } else { different.push(score) }
            }
        }
        let range = |v: &mut Vec<f32>| {
            v.sort_by(f32::total_cmp);
            if v.is_empty() { "none".to_string() } else { format!("min {:.2}  median {:.2}  max {:.2}  (n={})", v[0], v[v.len() / 2], v[v.len() - 1], v.len()) }
        };
        println!("same speaker:      {}", range(&mut same));
        println!("different speaker: {}", range(&mut different));
        println!("below threshold {SPEAKER_MATCH_THRESHOLD} among same: {}, at or above among different: {}",
            same.iter().filter(|s| **s < SPEAKER_MATCH_THRESHOLD).count(), different.iter().filter(|s| **s >= SPEAKER_MATCH_THRESHOLD).count());

        // Take turns round-robin across speakers, the way a conversation goes.
        let mut by_speaker: std::collections::BTreeMap<&str, Vec<usize>> = Default::default();
        for (i, t) in turns.iter().enumerate() {
            by_speaker.entry(&t.0).or_default().push(i);
        }
        let longest = by_speaker.values().map(Vec::len).max().unwrap();
        let order: Vec<usize> = (0..longest).flat_map(|n| by_speaker.values().filter_map(move |v| v.get(n).copied())).collect();

        let mut labeller = voice_labeller(Some(Path::new(&model))).expect("the model file should be accepted");
        let mut seen: std::collections::BTreeMap<&str, std::collections::BTreeMap<String, usize>> = Default::default();
        for i in order {
            let label = labeller.label(&turns[i].2).unwrap_or_else(|| "others".into());
            *seen.entry(&turns[i].0).or_default().entry(label).or_default() += 1;
        }
        for (who, labels) in &seen {
            println!("{who:>12}: {labels:?}");
        }
        println!("{} voices found for {} speakers", labeller.voices().len(), by_speaker.len());
        if piece_ms.is_none() {
            assert_eq!(labeller.voices().len(), by_speaker.len());
        }
    }

    #[cfg(feature = "parakeet")]
    fn read_wav(path: &Path) -> Vec<f32> {
        let bytes = std::fs::read(path).unwrap();
        assert_eq!(&bytes[..4], b"RIFF", "{} is not a WAV", path.display());
        let mut at = 12;
        while at + 8 <= bytes.len() {
            let len = u32::from_le_bytes(bytes[at + 4..at + 8].try_into().unwrap()) as usize;
            let body = &bytes[at + 8..(at + 8 + len).min(bytes.len())];
            if &bytes[at..at + 4] == b"fmt " {
                let (channels, rate, bits) = (u16::from_le_bytes([body[2], body[3]]), u32::from_le_bytes(body[4..8].try_into().unwrap()), u16::from_le_bytes([body[14], body[15]]));
                assert_eq!((channels, rate, bits), (1, SAMPLE_RATE, 16), "{} must be 16 kHz mono 16-bit", path.display());
            }
            if &bytes[at..at + 4] == b"data" {
                return body.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0).collect();
            }
            at += 8 + len + len % 2;
        }
        panic!("no audio in {}", path.display());
    }
}
