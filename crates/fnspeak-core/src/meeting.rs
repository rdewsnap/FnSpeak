//! Live meeting transcription.
//!
//! The app feeds two streams: the microphone (the user) and the audio the
//! computer plays (everyone else on the call). Mic speech is "me". System
//! audio is "others", or "Speaker 1", "Speaker 2" and so on when a
//! [`SpeakerLabeller`] is there to tell the far-side voices apart.
//! Each stream is cut into utterances at pauses, and each utterance goes
//! through speech-to-text and the rule-based filter (never the cleanup
//! model) and lands in the notes store as a segment.
//!
//! Audio callbacks only copy samples into a channel. Cutting and
//! transcription happen on the session's own worker thread.

use crate::notes::{NotesStore, Segment, SPEAKER_ME, SPEAKER_OTHERS};
use crate::pipeline::Pipeline;
use crate::speakers::{SpeakerLabeller, Voice};
use crate::stt::SAMPLE_RATE;
use std::collections::VecDeque;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioSource {
    Mic,
    System,
}

impl AudioSource {
    pub fn speaker(self) -> &'static str {
        match self {
            AudioSource::Mic => SPEAKER_ME,
            AudioSource::System => SPEAKER_OTHERS,
        }
    }
}

/// Turns one utterance into (raw, filtered) text.
pub trait Transcriber: Send {
    fn transcribe(&mut self, audio: &[f32]) -> Result<(String, String), String>;
}

/// Transcribes through the engine's pipeline, sharing its speech model and
/// vocabulary with dictation. The lock is held for one utterance at a time.
pub struct PipelineTranscriber {
    pub pipeline: Arc<Mutex<Pipeline>>,
    /// Picks vocabulary hints, like the window title does for dictation:
    /// the meeting title and participant names.
    pub context: String,
}

impl Transcriber for PipelineTranscriber {
    fn transcribe(&mut self, audio: &[f32]) -> Result<(String, String), String> {
        let mut pipeline = self.pipeline.lock().unwrap_or_else(|e| e.into_inner());
        pipeline.transcribe_verbatim(audio, &self.context).map_err(|e| e.to_string())
    }
}

/// Told about each segment as it's stored, from the worker thread.
pub trait SegmentListener: Send + Sync {
    fn segment(&self, segment: &Segment);
}

#[derive(Clone, Copy, Debug)]
pub struct VadConfig {
    pub frame_ms: u32,
    /// A pause this long ends an utterance.
    pub end_silence_ms: u32,
    /// Utterances are cut at the quietest recent moment past this length.
    pub max_utterance_ms: u32,
    /// Shorter bursts (clicks, coughs, keyboard) are dropped.
    pub min_speech_ms: u32,
    /// Audio kept from just before speech starts, so first syllables survive.
    pub pre_roll_ms: u32,
    /// Frames quieter than this are never speech, whatever the noise floor.
    pub min_rms: f32,
}

impl Default for VadConfig {
    fn default() -> Self {
        VadConfig { frame_ms: 20, end_silence_ms: 700, max_utterance_ms: 30_000, min_speech_ms: 250, pre_roll_ms: 200, min_rms: 0.006 }
    }
}

impl VadConfig {
    fn samples(&self, ms: u32) -> usize {
        (ms as u64 * SAMPLE_RATE as u64 / 1000) as usize
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Utterance {
    /// Offset of the first sample from the start of the stream.
    pub start_sample: u64,
    pub audio: Vec<f32>,
}

impl Utterance {
    pub fn started_ms(&self) -> i64 {
        (self.start_sample * 1000 / SAMPLE_RATE as u64) as i64
    }

    pub fn ended_ms(&self) -> i64 {
        ((self.start_sample + self.audio.len() as u64) * 1000 / SAMPLE_RATE as u64) as i64
    }
}

/// Long enough to span a pause between words, short enough that a fan
/// switching on stops counting as speech within a few seconds.
const NOISE_WINDOW_MS: u32 = 5000;

struct Current {
    start_sample: u64,
    audio: Vec<f32>,
    /// Per frame: RMS and whether it counted as speech.
    frames: Vec<(f32, bool)>,
    trailing_silence: usize,
}

/// Energy-based voice activity detection for one stream. Speech is a frame
/// well above the running noise floor; an utterance ends after a pause.
pub struct Segmenter {
    config: VadConfig,
    frame_len: usize,
    partial: Vec<f32>,
    /// Samples processed so far, in whole frames.
    position: u64,
    /// RMS of recent frames. Their minimum is the noise floor: even
    /// continuous speech dips to it between words.
    recent_rms: VecDeque<f32>,
    pre_roll: VecDeque<f32>,
    current: Option<Current>,
}

impl Segmenter {
    pub fn new(config: VadConfig) -> Self {
        let frame_len = config.samples(config.frame_ms).max(1);
        Segmenter { config, frame_len, partial: Vec::new(), position: 0, recent_rms: VecDeque::new(), pre_roll: VecDeque::new(), current: None }
    }

    /// Take more audio; returns any utterances it completed.
    pub fn push(&mut self, samples: &[f32]) -> Vec<Utterance> {
        let mut done = Vec::new();
        self.partial.extend_from_slice(samples);
        let whole = self.partial.len() / self.frame_len * self.frame_len;
        let frames: Vec<f32> = self.partial.drain(..whole).collect();
        for frame in frames.chunks(self.frame_len) {
            if let Some(u) = self.frame(frame) {
                done.push(u);
            }
        }
        done
    }

    /// End of stream: whatever speech is in progress becomes an utterance.
    pub fn flush(&mut self) -> Option<Utterance> {
        let partial = std::mem::take(&mut self.partial);
        let mut cur = self.current.take()?;
        cur.audio.extend_from_slice(&partial);
        self.finish(cur, 0)
    }

    fn frame(&mut self, frame: &[f32]) -> Option<Utterance> {
        let rms = (frame.iter().map(|s| s * s).sum::<f32>() / frame.len() as f32).sqrt();
        // Until the window fills, the floor could be the speaker's own voice.
        let window = (NOISE_WINDOW_MS / self.config.frame_ms) as usize;
        let noise_floor =
            if self.recent_rms.len() >= window { self.recent_rms.iter().copied().fold(f32::INFINITY, f32::min) } else { 0.0 };
        let speech = rms > self.config.min_rms.max(noise_floor * 3.0);
        self.recent_rms.push_back(rms);
        if self.recent_rms.len() > window {
            self.recent_rms.pop_front();
        }
        let frame_start = self.position;
        self.position += frame.len() as u64;

        let Some(cur) = self.current.as_mut() else {
            if speech {
                let pre: Vec<f32> = self.pre_roll.drain(..).collect();
                let mut audio = pre;
                let start_sample = frame_start - audio.len() as u64;
                audio.extend_from_slice(frame);
                self.current = Some(Current { start_sample, audio, frames: vec![(rms, true)], trailing_silence: 0 });
            } else {
                self.pre_roll.extend(frame);
                let keep = self.config.samples(self.config.pre_roll_ms);
                while self.pre_roll.len() > keep {
                    self.pre_roll.pop_front();
                }
            }
            return None;
        };

        cur.audio.extend_from_slice(frame);
        cur.frames.push((rms, speech));
        cur.trailing_silence = if speech { 0 } else { cur.trailing_silence + 1 };

        if cur.trailing_silence * self.config.frame_ms as usize >= self.config.end_silence_ms as usize {
            let cur = self.current.take()?;
            let silence = cur.trailing_silence * self.frame_len;
            // Keep a little of the pause; Whisper does better with a tail.
            let trim = silence.saturating_sub(self.config.samples(self.config.pre_roll_ms));
            return self.finish(cur, trim);
        }
        if cur.audio.len() >= self.config.samples(self.config.max_utterance_ms) {
            return self.split_long();
        }
        None
    }

    /// Cut an over-long utterance at its quietest frame in the last two
    /// seconds, to avoid splitting a word, and carry the rest forward.
    fn split_long(&mut self) -> Option<Utterance> {
        let mut cur = self.current.take()?;
        let window = (2000 / self.config.frame_ms as usize).min(cur.frames.len() - 1);
        let first = cur.frames.len() - window;
        let cut_frame =
            (first..cur.frames.len()).min_by(|&a, &b| cur.frames[a].0.total_cmp(&cur.frames[b].0)).unwrap_or(cur.frames.len());
        // Frames line up with the audio's end, not its start (pre-roll comes first).
        let offset = cur.audio.len() - cur.frames.len() * self.frame_len;
        let cut = offset + cut_frame * self.frame_len;

        let rest_audio = cur.audio.split_off(cut);
        let rest_frames = cur.frames.split_off(cut_frame);
        if rest_frames.iter().any(|f| f.1) {
            let trailing_silence = rest_frames.iter().rev().take_while(|f| !f.1).count();
            self.current = Some(Current {
                start_sample: cur.start_sample + cut as u64,
                audio: rest_audio,
                frames: rest_frames,
                trailing_silence,
            });
        } else {
            let keep = self.config.samples(self.config.pre_roll_ms);
            self.pre_roll = rest_audio[rest_audio.len().saturating_sub(keep)..].iter().copied().collect();
        }
        cur.trailing_silence = 0;
        self.finish(cur, 0)
    }

    fn finish(&self, mut cur: Current, trim: usize) -> Option<Utterance> {
        let voiced_ms = cur.frames.iter().filter(|f| f.1).count() * self.config.frame_ms as usize;
        if voiced_ms < self.config.min_speech_ms as usize {
            return None;
        }
        cur.audio.truncate(cur.audio.len().saturating_sub(trim));
        Some(Utterance { start_sample: cur.start_sample, audio: cur.audio })
    }
}

enum Msg {
    Audio(AudioSource, Vec<f32>),
    Finish,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SessionReport {
    pub segments: usize,
    /// Utterances that couldn't be transcribed or stored.
    pub failures: usize,
    pub last_error: Option<String>,
    /// The far-side voices that were told apart, in the order they first
    /// spoke. Empty without a speaker labeller. In memory only.
    pub voices: Vec<Voice>,
}

/// One meeting being recorded. Feed it audio from any thread; call
/// [`finish`](Self::finish) to transcribe what's left and stop the worker.
///
/// Timestamps count samples per source, so each stream should be fed
/// continuously from the start of the meeting, silence included.
pub struct MeetingSession {
    meeting_id: i64,
    tx: Sender<Msg>,
    worker: Option<JoinHandle<SessionReport>>,
}

impl MeetingSession {
    pub fn start(
        meeting_id: i64,
        store: Arc<Mutex<NotesStore>>,
        transcriber: Box<dyn Transcriber>,
        labeller: Option<Box<dyn SpeakerLabeller>>,
        listener: Option<Arc<dyn SegmentListener>>,
        config: VadConfig,
    ) -> Self {
        let (tx, rx) = mpsc::channel();
        let worker = thread::Builder::new()
            .name(format!("meeting-{meeting_id}"))
            .spawn(move || Worker { meeting_id, store, transcriber, labeller, listener, report: SessionReport::default() }.run(rx, config))
            .expect("spawn meeting worker");
        MeetingSession { meeting_id, tx, worker: Some(worker) }
    }

    pub fn meeting_id(&self) -> i64 {
        self.meeting_id
    }

    /// Queue 16 kHz mono samples. Never blocks.
    pub fn feed(&self, source: AudioSource, samples: Vec<f32>) {
        if !samples.is_empty() {
            let _ = self.tx.send(Msg::Audio(source, samples));
        }
    }

    /// Transcribe everything still queued or buffered, then stop. Blocks
    /// until the backlog is done.
    pub fn finish(mut self) -> SessionReport {
        let _ = self.tx.send(Msg::Finish);
        self.worker.take().and_then(|w| w.join().ok()).unwrap_or_default()
    }
}

impl Drop for MeetingSession {
    fn drop(&mut self) {
        // Without finish(), the worker still drains and exits on its own.
        let _ = self.tx.send(Msg::Finish);
    }
}

struct Worker {
    meeting_id: i64,
    store: Arc<Mutex<NotesStore>>,
    transcriber: Box<dyn Transcriber>,
    /// Tells far-side voices apart; without one they're all "others".
    labeller: Option<Box<dyn SpeakerLabeller>>,
    listener: Option<Arc<dyn SegmentListener>>,
    report: SessionReport,
}

impl Worker {
    fn run(mut self, rx: Receiver<Msg>, config: VadConfig) -> SessionReport {
        let mut mic = Segmenter::new(config);
        let mut system = Segmenter::new(config);
        while let Ok(Msg::Audio(source, samples)) = rx.recv() {
            let segmenter = match source {
                AudioSource::Mic => &mut mic,
                AudioSource::System => &mut system,
            };
            for utterance in segmenter.push(&samples) {
                self.handle(source, utterance);
            }
        }
        for (source, segmenter) in [(AudioSource::Mic, &mut mic), (AudioSource::System, &mut system)] {
            if let Some(utterance) = segmenter.flush() {
                self.handle(source, utterance);
            }
        }
        if let Some(labeller) = &self.labeller {
            self.report.voices = labeller.voices();
        }
        self.report
    }

    fn handle(&mut self, source: AudioSource, utterance: Utterance) {
        let (raw, text) = match self.transcriber.transcribe(&utterance.audio) {
            Ok(t) => t,
            Err(e) => return self.fail(e),
        };
        if text.trim().is_empty() {
            return;
        }
        // Only speech that made it to text gets a voice: noise that
        // transcribed to nothing shouldn't count as someone speaking.
        let voice = match (source, self.labeller.as_mut()) {
            (AudioSource::System, Some(labeller)) => labeller.label(&utterance.audio),
            _ => None,
        };
        let speaker = voice.as_deref().unwrap_or(source.speaker());
        let stored = {
            let store = self.store.lock().unwrap_or_else(|e| e.into_inner());
            store.append_segment(self.meeting_id, utterance.started_ms(), utterance.ended_ms(), speaker, &raw, &text)
        };
        match stored {
            Ok(segment) => {
                self.report.segments += 1;
                if let Some(listener) = &self.listener {
                    listener.segment(&segment);
                }
            }
            Err(e) => self.fail(e.to_string()),
        }
    }

    fn fail(&mut self, error: String) {
        self.report.failures += 1;
        self.report.last_error = Some(error);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(ms: u32) -> Vec<f32> {
        (0..ms * 16).map(|i| (i as f32 * 0.05).sin() * 0.2).collect()
    }

    fn silence(ms: u32) -> Vec<f32> {
        vec![0.0; (ms * 16) as usize]
    }

    fn concat(parts: &[Vec<f32>]) -> Vec<f32> {
        parts.concat()
    }

    fn segment_all(audio: &[f32], chunk: usize) -> Vec<Utterance> {
        let mut seg = Segmenter::new(VadConfig::default());
        let mut out: Vec<Utterance> = audio.chunks(chunk).flat_map(|c| seg.push(c)).collect();
        out.extend(seg.flush());
        out
    }

    #[test]
    fn cuts_at_pauses() {
        let audio = concat(&[silence(500), tone(1000), silence(1000), tone(1500), silence(1000)]);
        let utterances = segment_all(&audio, 1024);
        assert_eq!(utterances.len(), 2);
        // Pre-roll starts each utterance a little before the speech.
        assert_eq!(utterances[0].started_ms(), 300);
        assert_eq!(utterances[1].started_ms(), 2300);
        assert!((1400..=1500).contains(&(utterances[0].ended_ms() - utterances[0].started_ms())));
    }

    #[test]
    fn chunk_size_does_not_matter() {
        let audio = concat(&[tone(800), silence(900), tone(600), silence(200)]);
        assert_eq!(segment_all(&audio, 160), segment_all(&audio, 7_777));
        // The second utterance had no pause after it: flush emits it.
        assert_eq!(segment_all(&audio, 160).len(), 2);
    }

    #[test]
    fn ignores_short_bursts_and_quiet_noise() {
        let noise: Vec<f32> = (0..32_000).map(|i| if i % 2 == 0 { 0.003 } else { -0.003 }).collect();
        let audio = concat(&[silence(500), tone(90), silence(1000), noise]);
        assert!(segment_all(&audio, 1024).is_empty());
    }

    #[test]
    fn splits_long_monologues() {
        // Speech with short breaths every 3 s, never a long enough pause.
        let mut parts = Vec::new();
        for _ in 0..16 {
            parts.push(tone(2800));
            parts.push(silence(200));
        }
        let utterances = segment_all(&concat(&parts), 4096);
        assert!(utterances.len() >= 2);
        for u in &utterances {
            assert!(u.ended_ms() - u.started_ms() <= 30_000);
        }
        // Cut at a breath, and nothing lost or duplicated between pieces.
        assert_eq!(utterances[0].ended_ms(), utterances[1].started_ms());
        let cut = utterances[0].ended_ms() % 3000;
        assert!((2800..3000).contains(&cut), "cut mid-word at {cut}");
    }

    struct Counter(usize);
    impl Transcriber for Counter {
        fn transcribe(&mut self, audio: &[f32]) -> Result<(String, String), String> {
            self.0 += 1;
            Ok((format!("um utterance {}", self.0), format!("Utterance {} ({} ms)", self.0, audio.len() / 16)))
        }
    }

    #[derive(Default)]
    struct Collect(Mutex<Vec<Segment>>);
    impl SegmentListener for Collect {
        fn segment(&self, segment: &Segment) {
            self.0.lock().unwrap().push(segment.clone());
        }
    }

    #[test]
    fn session_stores_segments_by_speaker() {
        let store = Arc::new(Mutex::new(NotesStore::in_memory().unwrap()));
        let meeting = store.lock().unwrap().start_meeting("Standup", None, &[]).unwrap();
        let listener = Arc::new(Collect::default());
        let session =
            MeetingSession::start(meeting.id, store.clone(), Box::new(Counter(0)), None, Some(listener.clone()), VadConfig::default());

        let mic = concat(&[tone(1000), silence(3000)]);
        let system = concat(&[silence(2000), tone(1000), silence(1000)]);
        // Interleave small chunks the way two audio callbacks would.
        for (m, s) in mic.chunks(512).zip(system.chunks(512)) {
            session.feed(AudioSource::Mic, m.to_vec());
            session.feed(AudioSource::System, s.to_vec());
        }
        session.feed(AudioSource::Mic, tone(500));
        let report = session.finish();
        assert_eq!(report, SessionReport { segments: 3, failures: 0, last_error: None, voices: vec![] });

        let segments = store.lock().unwrap().segments(meeting.id).unwrap();
        let speakers: Vec<&str> = segments.iter().map(|s| s.speaker.as_str()).collect();
        assert_eq!(speakers, vec!["me", "others", "me"]);
        assert_eq!(segments[1].started_ms, 1800);
        assert_eq!(segments[0].raw, "um utterance 1");
        assert_eq!(listener.0.lock().unwrap().len(), 3);
    }

    /// Calls the first far-side utterance Speaker 1 and the next Speaker 2,
    /// then gives up, the way a labeller with nothing to go on does.
    struct Scripted(usize);
    impl SpeakerLabeller for Scripted {
        fn label(&mut self, _audio: &[f32]) -> Option<String> {
            self.0 += 1;
            (self.0 <= 2).then(|| format!("Speaker {}", self.0))
        }

        fn voices(&self) -> Vec<Voice> {
            vec![Voice { label: "Speaker 1".into(), embedding: vec![1.0], utterances: 1 }]
        }
    }

    #[test]
    fn session_labels_far_side_speakers() {
        let store = Arc::new(Mutex::new(NotesStore::in_memory().unwrap()));
        let meeting = store.lock().unwrap().start_meeting("Standup", None, &[]).unwrap();
        let session =
            MeetingSession::start(meeting.id, store.clone(), Box::new(Counter(0)), Some(Box::new(Scripted(0))), None, VadConfig::default());

        let turn = concat(&[tone(1000), silence(1000)]);
        session.feed(AudioSource::System, turn.clone());
        // The mic never goes to the labeller, so it doesn't use up a turn.
        session.feed(AudioSource::Mic, turn.clone());
        session.feed(AudioSource::System, turn.clone());
        session.feed(AudioSource::System, turn);
        let report = session.finish();
        assert_eq!(report.segments, 4);
        assert_eq!(report.voices.len(), 1);

        let mut segments = store.lock().unwrap().segments(meeting.id).unwrap();
        segments.sort_by_key(|s| s.id);
        let speakers: Vec<&str> = segments.iter().map(|s| s.speaker.as_str()).collect();
        // No label for the last one: it falls back to plain "others".
        assert_eq!(speakers, vec!["Speaker 1", "me", "Speaker 2", "others"]);
    }

    #[test]
    fn silent_utterances_are_not_given_a_voice() {
        struct Nothing;
        impl Transcriber for Nothing {
            fn transcribe(&mut self, _audio: &[f32]) -> Result<(String, String), String> {
                Ok((String::new(), "  ".into()))
            }
        }
        struct Panics;
        impl SpeakerLabeller for Panics {
            fn label(&mut self, _audio: &[f32]) -> Option<String> {
                panic!("asked to label an utterance with no text");
            }
        }
        let store = Arc::new(Mutex::new(NotesStore::in_memory().unwrap()));
        let meeting = store.lock().unwrap().start_meeting("Standup", None, &[]).unwrap();
        let session = MeetingSession::start(meeting.id, store, Box::new(Nothing), Some(Box::new(Panics)), None, VadConfig::default());
        session.feed(AudioSource::System, concat(&[tone(1000), silence(1000)]));
        assert_eq!(session.finish(), SessionReport::default());
    }
}
