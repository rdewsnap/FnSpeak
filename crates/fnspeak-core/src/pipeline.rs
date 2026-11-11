//! The whole dictation path: audio → speech-to-text → spoken commands at
//! the end → rule-based filter → vocabulary fixes → cleanup model →
//! guardrail → text to insert.
//!
//! Every step after speech-to-text has a safe fallback, so a slow or failing
//! cleanup model never loses a dictation: the user gets the filtered text.

use crate::cleanup::{guardrail, needs_model, trim_expanded_terms, Cleaner, CleanupMode, CleanupRequest, Llm};
use crate::commands::split_trailing;
use crate::context::DictationContext;
use crate::filter::filter;
use crate::history::History;
use crate::snippets::{self, SnippetStore};
use crate::stt::{is_silent, sanitize, SttEngine, SttError, SttHints, SAMPLE_RATE};
use crate::vocab::{apply_corrections, apply_suggestions, VocabIndex, AUTO_APPLY_SCORE};
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Terms passed to the speech engine and the cleanup model per dictation.
const VOCAB_PER_DICTATION: usize = 40;

/// Pause detection while dictating looks at the audio in 20 ms frames.
const FRAME_SAMPLES: usize = SAMPLE_RATE as usize / 50;
/// A frame below this RMS level counts as quiet. A bit above `SILENCE_RMS`,
/// which judges whole clips: one frame of breath or room noise shouldn't
/// count as speech, and a quiet stretch inside a word is far shorter than
/// a pause.
const PAUSE_RMS: f32 = 0.008;
/// That level suits a voice close to the microphone. Someone further away,
/// or trailing off at the end of a sentence, speaks below it, and their last
/// words must not be taken for a pause. So the level actually used is a
/// tenth of the loudest frame so far, between this floor and `PAUSE_RMS`.
const PAUSE_RMS_FLOOR: f32 = 0.002;
/// This long a quiet run after speech and the speaker may be done, so what's
/// been said so far is transcribed ahead of time. If they let go without
/// saying more, that transcript is the answer and nothing is left to wait
/// for; if they carry on, it's thrown away.
const AHEAD_SAMPLES: usize = SAMPLE_RATE as usize * 300 / 1000;
/// Least speech (from its first loud frame to the pause) worth transcribing
/// on its own. Shorter chunks give Whisper too little to go on, and it
/// invents text from them.
const MIN_CHUNK_SAMPLES: usize = SAMPLE_RATE as usize;
/// A pause this long, after at least `CHUNK_SAMPLES` of speech, ends a chunk
/// for good: what follows is transcribed separately. Chunks are kept long and
/// only cut at real pauses, because each one is punctuated as if it were a
/// whole utterance. Cutting at every breath turned one sentence into
/// "It works. But, it hasn't been tested."
const CHUNK_PAUSE_SAMPLES: usize = SAMPLE_RATE as usize * 700 / 1000;
const CHUNK_SAMPLES: usize = SAMPLE_RATE as usize * 10;
/// Past this a chunk ends at the next pause of any length, to stay inside
/// the window Whisper handles quickly.
const MAX_CHUNK_SAMPLES: usize = SAMPLE_RATE as usize * 18;

#[derive(Debug, thiserror::Error)]
pub enum PipelineError {
    #[error(transparent)]
    Stt(#[from] SttError),
    #[error("vocabulary error: {0}")]
    Vocab(#[from] crate::vocab::VocabError),
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Timings {
    /// Speech-to-text the user waited for: all of it for `dictate`, only
    /// what ran after `finish` for a session.
    pub stt_ms: u64,
    /// Speech-to-text that ran while the user was still talking.
    #[serde(default)]
    pub stt_live_ms: u64,
    pub cleanup_ms: u64,
    pub total_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DictationResult {
    /// Exactly what the speech engine heard.
    pub raw: String,
    /// After the rule-based filter and high-confidence vocabulary fixes.
    pub filtered: String,
    /// The cleaned text, before adjusting it to the cursor position.
    pub text: String,
    /// What to insert at the cursor (spacing and capitalization adjusted,
    /// plus any line breaks asked for with "new line" or "new paragraph").
    pub insert: String,
    /// The dictation ended with "send it": press Return after inserting.
    pub press_enter: bool,
    pub mode: CleanupMode,
    /// Which cleanup model produced `text`, if one did.
    pub cleaner: Option<String>,
    /// Why the cleanup model's output wasn't used, if it wasn't.
    pub fallback_reason: Option<String>,
    /// How many snippets were expanded in `insert`.
    #[serde(default)]
    pub expanded_snippets: u32,
    /// The cleanup model was left out because the text needed nothing.
    #[serde(default)]
    pub skipped_cleanup: bool,
    pub timings: Timings,
}

pub struct Pipeline {
    stt: Box<dyn SttEngine>,
    cleaner: Option<Box<dyn Cleaner>>,
    pub vocab: VocabIndex,
    pub history: Option<History>,
    /// Trigger phrases that expand to saved text. `None` when the store
    /// couldn't be opened; dictation works without it.
    pub snippets: Option<SnippetStore>,
    pub mode: CleanupMode,
    /// Treat "send it" / "send that" at the end as a request to press Return.
    pub send_command: bool,
}

impl Pipeline {
    pub fn new(stt: Box<dyn SttEngine>, vocab: VocabIndex, mode: CleanupMode) -> Self {
        Pipeline { stt, cleaner: None, vocab, history: None, snippets: None, mode, send_command: false }
    }

    pub fn with_cleaner(mut self, cleaner: Box<dyn Cleaner>) -> Self {
        self.cleaner = Some(cleaner);
        self
    }

    pub fn with_history(mut self, history: History) -> Self {
        self.history = Some(history);
        self
    }

    pub fn set_cleaner(&mut self, cleaner: Option<Box<dyn Cleaner>>) {
        self.cleaner = cleaner;
    }

    pub fn set_stt(&mut self, stt: Box<dyn SttEngine>) {
        self.stt = stt;
    }

    pub fn stt_name(&self) -> &'static str {
        self.stt.name()
    }

    /// The cleanup model, when the current mode uses one.
    pub fn llm(&self) -> Option<Box<dyn Llm>> {
        match self.mode {
            CleanupMode::Local | CleanupMode::Cloud => self.cleaner.as_ref().and_then(|c| c.llm()),
            CleanupMode::FilterOnly | CleanupMode::Raw => None,
        }
    }

    /// Run a recorded clip (16 kHz mono f32) through the whole pipeline.
    pub fn dictate(&mut self, audio: &[f32], ctx: &DictationContext) -> Result<DictationResult, PipelineError> {
        let started = Instant::now();
        let seconds = audio.len() as f32 / SAMPLE_RATE as f32;

        let raw = if is_silent(audio) {
            String::new()
        } else {
            let hints = SttHints { vocabulary: self.vocab.relevant_terms(&ctx.searchable(), &[], VOCAB_PER_DICTATION)? };
            sanitize(&self.stt.transcribe(audio, &hints)?, seconds)
        };
        let stt_ms = started.elapsed().as_millis() as u64;

        let mut result = self.clean(&raw, ctx)?;
        result.timings.stt_ms = stt_ms;
        result.timings.total_ms = started.elapsed().as_millis() as u64;
        self.record(&result, ctx, (seconds * 1000.0) as i64);
        Ok(result)
    }

    /// Start a dictation that's transcribed while it's recorded: feed it
    /// audio with `DictationSession::push` and end it with `finish`.
    pub fn begin_dictation(&self, ctx: &DictationContext) -> Result<DictationSession, PipelineError> {
        let hints = SttHints { vocabulary: self.vocab.relevant_terms(&ctx.searchable(), &[], VOCAB_PER_DICTATION)? };
        Ok(DictationSession {
            ctx: ctx.clone(),
            hints,
            audio: Vec::new(),
            cut: 0,
            scanned: 0,
            peak: 0.0,
            speech_from: None,
            quiet_from: None,
            committed: String::new(),
            ahead: None,
            tried_ahead: false,
            live_stt: Duration::ZERO,
        })
    }

    /// Speech-to-text, the rule-based filter and high-confidence vocabulary
    /// fixes, but no cleanup model: meeting transcripts have to stay faithful
    /// to what was said. `context` is text to pick vocabulary hints from.
    /// Returns the raw and filtered transcripts.
    pub fn transcribe_verbatim(&mut self, audio: &[f32], context: &str) -> Result<(String, String), PipelineError> {
        if is_silent(audio) {
            return Ok((String::new(), String::new()));
        }
        let seconds = audio.len() as f32 / SAMPLE_RATE as f32;
        let hints = SttHints { vocabulary: self.vocab.relevant_terms(context, &[], VOCAB_PER_DICTATION)? };
        let raw = sanitize(&self.stt.transcribe(audio, &hints)?, seconds);
        if raw.is_empty() || self.mode == CleanupMode::Raw {
            return Ok((raw.clone(), raw));
        }
        let filtered = filter(&raw);
        let suggestions = self.vocab.suggest(&filtered)?;
        Ok((raw, apply_suggestions(&filtered, &suggestions, AUTO_APPLY_SCORE)))
    }

    /// Everything after speech-to-text. Also used by the benchmark to score
    /// transcripts that came from elsewhere.
    pub fn clean(&mut self, raw: &str, ctx: &DictationContext) -> Result<DictationResult, PipelineError> {
        let started = Instant::now();
        let mut result = DictationResult {
            raw: raw.to_string(),
            filtered: String::new(),
            text: String::new(),
            insert: String::new(),
            press_enter: false,
            mode: self.mode,
            cleaner: None,
            fallback_reason: None,
            expanded_snippets: 0,
            skipped_cleanup: false,
            timings: Timings::default(),
        };
        if raw.trim().is_empty() {
            return Ok(result);
        }
        if self.mode == CleanupMode::Raw {
            result.filtered = raw.to_string();
            result.text = raw.to_string();
            result.insert = fit_to_cursor(&result.text, ctx);
            return Ok(result);
        }

        // "scratch that", "new line" and friends at the end are instructions,
        // not text; the rest goes on as if they were never said.
        let (spoken, trailing) = split_trailing(raw, self.send_command);
        result.press_enter = trailing.press_enter;
        if spoken.trim().is_empty() {
            result.insert = trailing.breaks;
            return Ok(result);
        }

        let filtered = filter(&spoken);
        let suggestions = self.vocab.suggest(&filtered)?;
        let corrections = self.vocab.corrections()?;
        result.filtered = apply_corrections(&apply_suggestions(&filtered, &suggestions, AUTO_APPLY_SCORE), &corrections);
        result.text = result.filtered.clone();
        // Snippet triggers the speaker said. The model must leave them
        // alone; they're swapped for their text at the very end.
        let active = self.snippets.as_ref().and_then(|s| s.active().ok()).unwrap_or_default();
        let said = snippets::find(&result.filtered, &active);

        let wants_model = matches!(self.mode, CleanupMode::Local | CleanupMode::Cloud);
        // Already clean: the model would hand it back unchanged, a few
        // hundred milliseconds later.
        // If the filter took something out it can leave a stray comma behind
        // ("Can you, um, send" → "Can you, send"), which the model tidies.
        let untouched = filtered.split_whitespace().eq(spoken.split_whitespace());
        let nothing_to_do = wants_model && untouched && !needs_model(&result.filtered, ctx.style(), &suggestions);
        match self.cleaner.as_mut() {
            Some(_) if nothing_to_do => result.skipped_cleanup = true,
            Some(cleaner) if wants_model && !filtered.is_empty() => {
                let mut vocabulary = self.vocab.relevant_terms(&ctx.searchable(), &suggestions, VOCAB_PER_DICTATION)?;
                // Learned spellings in this dictation count as vocabulary, so
                // the guardrail accepts them and the model sees them.
                for c in corrections.iter().filter(|c| result.filtered.contains(c.corrected.as_str())) {
                    if !vocabulary.contains(&c.corrected) {
                        vocabulary.push(c.corrected.clone());
                    }
                }
                for m in &said {
                    let phrase = result.filtered[m.start..m.end].to_string();
                    if !vocabulary.contains(&phrase) {
                        vocabulary.push(phrase);
                    }
                }
                let req = CleanupRequest { transcript: &filtered, context: ctx, vocabulary: &vocabulary, suggestions: &suggestions };
                let cleaned = cleaner.clean(&req).and_then(|out| guardrail(&filtered, &out, &vocabulary).map(|_| out));
                match cleaned {
                    Ok(text) => {
                        // Again on the model's output: it works from the
                        // unfixed transcript and may keep what was misheard.
                        let text = apply_corrections(&trim_expanded_terms(&filtered, &text, &vocabulary), &corrections);
                        if snippets::find(&text, &active).len() < said.len() {
                            // The filtered text still has every trigger.
                            result.fallback_reason = Some("cleanup changed a snippet trigger".into());
                        } else {
                            result.text = text;
                            result.cleaner = Some(cleaner.name());
                        }
                    }
                    Err(e) => result.fallback_reason = Some(e.to_string()),
                }
            }
            None if wants_model => result.fallback_reason = Some("no cleanup model configured".into()),
            _ => {}
        }

        result.timings.cleanup_ms = started.elapsed().as_millis() as u64;
        let (expanded, ranges) = snippets::expand(&result.text, &active);
        result.expanded_snippets = ranges.len() as u32;
        // Snippet text is inserted as saved, capital letter included.
        let starts_with_snippet = ranges.first().is_some_and(|r| r.start == 0);
        result.insert = fit(&expanded, ctx, !starts_with_snippet) + &trailing.breaks;
        Ok(result)
    }

    fn record(&mut self, result: &DictationResult, ctx: &DictationContext, duration_ms: i64) {
        if result.text.is_empty() {
            return;
        }
        // Bookkeeping must never fail a dictation.
        let _ = self.vocab.record_usage(&result.text);
        if let Some(history) = &self.history {
            let mode = serde_json::to_value(result.mode).ok().and_then(|v| v.as_str().map(String::from)).unwrap_or_default();
            let _ = history.save(now(), &ctx.app_id, &result.raw, &result.text, &mode, duration_ms);
        }
    }
}

/// A dictation transcribed while it's being recorded. At each pause the audio
/// so far is transcribed ahead of time, so if the speaker lets go there the
/// text is already done. A long dictation is also split at its longer pauses,
/// so on release only the last stretch is left. Audio is only ever cut inside
/// a pause, never mid-word.
pub struct DictationSession {
    ctx: DictationContext,
    hints: SttHints,
    audio: Vec<f32>,
    /// Start of the audio not transcribed yet.
    cut: usize,
    /// How far pause detection has looked.
    scanned: usize,
    /// The loudest frame so far, which sets what counts as quiet.
    peak: f32,
    /// First loud frame since `cut`.
    speech_from: Option<usize>,
    /// Start of the quiet run after that speech, if we're in one.
    quiet_from: Option<usize>,
    /// What's been transcribed so far, up to `cut`.
    committed: String,
    /// A transcript of the audio from `cut` to the current pause. Dropped as
    /// soon as the speaker says more.
    ahead: Option<Ahead>,
    /// The current pause has had its go at `ahead`, whether or not it worked.
    tried_ahead: bool,
    live_stt: Duration,
}

struct Ahead {
    /// Where in the audio the transcript stops, inside the pause.
    end: usize,
    text: String,
}

impl DictationSession {
    /// Add 16 kHz mono samples. Transcribes the audio since the last cut when
    /// they complete a pause, so call it off the main thread.
    pub fn push(&mut self, pipeline: &mut Pipeline, audio: &[f32]) -> Result<(), PipelineError> {
        self.audio.extend_from_slice(audio);
        while self.scanned + FRAME_SAMPLES <= self.audio.len() {
            let at = self.scanned;
            self.scanned += FRAME_SAMPLES;
            let level = rms(&self.audio[at..self.scanned]);
            self.peak = self.peak.max(level);
            if level >= (self.peak / 10.0).clamp(PAUSE_RMS_FLOOR, PAUSE_RMS) {
                self.speech_from.get_or_insert(at);
                self.quiet_from = None;
                // More speech: whatever was transcribed ahead is out of date.
                self.ahead = None;
                self.tried_ahead = false;
                continue;
            }
            let Some(speech_from) = self.speech_from else { continue };
            let quiet_from = *self.quiet_from.get_or_insert(at);
            let (quiet, speech) = (self.scanned - quiet_from, quiet_from - speech_from);
            if speech < MIN_CHUNK_SAMPLES {
                continue;
            }
            if !self.tried_ahead && quiet >= AHEAD_SAMPLES {
                // Stop most of the way into the pause: the end of a word
                // fades out below the quiet level, and it has to stay whole.
                self.tried_ahead = true;
                self.transcribe_ahead(pipeline, quiet_from + quiet * 2 / 3)?;
            }
            let long_enough = speech >= MAX_CHUNK_SAMPLES || (speech >= CHUNK_SAMPLES && quiet >= CHUNK_PAUSE_SAMPLES);
            if long_enough {
                self.commit();
            }
        }
        Ok(())
    }

    /// Text transcribed and settled so far, before cleanup.
    pub fn committed(&self) -> &str {
        &self.committed
    }

    /// Transcribe what's left and run the result through the rest of the
    /// pipeline, exactly as `Pipeline::dictate` does.
    pub fn finish(mut self, pipeline: &mut Pipeline) -> Result<DictationResult, PipelineError> {
        let started = Instant::now();
        // Nothing was said after the pause `ahead` was made in, so it covers
        // everything; otherwise the rest still has to be transcribed.
        let done_ahead = self.ahead.is_some();
        self.commit();
        let tail = &self.audio[self.cut..];
        let mut raw = self.committed.clone();
        if !done_ahead && !is_silent(tail) {
            let text = pipeline.stt.transcribe_continuing(tail, &self.hints, &raw)?;
            join(&mut raw, &sanitize(&text, seconds(tail)));
        }
        let stt_ms = started.elapsed().as_millis() as u64;

        let mut result = pipeline.clean(&raw, &self.ctx)?;
        result.timings.stt_ms = stt_ms;
        result.timings.stt_live_ms = self.live_stt.as_millis() as u64;
        result.timings.total_ms = started.elapsed().as_millis() as u64;
        pipeline.record(&result, &self.ctx, (seconds(&self.audio) * 1000.0) as i64);
        Ok(result)
    }

    /// Transcribe the audio from the last cut up to `end`, without settling
    /// on it yet.
    fn transcribe_ahead(&mut self, pipeline: &mut Pipeline, end: usize) -> Result<(), PipelineError> {
        let chunk = &self.audio[self.cut..end];
        if is_silent(chunk) {
            self.ahead = Some(Ahead { end, text: String::new() });
            return Ok(());
        }
        let started = Instant::now();
        let text = pipeline.stt.transcribe_continuing(chunk, &self.hints, &self.committed);
        self.live_stt += started.elapsed();
        // On failure nothing is kept, and `finish` tries the audio again.
        let text = sanitize(&text?, seconds(chunk));
        self.ahead = Some(Ahead { end, text });
        Ok(())
    }

    /// Settle on what was transcribed ahead: the next chunk starts after it.
    fn commit(&mut self) {
        let Some(ahead) = self.ahead.take() else { return };
        join(&mut self.committed, &ahead.text);
        self.cut = ahead.end;
        self.speech_from = None;
        self.quiet_from = None;
        self.tried_ahead = false;
    }
}

fn rms(audio: &[f32]) -> f32 {
    (audio.iter().map(|s| s * s).sum::<f32>() / audio.len().max(1) as f32).sqrt()
}

fn seconds(audio: &[f32]) -> f32 {
    audio.len() as f32 / SAMPLE_RATE as f32
}

/// Append a chunk's transcript, skipping empty ones (silence, phantoms).
fn join(text: &mut String, piece: &str) {
    if piece.is_empty() {
        return;
    }
    if !text.is_empty() {
        text.push(' ');
    }
    text.push_str(piece);
}

/// Words that only start with a capital because they started the dictation.
const LOWERCASE_MID_SENTENCE: &[&str] = &[
    "a", "an", "the", "and", "but", "or", "so", "then", "also", "because", "which", "that", "this", "these",
    "those", "it", "its", "we", "you", "they", "he", "she", "to", "for", "with", "in", "on", "at", "of",
    "if", "when", "while", "maybe", "just", "not", "is", "are", "was", "were", "can", "will", "should",
    "would", "could", "my", "our", "your", "their", "there", "here", "what", "how", "why",
];

/// Adjust cleaned text to where it's being inserted: add a separating space
/// after existing text, and don't capitalize a continuation mid-sentence.
pub fn fit_to_cursor(text: &str, ctx: &DictationContext) -> String {
    fit(text, ctx, true)
}

/// `may_lowercase` is false when the text starts with a snippet.
fn fit(text: &str, ctx: &DictationContext, may_lowercase: bool) -> String {
    let before = ctx.text_before.as_str();
    let Some(last) = before.chars().next_back() else {
        return text.to_string();
    };
    let mut out = String::with_capacity(text.len() + 1);
    let needs_space = !last.is_whitespace() && text.chars().next().is_some_and(|c| c.is_alphanumeric());
    if needs_space {
        out.push(' ');
    }

    let mid_sentence = before.trim_end().chars().next_back().is_some_and(|c| !matches!(c, '.' | '!' | '?' | ':' | '\n'));
    let first_word: String = text.chars().take_while(|c| c.is_alphabetic()).collect();
    if may_lowercase && mid_sentence && LOWERCASE_MID_SENTENCE.contains(&first_word.to_lowercase().as_str()) && !text.contains('\n') {
        let mut chars = text.chars();
        if let Some(c) = chars.next() {
            out.extend(c.to_lowercase());
            out.push_str(chars.as_str());
            // A single mid-sentence clause shouldn't get a period it didn't have.
            return out;
        }
    }
    out.push_str(text);
    out
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cleanup::CleanupError;
    use crate::stt::FixedTranscript;
    use crate::vocab::Source;

    struct Echo(&'static str);
    impl Cleaner for Echo {
        fn name(&self) -> String {
            "echo".into()
        }
        fn clean(&mut self, _req: &CleanupRequest<'_>) -> Result<String, CleanupError> {
            Ok(self.0.to_string())
        }
    }

    fn pipeline(transcript: &str, mode: CleanupMode) -> Pipeline {
        let mut vocab = VocabIndex::in_memory().unwrap();
        vocab.add_terms(Source::Project, ["Kinju"]).unwrap();
        Pipeline::new(Box::new(FixedTranscript(transcript.into())), vocab, mode)
    }

    fn speech() -> Vec<f32> {
        (0..16_000).map(|i| (i as f32 * 0.05).sin() * 0.2).collect()
    }

    fn with_snippet(mut p: Pipeline, trigger: &str, text: &str) -> Pipeline {
        let mut store = crate::snippets::SnippetStore::in_memory().unwrap();
        store.add(trigger, text).unwrap();
        p.snippets = Some(store);
        p
    }

    #[test]
    fn filter_only_applies_filter_and_vocab() {
        let mut p = pipeline("um so the kin ju build is is green", CleanupMode::FilterOnly);
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.text, "So the Kinju build is green");
        assert!(r.fallback_reason.is_none());
    }

    #[test]
    fn uses_model_output_when_guardrail_passes() {
        let mut p = pipeline("send it to Sam actually Priya", CleanupMode::Cloud).with_cleaner(Box::new(Echo("Send it to Priya.")));
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.text, "Send it to Priya.");
        assert_eq!(r.cleaner.as_deref(), Some("echo"));
    }

    #[test]
    fn falls_back_when_model_invents_text() {
        let mut p = pipeline("what's the weather like in Paris today", CleanupMode::Cloud)
            .with_cleaner(Box::new(Echo("It is sunny and warm in Paris with highs around twenty five degrees all week.")));
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.text, "what's the weather like in Paris today");
        assert!(r.fallback_reason.unwrap().contains("rejected"));
    }

    #[test]
    fn applies_learned_corrections_without_a_model() {
        let mut p = pipeline("ask priya to review the PG vector change", CleanupMode::FilterOnly);
        p.vocab.learn_from_edit("Ask Priya to review it.", "Ask Pria to review it.").unwrap();
        p.vocab.record_correction("pg vector", "pgvector").unwrap();
        p.vocab.record_correction("pg vector", "pgvector").unwrap();
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.text, "ask Pria to review the pgvector change");
    }

    #[test]
    fn learned_corrections_survive_the_model() {
        let mut p = pipeline("um tell kenju the build is green", CleanupMode::Cloud)
            .with_cleaner(Box::new(Echo("Tell Kenju the build is green.")));
        p.vocab.learn_from_edit("Tell Kenju hi.", "Tell Kinju hi.").unwrap();
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.text, "Tell Kinju the build is green.");
        assert_eq!(r.cleaner.as_deref(), Some("echo"));
    }

    #[test]
    fn spoken_commands_at_the_end() {
        let mut p = pipeline("Thanks for the update. Um wrong part. Scratch that. New paragraph.", CleanupMode::FilterOnly);
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!((r.text.as_str(), r.insert.as_str(), r.press_enter), ("Thanks for the update.", "Thanks for the update.\n\n", false));

        // "send it" only when the app allows it.
        let mut p = pipeline("On my way. Send it.", CleanupMode::FilterOnly);
        assert_eq!(p.dictate(&speech(), &DictationContext::default()).unwrap().text, "On my way. Send it.");
        p.send_command = true;
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!((r.insert.as_str(), r.press_enter), ("On my way.", true));

        // Without a pause before it, it's just words.
        let mut p = pipeline("add a new line", CleanupMode::FilterOnly);
        assert_eq!(p.dictate(&speech(), &DictationContext::default()).unwrap().insert, "add a new line");

        // The model never sees the command.
        let mut p = pipeline("So ship it Friday. New line.", CleanupMode::Cloud).with_cleaner(Box::new(Echo("Ship it Friday.")));
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!((r.insert.as_str(), r.cleaner.as_deref()), ("Ship it Friday.\n", Some("echo")));

        // A command on its own still does something.
        let mut p = pipeline("Send it.", CleanupMode::FilterOnly);
        p.send_command = true;
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!((r.insert.as_str(), r.press_enter), ("", true));
    }

    #[test]
    fn raw_mode_skips_everything() {
        let mut p = pipeline("um hello", CleanupMode::Raw);
        assert_eq!(p.dictate(&speech(), &DictationContext::default()).unwrap().text, "um hello");
    }

    #[test]
    fn silence_produces_nothing() {
        let mut p = pipeline("Thank you.", CleanupMode::FilterOnly);
        let r = p.dictate(&vec![0.0; 16_000], &DictationContext::default()).unwrap();
        assert_eq!(r.insert, "");
    }

    #[test]
    fn verbatim_transcription_skips_the_model() {
        let mut p = pipeline("um so the kin ju build is is green", CleanupMode::Cloud).with_cleaner(Box::new(Echo("Rewritten.")));
        let (raw, text) = p.transcribe_verbatim(&speech(), "").unwrap();
        assert_eq!(raw, "um so the kin ju build is is green");
        assert_eq!(text, "So the Kinju build is green");
        assert_eq!(p.transcribe_verbatim(&vec![0.0; 16_000], "").unwrap().0, "");
    }

    #[test]
    fn records_history() {
        let mut p = pipeline("ship it", CleanupMode::FilterOnly).with_history(History::in_memory().unwrap());
        p.dictate(&speech(), &DictationContext { app_id: "com.apple.mail".into(), ..Default::default() }).unwrap();
        let last = p.history.as_ref().unwrap().last().unwrap().unwrap();
        assert_eq!((last.raw.as_str(), last.mode.as_str()), ("ship it", "filter_only"));
    }

    /// Hands out one transcript per call and remembers the text each call
    /// was told came before it.
    struct Chunks {
        texts: Vec<&'static str>,
        preceding: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
    }
    impl crate::stt::SttEngine for Chunks {
        fn name(&self) -> &'static str {
            "chunks"
        }
        fn transcribe(&mut self, audio: &[f32], hints: &SttHints) -> Result<String, SttError> {
            self.transcribe_continuing(audio, hints, "")
        }
        fn transcribe_continuing(&mut self, _audio: &[f32], _hints: &SttHints, preceding: &str) -> Result<String, SttError> {
            let mut seen = self.preceding.lock().unwrap();
            let text = self.texts.get(seen.len()).copied().unwrap_or("");
            seen.push(preceding.to_string());
            Ok(text.to_string())
        }
    }

    fn chunked(texts: Vec<&'static str>) -> (Pipeline, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
        let preceding = std::sync::Arc::default();
        let stt = Chunks { texts, preceding: std::sync::Arc::clone(&preceding) };
        (Pipeline::new(Box::new(stt), VocabIndex::in_memory().unwrap(), CleanupMode::Raw), preceding)
    }

    fn tone(seconds: f32) -> Vec<f32> {
        (0..(seconds * 16_000.0) as usize).map(|i| (i as f32 * 0.05).sin() * 0.2).collect()
    }

    fn quiet(seconds: f32) -> Vec<f32> {
        vec![0.0; (seconds * 16_000.0) as usize]
    }

    /// Feed a session the way the app does, a quarter second at a time.
    fn feed(p: &mut Pipeline, s: &mut DictationSession, audio: &[f32]) {
        for piece in audio.chunks(4_000) {
            s.push(p, piece).unwrap();
        }
    }

    #[test]
    fn session_splits_a_long_dictation_at_a_real_pause() {
        let (mut p, preceding) = chunked(vec!["Ship the build today.", "Then tell Sam."]);
        let mut s = p.begin_dictation(&DictationContext::default()).unwrap();
        feed(&mut p, &mut s, &[tone(10.5), quiet(0.8)].concat());
        assert_eq!(s.committed(), "Ship the build today.");
        feed(&mut p, &mut s, &tone(1.0));
        let r = s.finish(&mut p).unwrap();
        assert_eq!(r.raw, "Ship the build today. Then tell Sam.");
        assert_eq!(*preceding.lock().unwrap(), ["", "Ship the build today."]);
    }

    #[test]
    fn session_is_done_ahead_of_time_when_nothing_follows_a_pause() {
        let (mut p, preceding) = chunked(vec!["Ship the build today."]);
        let mut s = p.begin_dictation(&DictationContext::default()).unwrap();
        feed(&mut p, &mut s, &[tone(1.5), quiet(0.5)].concat());
        // Transcribed during the pause, but not settled: more could follow.
        assert_eq!(s.committed(), "");
        assert_eq!(preceding.lock().unwrap().len(), 1);
        let r = s.finish(&mut p).unwrap();
        assert_eq!(r.raw, "Ship the build today.");
        // Letting go cost no more speech-to-text.
        assert_eq!(preceding.lock().unwrap().len(), 1);
    }

    #[test]
    fn session_hears_a_quiet_ending() {
        // Trailing off: the last words are far quieter than the first, but
        // well above the room. They aren't a pause.
        let normal: Vec<f32> = tone(1.5).iter().map(|s| s * 0.15).collect();
        let soft: Vec<f32> = tone(1.0).iter().map(|s| s * 0.03).collect();
        let (mut p, preceding) = chunked(vec!["It works, but", "It works, but it hasn't been tested."]);
        let mut s = p.begin_dictation(&DictationContext::default()).unwrap();
        feed(&mut p, &mut s, &[normal, quiet(0.4), soft, quiet(0.1)].concat());
        let r = s.finish(&mut p).unwrap();
        assert_eq!(r.raw, "It works, but it hasn't been tested.");
        assert_eq!(preceding.lock().unwrap().len(), 2);
    }

    #[test]
    fn session_keeps_a_short_dictation_in_one_piece() {
        // A breath mid-sentence must not split it into two "sentences".
        let (mut p, preceding) = chunked(vec!["It works.", "It works, but it hasn't been tested."]);
        let mut s = p.begin_dictation(&DictationContext::default()).unwrap();
        feed(&mut p, &mut s, &[tone(1.5), quiet(0.5), tone(1.5)].concat());
        let r = s.finish(&mut p).unwrap();
        assert_eq!(r.raw, "It works, but it hasn't been tested.");
        // Both passes started from nothing: the whole dictation was redone.
        assert_eq!(*preceding.lock().unwrap(), ["", ""]);
    }

    #[test]
    fn session_never_cuts_the_first_second_of_speech() {
        let (mut p, preceding) = chunked(vec!["Yes, ship it."]);
        let mut s = p.begin_dictation(&DictationContext::default()).unwrap();
        feed(&mut p, &mut s, &[quiet(1.0), tone(0.6), quiet(0.6), tone(0.6)].concat());
        assert_eq!(s.committed(), "");
        assert_eq!(s.finish(&mut p).unwrap().raw, "Yes, ship it.");
        assert_eq!(preceding.lock().unwrap().len(), 1);
    }

    #[test]
    fn session_drops_phantom_chunks() {
        let (mut p, _) = chunked(vec!["Thank you.", "Ship it."]);
        let mut s = p.begin_dictation(&DictationContext::default()).unwrap();
        feed(&mut p, &mut s, &[tone(1.2), quiet(0.6), tone(1.0)].concat());
        assert_eq!(s.finish(&mut p).unwrap().raw, "Ship it.");
    }

    #[test]
    fn short_session_matches_dictate() {
        let audio = [speech(), quiet(0.2)].concat();
        let ctx = DictationContext { text_before: "I think ".into(), ..Default::default() };
        let mut p = pipeline("um so the kin ju build is is green", CleanupMode::FilterOnly);
        let expected = p.dictate(&audio, &ctx).unwrap();
        let mut s = p.begin_dictation(&ctx).unwrap();
        feed(&mut p, &mut s, &audio);
        let r = s.finish(&mut p).unwrap();
        assert_eq!((r.raw, r.filtered, r.text, r.insert), (expected.raw, expected.filtered, expected.text, expected.insert));
        assert_eq!(r.timings.stt_live_ms, 0);
    }

    #[test]
    fn silent_session_produces_nothing() {
        let (mut p, preceding) = chunked(vec!["Thank you for watching, see you next time."]);
        let mut s = p.begin_dictation(&DictationContext::default()).unwrap();
        feed(&mut p, &mut s, &quiet(3.0));
        let r = s.finish(&mut p).unwrap();
        assert_eq!((r.raw.as_str(), r.insert.as_str()), ("", ""));
        assert!(preceding.lock().unwrap().is_empty());
    }

    #[test]
    fn fits_text_to_cursor() {
        let ctx = |before: &str| DictationContext { text_before: before.into(), ..Default::default() };
        assert_eq!(fit_to_cursor("We should ship.", &ctx("")), "We should ship.");
        assert_eq!(fit_to_cursor("We should ship.", &ctx("Done.")), " We should ship.");
        assert_eq!(fit_to_cursor("We should ship.", &ctx("Done. ")), "We should ship.");
        assert_eq!(fit_to_cursor("We should ship", &ctx("I think ")), "we should ship");
        assert_eq!(fit_to_cursor("Priya agreed", &ctx("and then ")), "Priya agreed");
    }

    #[test]
    fn expands_a_snippet_in_the_insert_only() {
        let p = pipeline("Grab a time on my calendar link, thanks.", CleanupMode::FilterOnly);
        let mut p = with_snippet(p, "my calendar link", "https://cal.com/ryan");
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.insert, "Grab a time on https://cal.com/ryan, thanks.");
        assert_eq!(r.text, "Grab a time on my calendar link, thanks.");
        assert_eq!(r.expanded_snippets, 1);
    }

    #[test]
    fn no_snippets_means_no_change() {
        let mut p = pipeline("Grab a time on my calendar link, thanks.", CleanupMode::FilterOnly);
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!((r.insert.as_str(), r.expanded_snippets), ("Grab a time on my calendar link, thanks.", 0));
    }

    #[test]
    fn a_model_that_keeps_the_trigger_is_used() {
        let p = pipeline("So um grab a time on my calendar link, thanks.", CleanupMode::Cloud)
            .with_cleaner(Box::new(Echo("Grab a time on my calendar link. Thanks.")));
        let mut p = with_snippet(p, "my calendar link", "https://cal.com/ryan");
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.cleaner.as_deref(), Some("echo"));
        assert_eq!(r.insert, "Grab a time on https://cal.com/ryan. Thanks.");
    }

    #[test]
    fn a_model_that_rewords_the_trigger_is_dropped() {
        let p = pipeline("So grab a time on my calendar link, thanks.", CleanupMode::Cloud)
            .with_cleaner(Box::new(Echo("Grab a time on my calendar. Thanks.")));
        let mut p = with_snippet(p, "my calendar link", "https://cal.com/ryan");
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.cleaner, None);
        assert_eq!(r.fallback_reason.as_deref(), Some("cleanup changed a snippet trigger"));
        assert_eq!(r.insert, "So grab a time on https://cal.com/ryan, thanks.");
    }

    #[test]
    fn clean_text_never_reaches_the_model() {
        // The echo would change the text if it were asked.
        let mut p = pipeline("Are there vehicles?", CleanupMode::Cloud).with_cleaner(Box::new(Echo("Something else entirely.")));
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!((r.text.as_str(), r.cleaner, r.fallback_reason), ("Are there vehicles?", None, None));
        assert!(r.skipped_cleanup);

        // So is anything the rule-based filter had to touch.
        let mut p = pipeline("Can you, um, send me the deck?", CleanupMode::Cloud).with_cleaner(Box::new(Echo("Can you send me the deck?")));
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!((r.text.as_str(), r.skipped_cleanup), ("Can you send me the deck?", false));

        // A filler is the model's call.
        let mut p = pipeline("I mean, are there vehicles?", CleanupMode::Cloud).with_cleaner(Box::new(Echo("Are there vehicles?")));
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!((r.text.as_str(), r.cleaner.as_deref(), r.skipped_cleanup), ("Are there vehicles?", Some("echo"), false));
    }

    #[test]
    fn raw_mode_leaves_triggers_alone() {
        let p = pipeline("grab a time on my calendar link", CleanupMode::Raw);
        let mut p = with_snippet(p, "my calendar link", "https://cal.com/ryan");
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!((r.insert.as_str(), r.expanded_snippets), ("grab a time on my calendar link", 0));
    }

    #[test]
    fn snippet_text_at_the_start_keeps_its_capital() {
        let p = pipeline("Team intro line.", CleanupMode::FilterOnly);
        let mut p = with_snippet(p, "team intro line", "The FnSpeak team builds dictation");
        let ctx = DictationContext { text_before: "I think ".into(), ..Default::default() };
        let r = p.dictate(&speech(), &ctx).unwrap();
        // "The" is a word fit_to_cursor would lowercase mid-sentence.
        assert_eq!(r.insert, "The FnSpeak team builds dictation.");
    }

    #[test]
    fn spoken_commands_still_work_after_a_snippet() {
        let p = pipeline("Here is my calendar link. New line.", CleanupMode::FilterOnly);
        let mut p = with_snippet(p, "my calendar link", "https://cal.com/ryan");
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.insert, "Here is https://cal.com/ryan.\n");
    }
}
