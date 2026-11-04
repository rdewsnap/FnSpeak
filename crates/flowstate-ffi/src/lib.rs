//! The surface the native shells talk to. Swift bindings are generated with
//! `uniffi-bindgen` (see `scripts/build-mac.sh`); a C# binding can come from
//! the same definitions when the Windows shell lands.

use flowstate_core::cleanup::{AnthropicCleaner, Cleaner, FlowstateCleaner, LocalCleaner, LocalConfig, OpenAiCompatCleaner, RoutedCleaner};
use flowstate_core::context::Style;
use flowstate_core::history::History;
use flowstate_core::meeting::{self as live, MeetingSession, PipelineTranscriber, SegmentListener, VadConfig};
use flowstate_core::notes::{self, NotesStore};
use flowstate_core::stt::SttEngine;
use flowstate_core::summary;
use flowstate_core::tier::HardwareInfo;
use flowstate_core::vocab::{self, VocabIndex};
use flowstate_core::pipeline::DictationSession;
use flowstate_core::{CleanupMode, DictationContext, DictationResult, Pipeline};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FlowstateError {
    #[error("{0}")]
    Setup(String),
    #[error("{0}")]
    Dictation(String),
    #[error("{0}")]
    Storage(String),
    #[error("{0}")]
    Meeting(String),
}

fn setup_err(e: impl std::fmt::Display) -> FlowstateError {
    FlowstateError::Setup(e.to_string())
}

fn storage_err(e: impl std::fmt::Display) -> FlowstateError {
    FlowstateError::Storage(e.to_string())
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum Mode {
    Local,
    Cloud,
    FilterOnly,
    Raw,
}

impl From<Mode> for CleanupMode {
    fn from(m: Mode) -> Self {
        match m {
            Mode::Local => CleanupMode::Local,
            Mode::Cloud => CleanupMode::Cloud,
            Mode::FilterOnly => CleanupMode::FilterOnly,
            Mode::Raw => CleanupMode::Raw,
        }
    }
}

impl From<CleanupMode> for Mode {
    fn from(m: CleanupMode) -> Self {
        match m {
            CleanupMode::Local => Mode::Local,
            CleanupMode::Cloud => Mode::Cloud,
            CleanupMode::FilterOnly => Mode::FilterOnly,
            CleanupMode::Raw => Mode::Raw,
        }
    }
}

#[derive(Clone, Debug, uniffi::Enum)]
pub enum SpeechEngine {
    Whisper { model_path: String },
    Parakeet { model_dir: String },
}

#[derive(Clone, Debug, uniffi::Enum)]
pub enum CloudProvider {
    Anthropic,
    /// Groq, OpenRouter, OpenAI, Ollama, LM Studio.
    OpenAiCompatible { base_url: String },
    /// A Flowstate server's API root (`…/v1`), with the account token as
    /// the key. Cleanup and meeting summaries both run on the server.
    Flowstate { base_url: String },
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudConfig {
    pub provider: CloudProvider,
    pub api_key: Option<String>,
    /// Model for dictations with self-corrections.
    pub model: String,
    /// Cheaper model for everything else; same as `model` when unset.
    pub light_model: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LocalModel {
    /// The `llama-server` binary, usually bundled in the app.
    pub server_binary: String,
    /// GGUF cleanup model.
    pub model_path: String,
    /// A smaller, faster GGUF for dictations without self-corrections. Runs
    /// as a second server; unset or the same as `model_path` means one model
    /// does everything.
    pub light_model_path: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct EngineConfig {
    /// Where the vocabulary, history and notes databases live.
    pub data_dir: String,
    pub speech: SpeechEngine,
    pub mode: Mode,
    pub local: Option<LocalModel>,
    pub cloud: Option<CloudConfig>,
}

/// How the cleanup model should write.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum WritingStyle {
    /// Chat: relaxed, light punctuation.
    Casual,
    /// Email and documents: full sentences and paragraphs.
    Prose,
    /// Editors and terminals: identifiers and symbols kept exactly.
    Code,
}

impl From<WritingStyle> for Style {
    fn from(s: WritingStyle) -> Self {
        match s {
            WritingStyle::Casual => Style::Casual,
            WritingStyle::Prose => Style::Prose,
            WritingStyle::Code => Style::Code,
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Context {
    pub app_id: String,
    pub app_name: String,
    pub window_title: String,
    pub url: Option<String>,
    pub text_before: String,
    /// The style chosen in settings for this app. None lets the core pick
    /// one from the app id and URL.
    #[uniffi(default)]
    pub style: Option<WritingStyle>,
}

impl From<Context> for DictationContext {
    fn from(c: Context) -> Self {
        DictationContext {
            app_id: c.app_id,
            app_name: c.app_name,
            window_title: c.window_title,
            url: c.url,
            text_before: c.text_before,
            style: c.style.map(Style::from),
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Dictation {
    pub raw: String,
    pub text: String,
    /// What to insert at the cursor, line breaks from "new line" included.
    pub insert: String,
    /// The dictation ended with "send it": press Return after inserting.
    /// Only ever true after `set_send_command(true)`.
    pub press_enter: bool,
    pub mode: Mode,
    pub cleaner: Option<String>,
    pub fallback_reason: Option<String>,
    /// Speech-to-text after the recording ended, what the user waited for.
    pub stt_ms: u64,
    /// Speech-to-text that ran while still recording (sessions only).
    pub stt_live_ms: u64,
    pub cleanup_ms: u64,
    pub total_ms: u64,
}

impl From<DictationResult> for Dictation {
    fn from(r: DictationResult) -> Self {
        Dictation {
            raw: r.raw,
            text: r.text,
            insert: r.insert,
            press_enter: r.press_enter,
            mode: r.mode.into(),
            cleaner: r.cleaner,
            fallback_reason: r.fallback_reason,
            stt_ms: r.timings.stt_ms,
            stt_live_ms: r.timings.stt_live_ms,
            cleanup_ms: r.timings.cleanup_ms,
            total_ms: r.timings.total_ms,
        }
    }
}

fn dictation_err(e: impl std::fmt::Display) -> FlowstateError {
    FlowstateError::Dictation(e.to_string())
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum TermSource {
    Project,
    Contact,
    Calendar,
    User,
    Correction,
    Learned,
    /// The shared glossary of the user's teams on a Flowstate server.
    Team,
}

impl From<TermSource> for vocab::Source {
    fn from(s: TermSource) -> Self {
        match s {
            TermSource::Project => vocab::Source::Project,
            TermSource::Contact => vocab::Source::Contact,
            TermSource::Calendar => vocab::Source::Calendar,
            TermSource::User => vocab::Source::User,
            TermSource::Correction => vocab::Source::Correction,
            TermSource::Learned => vocab::Source::Learned,
            TermSource::Team => vocab::Source::Team,
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LearnedCorrection {
    /// What Flowstate wrote, lowercased. Pass back to `forget_correction`.
    pub heard: String,
    /// The user's spelling, now applied to new dictations.
    pub corrected: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Term {
    pub text: String,
    pub source: String,
    pub hits: i64,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Hardware {
    pub total_memory_gb: f64,
    pub apple_silicon: bool,
    pub gpu_memory_gb: Option<f64>,
    pub recommended_mode: Mode,
}

/// First-run hardware check. The shell can add GPU memory on Windows and
/// call `recommended_mode_for` again.
#[uniffi::export]
pub fn detect_hardware() -> Hardware {
    let hw = HardwareInfo::detect();
    Hardware {
        total_memory_gb: hw.total_memory_gb,
        apple_silicon: hw.apple_silicon,
        gpu_memory_gb: hw.gpu_memory_gb,
        recommended_mode: hw.default_cleanup_mode().into(),
    }
}

#[uniffi::export]
pub fn recommended_mode_for(total_memory_gb: f64, apple_silicon: bool, gpu_memory_gb: Option<f64>, measured_tokens_per_sec: Option<f64>) -> Mode {
    HardwareInfo { total_memory_gb, apple_silicon, gpu_memory_gb, measured_tokens_per_sec }.default_cleanup_mode().into()
}

/// Terms from a projects folder (project, package and README names).
#[uniffi::export]
pub fn scan_projects(root: String) -> Result<Vec<String>, FlowstateError> {
    vocab::projects::index_projects(Path::new(&root)).map_err(storage_err)
}

#[derive(uniffi::Object)]
pub struct FlowstateEngine {
    // Shared with the meeting worker, which transcribes through it.
    pipeline: Arc<Mutex<Pipeline>>,
    notes: Arc<Mutex<NotesStore>>,
    meeting: Mutex<Option<MeetingSession>>,
    /// The dictation being recorded, if it's transcribed as it goes.
    dictation: Mutex<Option<DictationSession>>,
    listener: Arc<RwLock<Option<Arc<dyn MeetingListener>>>>,
}

#[uniffi::export]
impl FlowstateEngine {
    #[uniffi::constructor]
    pub fn new(config: EngineConfig) -> Result<Arc<Self>, FlowstateError> {
        let dir = PathBuf::from(&config.data_dir);
        std::fs::create_dir_all(&dir).map_err(storage_err)?;
        let vocab = VocabIndex::open(dir.join("vocabulary.db")).map_err(storage_err)?;
        let history = History::open(dir.join("history.db")).map_err(storage_err)?;
        let notes = NotesStore::open(dir.join("notes.db")).map_err(storage_err)?;
        // A meeting still "recording" means the app quit or crashed mid-meeting.
        notes.recover_interrupted().map_err(storage_err)?;

        let mut pipeline = Pipeline::new(build_stt(&config.speech)?, vocab, config.mode.into()).with_history(history);
        pipeline.set_cleaner(build_cleaner(config.mode.into(), config.local.as_ref(), config.cloud.as_ref())?);
        Ok(Arc::new(FlowstateEngine {
            pipeline: Arc::new(Mutex::new(pipeline)),
            notes: Arc::new(Mutex::new(notes)),
            meeting: Mutex::new(None),
            dictation: Mutex::new(None),
            listener: Arc::new(RwLock::new(None)),
        }))
    }

    /// Transcribe and clean a clip of 16 kHz mono f32 samples.
    pub fn dictate(&self, audio: Vec<f32>, context: Context) -> Result<Dictation, FlowstateError> {
        let mut p = self.pipeline.lock().unwrap();
        p.dictate(&audio, &context.into()).map(Dictation::from).map_err(dictation_err)
    }

    /// Start a dictation that's transcribed while it's recorded. Feed it with
    /// `push_audio` and end it with `finish_dictation` or `cancel_dictation`.
    /// Replaces a dictation that was never finished.
    pub fn begin_dictation(&self, context: Context) -> Result<(), FlowstateError> {
        let session = self.pipeline.lock().unwrap().begin_dictation(&context.into()).map_err(dictation_err)?;
        *self.dictation.lock().unwrap() = Some(session);
        Ok(())
    }

    /// Add 16 kHz mono samples to the running dictation. Blocks while a
    /// finished stretch of speech is transcribed. Does nothing when no
    /// dictation is running.
    pub fn push_audio(&self, samples: Vec<f32>) -> Result<(), FlowstateError> {
        // Always the dictation slot before the pipeline, like finish.
        let mut slot = self.dictation.lock().unwrap();
        let Some(session) = slot.as_mut() else { return Ok(()) };
        let mut p = self.pipeline.lock().unwrap();
        session.push(&mut p, &samples).map_err(dictation_err)
    }

    /// Transcribe the rest of the running dictation and clean it up.
    pub fn finish_dictation(&self) -> Result<Dictation, FlowstateError> {
        let session = self.dictation.lock().unwrap().take();
        let session = session.ok_or_else(|| FlowstateError::Dictation("no dictation is running".into()))?;
        let mut p = self.pipeline.lock().unwrap();
        session.finish(&mut p).map(Dictation::from).map_err(dictation_err)
    }

    /// Throw away the running dictation, if any.
    pub fn cancel_dictation(&self) {
        self.dictation.lock().unwrap().take();
    }

    pub fn configure_cleanup(&self, mode: Mode, local: Option<LocalModel>, cloud: Option<CloudConfig>) -> Result<(), FlowstateError> {
        let cleaner = build_cleaner(mode.into(), local.as_ref(), cloud.as_ref())?;
        let mut p = self.pipeline.lock().unwrap();
        p.mode = mode.into();
        p.set_cleaner(cleaner);
        Ok(())
    }

    /// Let "send it" / "send that" at the end of a dictation set
    /// `press_enter`. Off by default: in a chat app it sends the message.
    pub fn set_send_command(&self, enabled: bool) {
        self.pipeline.lock().unwrap().send_command = enabled;
    }

    pub fn set_speech_engine(&self, speech: SpeechEngine) -> Result<(), FlowstateError> {
        let stt = build_stt(&speech)?;
        self.pipeline.lock().unwrap().set_stt(stt);
        Ok(())
    }

    pub fn add_terms(&self, source: TermSource, terms: Vec<String>) -> Result<u32, FlowstateError> {
        let mut p = self.pipeline.lock().unwrap();
        p.vocab.add_terms(source.into(), terms).map(|n| n as u32).map_err(storage_err)
    }

    /// Replace every term from a source, e.g. after re-reading contacts.
    pub fn replace_terms(&self, source: TermSource, terms: Vec<String>) -> Result<u32, FlowstateError> {
        let mut p = self.pipeline.lock().unwrap();
        p.vocab.replace_source(source.into(), terms).map(|n| n as u32).map_err(storage_err)
    }

    pub fn remove_term(&self, term: String) -> Result<bool, FlowstateError> {
        self.pipeline.lock().unwrap().vocab.remove_term(&term).map_err(storage_err)
    }

    pub fn terms(&self) -> Result<Vec<Term>, FlowstateError> {
        let p = self.pipeline.lock().unwrap();
        let terms = p.vocab.terms(None).map_err(storage_err)?;
        Ok(terms
            .into_iter()
            .map(|t| Term {
                text: t.text,
                source: source_name(t.source),
                hits: t.hits,
            })
            .collect())
    }

    /// The user edited inserted text: learn the corrected spelling.
    pub fn record_correction(&self, heard: String, corrected: String) -> Result<(), FlowstateError> {
        self.pipeline.lock().unwrap().vocab.record_correction(&heard, &corrected).map(|_| ()).map_err(storage_err)
    }

    /// The user edited a dictation after it was inserted. `inserted` is what
    /// Flowstate typed, `final_text` the same region of the field now. Returns
    /// corrections that start applying because of this edit.
    pub fn learn_from_edit(&self, inserted: String, final_text: String) -> Result<Vec<LearnedCorrection>, FlowstateError> {
        let mut p = self.pipeline.lock().unwrap();
        let learned = p.vocab.learn_from_edit(&inserted, &final_text).map_err(storage_err)?;
        Ok(learned.into_iter().map(|c| LearnedCorrection { heard: c.heard, corrected: c.corrected }).collect())
    }

    /// Undo something `learn_from_edit` learned.
    pub fn forget_correction(&self, heard: String, corrected: String) -> Result<bool, FlowstateError> {
        self.pipeline.lock().unwrap().vocab.forget_correction(&heard, &corrected).map_err(storage_err)
    }

    /// Raw transcript of the most recent dictation, for the swap-to-raw shortcut.
    pub fn last_raw(&self) -> Option<String> {
        let p = self.pipeline.lock().unwrap();
        p.history.as_ref().and_then(|h| h.last().ok().flatten()).map(|e| e.raw)
    }

    pub fn purge_history(&self, older_than_days: u32) -> Result<u32, FlowstateError> {
        let p = self.pipeline.lock().unwrap();
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
        match &p.history {
            Some(h) => h.purge_older_than(now, older_than_days).map(|n| n as u32).map_err(storage_err),
            None => Ok(0),
        }
    }
}

/*
 * Notes and meetings. Everything is stored in `notes.db` in the data dir.
 *
 * Notes:     create_note, update_note, delete_note, notes(limit)
 * Search:    search(query) covers notes, meeting titles and summaries, and
 *            transcripts; snippets mark matches with **bold**.
 * Meetings:  start_meeting → feed_meeting_audio (repeatedly, from the audio
 *            threads) → finish_meeting. One meeting at a time.
 *            meetings(limit), meeting(id), delete_meeting(id),
 *            summarize_meeting(id) to retry a summary,
 *            export_meeting_markdown(id). Afterwards: rename_meeting,
 *            update_meeting_participants, set_action_item_done.
 * Live view: set_meeting_listener; segment() is called on a background
 *            thread as each utterance is transcribed. Segments can arrive
 *            slightly out of order across the two sources; sort by
 *            started_ms.
 *
 * Speakers: the mic stream is "me", the system-audio stream is "others".
 * Feed both streams continuously from the start, silence included, at
 * 16 kHz mono f32: timestamps are counted in samples per stream.
 *
 * Calls that may run the cleanup model (finish_meeting, summarize_meeting,
 * create_note and update_note with an empty title) block for as long as
 * the model takes; call them off the main thread.
 */

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum NoteSource {
    Quick,
    Meeting,
    Dictation,
}

impl From<NoteSource> for notes::NoteSource {
    fn from(s: NoteSource) -> Self {
        match s {
            NoteSource::Quick => notes::NoteSource::Quick,
            NoteSource::Meeting => notes::NoteSource::Meeting,
            NoteSource::Dictation => notes::NoteSource::Dictation,
        }
    }
}

impl From<notes::NoteSource> for NoteSource {
    fn from(s: notes::NoteSource) -> Self {
        match s {
            notes::NoteSource::Quick => NoteSource::Quick,
            notes::NoteSource::Meeting => NoteSource::Meeting,
            notes::NoteSource::Dictation => NoteSource::Dictation,
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Note {
    pub id: i64,
    /// Unix seconds.
    pub created_at: i64,
    pub updated_at: i64,
    pub title: String,
    pub body_md: String,
    pub source: NoteSource,
    pub meeting_id: Option<i64>,
    pub tags: Vec<String>,
    pub pinned: bool,
}

impl From<notes::Note> for Note {
    fn from(n: notes::Note) -> Self {
        Note {
            id: n.id,
            created_at: n.created_at,
            updated_at: n.updated_at,
            title: n.title,
            body_md: n.body_md,
            source: n.source.into(),
            meeting_id: n.meeting_id,
            tags: n.tags,
            pinned: n.pinned,
        }
    }
}

/// What the app sends to create or replace a note.
#[derive(Clone, Debug, uniffi::Record)]
pub struct NoteInput {
    /// Leave empty to have one written: by the cleanup model when there is
    /// one, otherwise from the note's first words.
    pub title: String,
    pub body_md: String,
    pub source: NoteSource,
    pub meeting_id: Option<i64>,
    pub tags: Vec<String>,
    pub pinned: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum MeetingStatus {
    Recording,
    /// Recording stopped; the summary isn't there yet (or failed: retry with
    /// `summarize_meeting`).
    Processing,
    Done,
}

impl From<notes::MeetingStatus> for MeetingStatus {
    fn from(s: notes::MeetingStatus) -> Self {
        match s {
            notes::MeetingStatus::Recording => MeetingStatus::Recording,
            notes::MeetingStatus::Processing => MeetingStatus::Processing,
            notes::MeetingStatus::Done => MeetingStatus::Done,
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ActionItem {
    /// Only when the meeting said who.
    pub owner: Option<String>,
    pub task: String,
    /// Only when the meeting said when, in the words used ("Friday").
    pub due: Option<String>,
    pub done: bool,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Segment {
    pub id: i64,
    pub meeting_id: i64,
    /// Offsets from the start of the meeting.
    pub started_ms: i64,
    pub ended_ms: i64,
    /// "me", "others", or a name.
    pub speaker: String,
    /// Exactly what the speech engine heard.
    pub raw: String,
    /// Fillers removed and vocabulary fixed; never rewritten by a model.
    pub text: String,
}

impl From<notes::Segment> for Segment {
    fn from(s: notes::Segment) -> Self {
        Segment { id: s.id, meeting_id: s.meeting_id, started_ms: s.started_ms, ended_ms: s.ended_ms, speaker: s.speaker, raw: s.raw, text: s.text }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Meeting {
    pub id: i64,
    /// Unix seconds.
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub title: String,
    pub calendar_event_id: Option<String>,
    pub participants: Vec<String>,
    pub status: MeetingStatus,
    /// Markdown with Summary, Decisions, Action items and Open questions.
    pub summary_md: Option<String>,
    pub action_items: Vec<ActionItem>,
    /// The timestamped transcript, frozen when recording stopped.
    pub transcript_md: Option<String>,
    /// Filled by `meeting(id)` and `finish_meeting`; empty in `meetings(limit)`.
    pub segments: Vec<Segment>,
}

impl Meeting {
    fn new(m: notes::Meeting, segments: Vec<notes::Segment>) -> Self {
        Meeting {
            id: m.id,
            started_at: m.started_at,
            ended_at: m.ended_at,
            title: m.title,
            calendar_event_id: m.calendar_event_id,
            participants: m.participants,
            status: m.status.into(),
            summary_md: m.summary_md,
            action_items: m
                .action_items
                .into_iter()
                .map(|a| ActionItem { owner: a.owner, task: a.task, due: a.due, done: a.done })
                .collect(),
            transcript_md: m.raw_transcript_md,
            segments: segments.into_iter().map(Segment::from).collect(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum SearchHitKind {
    Note,
    /// The meeting's title or summary matched.
    Meeting,
    /// Something said in the meeting matched; see `started_ms`.
    Segment,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct SearchHit {
    pub kind: SearchHitKind,
    pub note_id: Option<i64>,
    pub meeting_id: Option<i64>,
    pub segment_id: Option<i64>,
    /// The note's or meeting's title.
    pub title: String,
    /// Matching text with the matched words in **bold**.
    pub snippet: String,
    /// When the note was last edited, or when the meeting started (Unix seconds).
    pub at: i64,
    pub started_ms: Option<i64>,
}

impl From<notes::SearchHit> for SearchHit {
    fn from(h: notes::SearchHit) -> Self {
        SearchHit {
            kind: match h.kind {
                notes::HitKind::Note => SearchHitKind::Note,
                notes::HitKind::Meeting => SearchHitKind::Meeting,
                notes::HitKind::Segment => SearchHitKind::Segment,
            },
            note_id: h.note_id,
            meeting_id: h.meeting_id,
            segment_id: h.segment_id,
            title: h.title,
            snippet: h.snippet,
            at: h.at,
            started_ms: h.started_ms,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum AudioSource {
    /// The user's microphone: transcribed as "me".
    Mic,
    /// What the computer plays (the call): transcribed as "others".
    System,
}

impl From<AudioSource> for live::AudioSource {
    fn from(s: AudioSource) -> Self {
        match s {
            AudioSource::Mic => live::AudioSource::Mic,
            AudioSource::System => live::AudioSource::System,
        }
    }
}

/// Implemented by the app to show transcript segments as they land.
#[uniffi::export(callback_interface)]
pub trait MeetingListener: Send + Sync {
    /// Called on a background thread.
    fn segment(&self, segment: Segment);
}

/// Forwards to whichever listener is set when a segment lands, so the app
/// can set or clear it mid-meeting.
struct ListenerSlot(Arc<RwLock<Option<Arc<dyn MeetingListener>>>>);

impl SegmentListener for ListenerSlot {
    fn segment(&self, segment: &notes::Segment) {
        let listener = self.0.read().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(listener) = listener {
            listener.segment(segment.clone().into());
        }
    }
}

const SEARCH_LIMIT: usize = 50;
/// Vocabulary terms given to the summary model.
const SUMMARY_VOCAB: usize = 40;

#[uniffi::export]
impl FlowstateEngine {
    pub fn create_note(&self, note: NoteInput) -> Result<Note, FlowstateError> {
        let draft = self.note_draft(note);
        self.store().create_note(&draft).map(Note::from).map_err(storage_err)
    }

    pub fn update_note(&self, id: i64, note: NoteInput) -> Result<Note, FlowstateError> {
        let draft = self.note_draft(note);
        self.store().update_note(id, &draft).map(Note::from).map_err(storage_err)
    }

    /// False if there was no such note.
    pub fn delete_note(&self, id: i64) -> Result<bool, FlowstateError> {
        self.store().delete_note(id).map_err(storage_err)
    }

    /// Pinned first, then most recently edited.
    pub fn notes(&self, limit: u32) -> Result<Vec<Note>, FlowstateError> {
        Ok(self.store().notes(limit as usize).map_err(storage_err)?.into_iter().map(Note::from).collect())
    }

    /// Best matches first. Every word must match; the last may be a prefix.
    pub fn search(&self, query: String) -> Result<Vec<SearchHit>, FlowstateError> {
        Ok(self.store().search(&query, SEARCH_LIMIT).map_err(storage_err)?.into_iter().map(SearchHit::from).collect())
    }

    /// Start recording a meeting. Fails if one is already being recorded.
    pub fn start_meeting(&self, title: String, calendar_event_id: Option<String>, participants: Vec<String>) -> Result<Meeting, FlowstateError> {
        let mut current = self.meeting.lock().unwrap();
        if current.is_some() {
            return Err(FlowstateError::Meeting("a meeting is already being recorded".into()));
        }
        let meeting = self.store().start_meeting(&title, calendar_event_id.as_deref(), &participants).map_err(storage_err)?;
        let transcriber = PipelineTranscriber { pipeline: self.pipeline.clone(), context: vocab_context(&meeting) };
        let listener: Arc<dyn SegmentListener> = Arc::new(ListenerSlot(self.listener.clone()));
        *current = Some(MeetingSession::start(meeting.id, self.notes.clone(), Box::new(transcriber), Some(listener), VadConfig::default()));
        Ok(Meeting::new(meeting, vec![]))
    }

    /// Queue 16 kHz mono f32 samples from one source. Cheap enough for an
    /// audio callback; does nothing when no meeting is being recorded.
    pub fn feed_meeting_audio(&self, source: AudioSource, samples: Vec<f32>) {
        if let Some(session) = self.meeting.lock().unwrap().as_ref() {
            session.feed(source.into(), samples);
        }
    }

    /// Stop recording, transcribe what's still queued, and summarize. Blocks
    /// until done. If summarizing fails the transcript is still saved and
    /// the meeting stays in Processing; retry with `summarize_meeting`.
    pub fn finish_meeting(&self) -> Result<Meeting, FlowstateError> {
        let session = self.meeting.lock().unwrap().take().ok_or_else(|| FlowstateError::Meeting("no meeting is being recorded".into()))?;
        let id = session.meeting_id();
        session.finish();
        self.store().finish_meeting(id).map_err(storage_err)?;
        self.summarize_meeting(id)
    }

    /// Summarize a finished meeting again, e.g. after a failure or after
    /// switching to a mode with a cleanup model.
    pub fn summarize_meeting(&self, id: i64) -> Result<Meeting, FlowstateError> {
        let meeting = self.store().meeting(id).map_err(storage_err)?.ok_or_else(|| FlowstateError::Meeting(format!("no meeting {id}")))?.0;
        let (llm, vocabulary) = {
            let p = self.pipeline.lock().unwrap();
            (p.llm(), p.vocab.relevant_terms(&vocab_context(&meeting), &[], SUMMARY_VOCAB).unwrap_or_default())
        };
        summary::summarize_meeting(&self.notes, llm.as_deref(), &vocabulary, id)
            .map_err(|e| FlowstateError::Meeting(format!("transcript saved, but the summary failed: {e}")))?;
        self.meeting(id)?.ok_or_else(|| FlowstateError::Meeting(format!("no meeting {id}")))
    }

    /// Most recent first, without segments.
    pub fn meetings(&self, limit: u32) -> Result<Vec<Meeting>, FlowstateError> {
        let meetings = self.store().recent_meetings(limit as usize).map_err(storage_err)?;
        Ok(meetings.into_iter().map(|m| Meeting::new(m, vec![])).collect())
    }

    /// A meeting with its segments in order.
    pub fn meeting(&self, id: i64) -> Result<Option<Meeting>, FlowstateError> {
        Ok(self.store().meeting(id).map_err(storage_err)?.map(|(m, segments)| Meeting::new(m, segments)))
    }

    /// Delete a meeting and its transcript; notes taken in it are kept.
    /// Refuses the meeting being recorded.
    pub fn delete_meeting(&self, id: i64) -> Result<bool, FlowstateError> {
        if self.meeting.lock().unwrap().as_ref().is_some_and(|s| s.meeting_id() == id) {
            return Err(FlowstateError::Meeting("finish the meeting before deleting it".into()));
        }
        self.store().delete_meeting(id).map_err(storage_err)
    }

    pub fn rename_meeting(&self, id: i64, title: String) -> Result<Meeting, FlowstateError> {
        let title = title.trim();
        if title.is_empty() {
            return Err(FlowstateError::Meeting("a meeting needs a title".into()));
        }
        self.store().rename_meeting(id, title).map_err(|e| missing_meeting(e, id))?;
        self.full_meeting(id)
    }

    /// Tick off (or untick) the action item at `index` in `action_items`.
    pub fn set_action_item_done(&self, meeting_id: i64, index: u32, done: bool) -> Result<Meeting, FlowstateError> {
        self.store().set_action_item_done(meeting_id, index as usize, done).map_err(|e| missing_meeting(e, meeting_id))?;
        self.full_meeting(meeting_id)
    }

    /// Replace the participant list. Blank names are dropped.
    pub fn update_meeting_participants(&self, id: i64, participants: Vec<String>) -> Result<Meeting, FlowstateError> {
        let participants: Vec<String> = participants.iter().map(|p| p.trim().to_string()).filter(|p| !p.is_empty()).collect();
        self.store().set_participants(id, &participants).map_err(|e| missing_meeting(e, id))?;
        self.full_meeting(id)
    }

    pub fn export_meeting_markdown(&self, id: i64) -> Result<String, FlowstateError> {
        self.store().export_meeting_markdown(id).map_err(storage_err)
    }

    /// Pass None to stop receiving segments.
    pub fn set_meeting_listener(&self, listener: Option<Box<dyn MeetingListener>>) {
        *self.listener.write().unwrap() = listener.map(Arc::from);
    }
}

impl FlowstateEngine {
    fn store(&self) -> std::sync::MutexGuard<'_, NotesStore> {
        self.notes.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn full_meeting(&self, id: i64) -> Result<Meeting, FlowstateError> {
        self.meeting(id)?.ok_or_else(|| FlowstateError::Meeting(format!("no meeting {id}")))
    }

    fn note_draft(&self, note: NoteInput) -> notes::NoteDraft {
        let title = if note.title.trim().is_empty() {
            let llm = self.pipeline.lock().unwrap().llm();
            summary::title_note(llm.as_deref(), &note.body_md)
        } else {
            note.title
        };
        notes::NoteDraft { title, body_md: note.body_md, source: note.source.into(), meeting_id: note.meeting_id, tags: note.tags, pinned: note.pinned }
    }
}

fn missing_meeting(e: notes::Error, id: i64) -> FlowstateError {
    match e {
        notes::Error::QueryReturnedNoRows => FlowstateError::Meeting(format!("no meeting {id}, or no such action item")),
        other => storage_err(other),
    }
}

/// Text the vocabulary index scans for hints during a meeting.
fn vocab_context(meeting: &notes::Meeting) -> String {
    format!("{}\n{}", meeting.title, meeting.participants.join("\n"))
}

fn source_name(s: vocab::Source) -> String {
    match s {
        vocab::Source::Project => "project",
        vocab::Source::Contact => "contact",
        vocab::Source::Calendar => "calendar",
        vocab::Source::User => "user",
        vocab::Source::Correction => "correction",
        vocab::Source::Learned => "learned",
        vocab::Source::Team => "team",
    }
    .to_string()
}

fn build_stt(speech: &SpeechEngine) -> Result<Box<dyn SttEngine>, FlowstateError> {
    match speech {
        #[cfg(feature = "whisper")]
        SpeechEngine::Whisper { model_path } => Ok(Box::new(
            flowstate_core::stt::WhisperEngine::load(flowstate_core::stt::WhisperConfig::new(model_path)).map_err(setup_err)?,
        )),
        #[cfg(feature = "parakeet")]
        SpeechEngine::Parakeet { model_dir } => Ok(Box::new(
            flowstate_core::stt::ParakeetEngine::load(flowstate_core::stt::ParakeetConfig::new(model_dir)).map_err(setup_err)?,
        )),
        #[allow(unreachable_patterns)]
        other => Err(FlowstateError::Setup(format!("{other:?} isn't compiled into this build"))),
    }
}

fn build_cleaner(mode: CleanupMode, local: Option<&LocalModel>, cloud: Option<&CloudConfig>) -> Result<Option<Box<dyn Cleaner>>, FlowstateError> {
    match mode {
        CleanupMode::Raw | CleanupMode::FilterOnly => Ok(None),
        CleanupMode::Local => {
            let local = local.ok_or_else(|| FlowstateError::Setup("local mode needs a cleanup model".into()))?;
            let start = |model: &str| LocalCleaner::start(LocalConfig::new(&local.server_binary, model)).map_err(setup_err);
            let heavy = start(&local.model_path)?;
            Ok(Some(match local.light_model_path.as_deref() {
                Some(light) if !light.is_empty() && light != local.model_path => {
                    Box::new(RoutedCleaner { light: Box::new(start(light)?), heavy: Box::new(heavy) })
                }
                _ => Box::new(heavy),
            }))
        }
        CleanupMode::Cloud => {
            let cloud = cloud.ok_or_else(|| FlowstateError::Setup("cloud mode needs a provider".into()))?;
            if let CloudProvider::Flowstate { base_url } = &cloud.provider {
                let token = cloud.api_key.clone().filter(|k| !k.is_empty()).ok_or_else(|| FlowstateError::Setup("sign in to use the Flowstate server".into()))?;
                return Ok(Some(Box::new(FlowstateCleaner::new(base_url.clone(), token).map_err(setup_err)?)));
            }
            let make = |model: &str| -> Result<Box<dyn Cleaner>, FlowstateError> {
                Ok(match &cloud.provider {
                    CloudProvider::Anthropic => Box::new(
                        AnthropicCleaner::new(cloud.api_key.clone().unwrap_or_default(), Some(model.to_string())).map_err(setup_err)?,
                    ),
                    CloudProvider::OpenAiCompatible { base_url } | CloudProvider::Flowstate { base_url } => {
                        Box::new(OpenAiCompatCleaner::new(base_url.clone(), cloud.api_key.clone(), model).map_err(setup_err)?)
                    }
                })
            };
            let heavy = make(&cloud.model)?;
            Ok(Some(match cloud.light_model.as_deref() {
                Some(light) if light != cloud.model => Box::new(RoutedCleaner { light: make(light)?, heavy }),
                _ => heavy,
            }))
        }
    }
}

/// Implemented by the app to receive the core's debug log lines (cleanup
/// timings, for one), so they land in the same log file as the app's own.
#[uniffi::export(callback_interface)]
pub trait LogSink: Send + Sync {
    /// Called on whichever thread logged.
    fn debug(&self, message: String);
}

struct SinkLogger(Arc<dyn LogSink>);

impl log::Log for SinkLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Debug && metadata.target().starts_with("flowstate_core")
    }

    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            self.0.debug(record.args().to_string());
        }
    }

    fn flush(&self) {}
}

/// Send the core's debug logging to `sink`. Only the first call in a process
/// takes effect.
#[uniffi::export]
pub fn set_log_sink(sink: Box<dyn LogSink>) {
    let logger: &'static SinkLogger = Box::leak(Box::new(SinkLogger(Arc::from(sink))));
    if log::set_logger(logger).is_ok() {
        log::set_max_level(log::LevelFilter::Debug);
    }
}

/*
 * Sync: writing what a Flowstate server sent back. These keep the given
 * timestamps (Unix seconds) and never call the cleanup model; the app keeps
 * the mapping between local ids and the server's ids itself.
 */

/// A transcript line pulled from a server.
#[derive(Clone, Debug, uniffi::Record)]
pub struct SyncedSegment {
    pub started_ms: i64,
    pub ended_ms: i64,
    pub speaker: String,
    pub text: String,
}

/// A whole meeting pulled from a server.
#[derive(Clone, Debug, uniffi::Record)]
pub struct SyncedMeeting {
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub title: String,
    pub participants: Vec<String>,
    pub status: MeetingStatus,
    pub summary_md: Option<String>,
    pub action_items: Vec<ActionItem>,
    pub transcript_md: Option<String>,
    pub segments: Vec<SyncedSegment>,
}

impl From<MeetingStatus> for notes::MeetingStatus {
    fn from(s: MeetingStatus) -> Self {
        match s {
            MeetingStatus::Recording => notes::MeetingStatus::Recording,
            MeetingStatus::Processing => notes::MeetingStatus::Processing,
            MeetingStatus::Done => notes::MeetingStatus::Done,
        }
    }
}

#[uniffi::export]
impl FlowstateEngine {
    /// Create (`id` None) or overwrite a note with a synced copy. The title
    /// is used as is, even when empty.
    pub fn put_synced_note(&self, id: Option<i64>, note: NoteInput, created_at: i64, updated_at: i64) -> Result<Note, FlowstateError> {
        let draft = notes::NoteDraft {
            title: note.title,
            body_md: note.body_md,
            source: note.source.into(),
            meeting_id: note.meeting_id,
            tags: note.tags,
            pinned: note.pinned,
        };
        self.store().put_synced_note(id, &draft, created_at, updated_at).map(Note::from).map_err(storage_err)
    }

    /// Create (`id` None) or replace a meeting and its segments with a
    /// synced copy. Refuses the meeting being recorded.
    pub fn put_synced_meeting(&self, id: Option<i64>, meeting: SyncedMeeting) -> Result<Meeting, FlowstateError> {
        if let Some(id) = id {
            if self.meeting.lock().unwrap().as_ref().is_some_and(|s| s.meeting_id() == id) {
                return Err(FlowstateError::Meeting("this meeting is being recorded".into()));
            }
        }
        let import = notes::MeetingImport {
            started_at: meeting.started_at,
            ended_at: meeting.ended_at,
            title: meeting.title,
            participants: meeting.participants,
            status: meeting.status.into(),
            summary_md: meeting.summary_md,
            action_items: meeting
                .action_items
                .into_iter()
                .map(|a| notes::ActionItem { owner: a.owner, task: a.task, due: a.due, done: a.done })
                .collect(),
            raw_transcript_md: meeting.transcript_md,
            segments: meeting
                .segments
                .into_iter()
                .map(|s| notes::SegmentImport { started_ms: s.started_ms, ended_ms: s.ended_ms, speaker: s.speaker, text: s.text })
                .collect(),
        };
        let store = self.store();
        let m = store.put_synced_meeting(id, &import).map_err(storage_err)?;
        let segments = store.segments(m.id).map_err(storage_err)?;
        Ok(Meeting::new(m, segments))
    }
}
