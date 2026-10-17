use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

use chrono::{Days, NaiveDate};
use serde::{Deserialize, Serialize};

use crate::usage::{
    normalize_model_for_grouping, CostSource, ServiceTier, TokenCostBreakdown, UnifiedMessage,
};

pub mod antigravity;
pub mod codex;
pub mod claude;
pub mod custom_pricing;
pub mod grok;
pub mod memory;
pub mod pricing;
pub mod openrouter;
pub mod usage;

pub use usage::StatisticsTimeZone;

pub const SCHEMA_VERSION: u32 = 11;

pub type SessionTitleMap = HashMap<(String, String), String>;

const CODEX_SYSTEM_INJECTED_PREFIXES: [&str; 3] = [
    "<environment_context>",
    "<system-reminder>",
    "<user_instructions>",
];

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestDetail {
    pub prompt: Option<String>,
    pub output: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenBreakdown {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub reasoning: i64,
}

impl TokenBreakdown {
    fn from_unified(tokens: &crate::usage::TokenBreakdown) -> Self {
        Self {
            input: tokens.input.max(0),
            output: tokens.output.max(0),
            cache_read: tokens.cache_read.max(0),
            cache_write: tokens.cache_write.max(0),
            reasoning: tokens.reasoning.max(0),
        }
    }

    fn total(&self) -> i64 {
        self.input
            .saturating_add(self.output)
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_write)
            .saturating_add(self.reasoning)
    }

    fn add_assign(&mut self, other: &Self) {
        self.input = self.input.saturating_add(other.input);
        self.output = self.output.saturating_add(other.output);
        self.cache_read = self.cache_read.saturating_add(other.cache_read);
        self.cache_write = self.cache_write.saturating_add(other.cache_write);
        self.reasoning = self.reasoning.saturating_add(other.reasoning);
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivityCostSource {
    #[default]
    Unknown,
    ProviderReported,
    Estimated,
}

impl From<CostSource> for ActivityCostSource {
    fn from(source: CostSource) -> Self {
        match source {
            CostSource::Unknown => Self::Unknown,
            CostSource::ProviderReported => Self::ProviderReported,
            CostSource::Estimated => Self::Estimated,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivityServiceTier {
    #[default]
    Unknown,
    Standard,
    Fast,
    Mixed,
}

impl From<ServiceTier> for ActivityServiceTier {
    fn from(tier: ServiceTier) -> Self {
        match tier {
            ServiceTier::Unknown => Self::Unknown,
            ServiceTier::Standard => Self::Standard,
            ServiceTier::Fast => Self::Fast,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationMetrics {
    pub generated_tokens: i64,
    pub duration_ms: i64,
}

impl GenerationMetrics {
    fn measured(self) -> Option<Self> {
        (self.generated_tokens > 0 && self.duration_ms > 0).then_some(self)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestSummary {
    pub id: String,
    pub platform: String,
    pub session_id: String,
    pub physical_session_id: String,
    pub is_subagent: bool,
    pub agent: Option<String>,
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
    pub provider: String,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation_metrics: Option<GenerationMetrics>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time_to_first_token_ms: Option<i64>,
    pub tokens: TokenBreakdown,
    pub cost_usd: f64,
    pub cost_source: ActivityCostSource,
    #[serde(default)]
    pub service_tier: ActivityServiceTier,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_path: Option<String>,
    pub prompt_preview: Option<String>,
    pub output_preview: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub contributions: Vec<RequestSummary>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub id: String,
    pub platform: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_path: Option<String>,
    pub workspace_label: Option<String>,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub tokens: TokenBreakdown,
    pub cost_usd: f64,
    pub models: Vec<String>,
    pub requests: Vec<RequestSummary>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityTotals {
    pub tokens: TokenBreakdown,
    pub cost_usd: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_costs: Option<TokenCostBreakdown>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub average_generation_tokens_per_second: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation_metrics: Option<GenerationMetrics>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub average_time_to_first_token_ms: Option<f64>,
    #[serde(default)]
    pub first_token_sample_count: usize,
    pub request_count: usize,
    pub session_count: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityRangeSummary {
    pub started_at_ms: i64,
    pub totals: ActivityTotals,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DailyModelSummary {
    pub platform: String,
    pub model: String,
    pub provider: String,
    pub tokens: TokenBreakdown,
    pub cost_usd: f64,
    pub request_count: usize,
    pub session_count: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DailySummary {
    pub date: String,
    pub tokens: TokenBreakdown,
    pub cost_usd: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub average_generation_tokens_per_second: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation_metrics: Option<GenerationMetrics>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub average_time_to_first_token_ms: Option<f64>,
    #[serde(default)]
    pub first_token_sample_count: usize,
    pub request_count: usize,
    pub session_count: usize,
    #[serde(default)]
    pub models: Vec<DailyModelSummary>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservedPricingModel {
    pub platform: String,
    #[serde(rename = "modelID")]
    pub model_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivitySnapshot {
    pub schema_version: u32,
    pub generated_at_ms: i64,
    pub timezone: String,
    pub today: ActivityTotals,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub range_totals: Option<ActivityTotals>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weekly_since_reset: Option<ActivityRangeSummary>,
    pub sessions: Vec<SessionSummary>,
    pub days: Vec<DailySummary>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sources: Vec<ActivitySourceSnapshot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_usage: Option<memory::MemoryUsageSnapshot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pricing_catalog: Option<openrouter::CatalogStatus>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pricing_models: Vec<ObservedPricingModel>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivitySourceSnapshot {
    pub platform: String,
    pub today: ActivityTotals,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub range_totals: Option<ActivityTotals>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weekly_since_reset: Option<ActivityRangeSummary>,
    pub days: Vec<DailySummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct RequestKey {
    date: NaiveDate,
    source: String,
    provider: String,
    model: String,
    reasoning_effort: Option<String>,
    session_id: String,
    physical_session_id: String,
    agent: Option<String>,
}

#[derive(Debug, Clone)]
struct RequestRow {
    date: NaiveDate,
    timestamp: i64,
    source: String,
    provider: String,
    model: String,
    reasoning_effort: Option<String>,
    session_id: String,
    physical_session_id: String,
    is_subagent: bool,
    workspace_path: Option<String>,
    workspace_label: Option<String>,
    agent: Option<String>,
    session_path: Option<String>,
    prompt_preview: Option<String>,
    output_preview: Option<String>,
    tokens: TokenBreakdown,
    cost: f64,
    token_costs: Option<TokenCostBreakdown>,
    cost_source: ActivityCostSource,
    service_tier: ActivityServiceTier,
    duration_ms: Option<i64>,
    model_duration_ms: Option<i64>,
    generation_metrics: GenerationMetrics,
    time_to_first_token_ms: Option<i64>,
    request_start_timestamp: Option<i64>,
    request_end_timestamp: i64,
    is_turn_start: bool,
}

#[derive(Debug, Clone)]
struct TurnRow {
    id: String,
    anchor: RequestRow,
    contributions: Vec<RequestRow>,
}

impl RequestRow {
    fn key(&self) -> RequestKey {
        RequestKey {
            date: self.date,
            source: self.source.clone(),
            provider: self.provider.clone(),
            model: self.model.clone(),
            reasoning_effort: self.reasoning_effort.clone(),
            session_id: self.session_id.clone(),
            physical_session_id: self.physical_session_id.clone(),
            agent: self.agent.clone(),
        }
    }

    fn started_at_ms(&self) -> i64 {
        self.request_start_timestamp.unwrap_or(self.timestamp)
    }
}

#[derive(Default)]
struct DailyAccumulator {
    tokens: TokenBreakdown,
    cost: f64,
    token_costs: OptionalTokenCostAccumulator,
    generated_tokens: f64,
    model_duration_ms: f64,
    first_token_total_ms: f64,
    first_token_sample_count: usize,
    turn_ids: HashSet<String>,
    session_ids: HashSet<(String, String)>,
    models: BTreeMap<(String, String, String), DailyModelAccumulator>,
}

#[derive(Default)]
struct OptionalTokenCostAccumulator {
    costs: TokenCostBreakdown,
    saw_request: bool,
    is_complete: bool,
}

impl OptionalTokenCostAccumulator {
    fn add(&mut self, costs: Option<&TokenCostBreakdown>) {
        if !self.saw_request {
            self.saw_request = true;
            self.is_complete = true;
        }
        if let Some(costs) = costs {
            self.costs.add_assign(costs);
        } else {
            self.is_complete = false;
        }
    }

    fn complete_costs(&self) -> Option<TokenCostBreakdown> {
        (self.saw_request && self.is_complete).then_some(self.costs)
    }
}

#[derive(Default)]
struct DailyModelAccumulator {
    tokens: TokenBreakdown,
    cost: f64,
    turn_ids: HashSet<String>,
    session_ids: HashSet<(String, String)>,
}

/// Reads the unabridged prompt and assistant messages for one Codex request.
///
/// Entries outside the inclusive millisecond range are ignored. Assistant
/// messages are kept in transcript order and separated by one blank line. The
/// original message text is otherwise unchanged, including embedded newlines.
pub fn extract_request_detail(
    session_path: &Path,
    start_ms: i64,
    end_ms: i64,
) -> Result<RequestDetail, String> {
    if start_ms > end_ms {
        return Err("request start must not be after request end".to_string());
    }

    let file = File::open(session_path).map_err(|error| {
        format!(
            "could not open Codex session {}: {error}",
            session_path.display()
        )
    })?;
    extract_request_detail_from_reader(BufReader::new(file), start_ms, end_ms)
}

fn extract_request_detail_from_reader<R: BufRead>(
    reader: R,
    start_ms: i64,
    end_ms: i64,
) -> Result<RequestDetail, String> {
    let mut messages: Vec<CodexDetailMessage> = Vec::new();

    for line in reader.lines() {
        let line = line.map_err(|error| format!("could not read Codex session: {error}"))?;
        let Ok(entry) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
            continue;
        };
        let Some(timestamp_ms) = codex_entry_timestamp_ms(&entry) else {
            continue;
        };
        // Rollouts can contain delayed writes with earlier timestamps. Scan the
        // complete transcript, while keeping the request's inclusive boundary.
        if timestamp_ms < start_ms || timestamp_ms > end_ms {
            continue;
        }
        let Some(mut message) = codex_detail_message(&entry, timestamp_ms) else {
            continue;
        };
        if message.text.trim().is_empty()
            || (message.is_user && !codex_message_is_human_turn(&message.text))
        {
            continue;
        }

        // Codex commonly writes the same message as both an event and a
        // response item. Match each mirror once, rather than globally deduping
        // text: identical messages sent again remain separate transcript items.
        let mirror = messages
            .iter_mut()
            .rev()
            .take_while(|previous| {
                previous.is_user == message.is_user && previous.text == message.text
            })
            .find(|previous| {
                !previous.mirrored
                    && previous.is_response_item != message.is_response_item
                    && previous.timestamp_ms.abs_diff(message.timestamp_ms) <= 1_000
                    && (previous.phase.is_none()
                        || message.phase.is_none()
                        || previous.phase == message.phase)
            });
        if let Some(previous) = mirror {
            previous.mirrored = true;
            continue;
        }
        message.mirrored = false;
        messages.push(message);
    }

    let join_role = |is_user| {
        let texts: Vec<&str> = messages
            .iter()
            .filter(|message| message.is_user == is_user)
            .map(|message| message.text.as_str())
            .collect();
        (!texts.is_empty()).then(|| texts.join("\n\n"))
    };
    Ok(RequestDetail {
        prompt: join_role(true),
        output: join_role(false),
    })
}

struct CodexDetailMessage {
    text: String,
    is_user: bool,
    is_response_item: bool,
    timestamp_ms: i64,
    phase: Option<String>,
    mirrored: bool,
}

fn codex_detail_message(
    entry: &serde_json::Value,
    timestamp_ms: i64,
) -> Option<CodexDetailMessage> {
    let payload = entry.get("payload")?;
    let is_response_item = entry.get("type")?.as_str()? == "response_item";
    let (is_user, text) = if is_response_item {
        if payload.get("type")?.as_str()? != "message" {
            return None;
        }
        let is_user = match payload.get("role")?.as_str()? {
            "user" => true,
            "assistant" => false,
            _ => return None,
        };
        // Analysis/reasoning is private model work, not the displayed answer.
        if ["channel", "phase"].iter().any(|key| {
            matches!(
                payload.get(*key).and_then(|value| value.as_str()),
                Some("analysis" | "reasoning")
            )
        }) {
            return None;
        }
        let content = payload.get("content")?;
        let text = if let Some(text) = content.as_str() {
            text.to_string()
        } else {
            content
                .as_array()?
                .iter()
                .filter_map(|part| {
                    matches!(
                        part.get("type")?.as_str()?,
                        "input_text" | "output_text" | "text"
                    )
                    .then(|| part.get("text")?.as_str())?
                })
                .collect::<Vec<_>>()
                .join("\n\n")
        };
        (is_user, text)
    } else if let Some(message) = codex_event_message(entry, "user_message") {
        (true, message.to_string())
    } else if let Some(message) = codex_event_message(entry, "agent_message") {
        (false, message.to_string())
    } else {
        return None;
    };
    let phase = payload
        .get("phase")
        .or_else(|| payload.get("channel"))
        .and_then(|value| value.as_str())
        .map(|phase| {
            if phase == "final_answer" {
                "final"
            } else {
                phase
            }
            .to_string()
        });
    Some(CodexDetailMessage {
        text,
        is_user,
        is_response_item,
        timestamp_ms,
        phase,
        mirrored: false,
    })
}

fn codex_entry_timestamp_ms(entry: &serde_json::Value) -> Option<i64> {
    let timestamp = entry.get("timestamp")?;
    if let Some(value) = timestamp.as_i64() {
        return Some(value);
    }
    chrono::DateTime::parse_from_rfc3339(timestamp.as_str()?)
        .ok()
        .map(|value| value.timestamp_millis())
}

fn codex_event_message<'a>(entry: &'a serde_json::Value, expected_type: &str) -> Option<&'a str> {
    if entry.get("type")?.as_str()? != "event_msg" {
        return None;
    }
    let payload = entry.get("payload")?;
    if payload.get("type")?.as_str()? != expected_type {
        return None;
    }
    payload.get("message")?.as_str()
}

fn codex_message_is_human_turn(message: &str) -> bool {
    let trimmed = message.trim_start();
    !CODEX_SYSTEM_INJECTED_PREFIXES
        .iter()
        .any(|prefix| trimmed.starts_with(prefix))
}

/// Normalizes Codex's reasoning breakdown before TokenBar aggregates it.
///
/// Codex reports `reasoning_output_tokens` as a subset of `output_tokens`, while
/// Tokscale's generic pricing contract treats `output` and `reasoning` as
/// disjoint buckets. Repricing the corrected message keeps the shared parser
/// untouched while preventing TokenBar from counting reasoning twice.
pub fn normalize_codex_reasoning_usage(
    messages: &mut [UnifiedMessage],
    mut recalculate_estimated_cost: impl FnMut(&UnifiedMessage) -> Option<TokenCostBreakdown>,
) {
    for message in messages {
        if message.client != "codex" {
            continue;
        }

        let reasoning = message.tokens.reasoning.max(0);
        if reasoning == 0 {
            continue;
        }

        let original_output = message.tokens.output;
        if reasoning > original_output {
            // An inconsistent breakdown cannot be converted into disjoint
            // buckets without inventing token counts. Preserve it verbatim.
            continue;
        }
        message.tokens.output = original_output - reasoning;

        if message.cost_source != CostSource::Estimated {
            continue;
        }

        let Some(token_costs) = recalculate_estimated_cost(message).filter(|costs| {
            let total = costs.total();
            total.is_finite() && total >= 0.0 && (total > 0.0 || message.cost == 0.0)
        }) else {
            // Keep the previous cost and token contract together if the same
            // cached pricing dataset cannot reproduce an estimated cost.
            message.tokens.output = original_output;
            continue;
        };
        message.cost = token_costs.total();
        message.token_costs = Some(token_costs);
    }
}

/// Resolves Codex App/CLI thread names to TokenBar's logical session ids.
///
/// `session_index.jsonl` is keyed by the upstream UUID stored in each rollout's
/// `session_meta`, while Tokscale exposes the rollout file stem as the logical
/// root id. Only a root rollout can name the grouped session; subagent rollouts
/// keep their own upstream ids and must not replace the parent title.
pub fn load_codex_session_titles(
    messages: &[UnifiedMessage],
    session_index_path: &Path,
) -> SessionTitleMap {
    let titles_by_upstream = read_codex_title_index(session_index_path);
    if titles_by_upstream.is_empty() {
        return HashMap::new();
    }

    let mut seen_paths = HashSet::new();
    let mut titles_by_session = HashMap::new();
    for message in messages {
        if message.client != "codex" {
            continue;
        }

        let Some(path) = message.session_path.as_deref() else {
            continue;
        };
        if physical_session_id(message) != message.session_id || !seen_paths.insert(path) {
            continue;
        }

        let Some(upstream_id) = read_codex_upstream_session_id(Path::new(path)) else {
            continue;
        };
        if let Some(title) = titles_by_upstream.get(&upstream_id) {
            titles_by_session.insert(
                ("codex".to_string(), message.session_id.clone()),
                title.clone(),
            );
        }
    }

    titles_by_session
}

/// Reads the latest custom title written into each root Claude Code transcript.
///
/// Claude appends `custom-title` records directly to the CLI JSONL. Subagent
/// transcripts cannot name the grouped session. Prefer the current user
/// transcript's title, with prior user transcripts as a fallback.
pub fn load_claude_session_titles(messages: &[UnifiedMessage]) -> SessionTitleMap {
    let mut seen_paths = HashSet::new();
    let mut titles_by_session = HashMap::new();
    for message in messages {
        if message.client != "claude" {
            continue;
        }

        let Some(path) = message.session_path.as_deref() else {
            continue;
        };
        if message.is_subagent || !seen_paths.insert(path) {
            continue;
        }

        if let Some(title) = read_claude_custom_title(Path::new(path)) {
            let key = ("claude".to_string(), message.session_id.clone());
            if physical_session_id(message) == message.session_id {
                titles_by_session.insert(key, title);
            } else {
                titles_by_session.entry(key).or_insert(title);
            }
        }
    }

    titles_by_session
}

fn read_claude_custom_title(path: &Path) -> Option<String> {
    let reader = BufReader::new(File::open(path).ok()?);
    let mut title = None;
    for line in reader.lines().map_while(Result::ok) {
        let Ok(entry) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        if entry.get("type").and_then(serde_json::Value::as_str) != Some("custom-title") {
            continue;
        }
        let Some(value) = entry
            .get("customTitle")
            .and_then(serde_json::Value::as_str)
        else {
            continue;
        };
        let value = value.trim();
        title = (!value.is_empty()).then(|| value.to_string());
    }
    title
}

fn read_codex_title_index(path: &Path) -> HashMap<String, String> {
    let Some(reader) = File::open(path).ok().map(BufReader::new) else {
        return HashMap::new();
    };
    let mut titles = HashMap::new();
    for line in reader.lines().map_while(Result::ok) {
        let Ok(entry) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        let (Some(id), Some(title)) = (
            entry.get("id").and_then(serde_json::Value::as_str),
            entry.get("thread_name").and_then(serde_json::Value::as_str),
        ) else {
            continue;
        };
        let title = title.trim();
        if !id.is_empty() && !title.is_empty() {
            // The index is append-oriented; a later row represents a rename.
            titles.insert(id.to_string(), title.to_string());
        }
    }
    titles
}

fn read_codex_upstream_session_id(path: &Path) -> Option<String> {
    let reader = BufReader::new(File::open(path).ok()?);
    for line in reader.lines().map_while(Result::ok).take(64) {
        let Ok(entry) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        if entry.get("type").and_then(serde_json::Value::as_str) != Some("session_meta") {
            continue;
        }
        return entry
            .get("payload")?
            .get("id")?
            .as_str()
            .map(str::to_string)
            .filter(|id| !id.is_empty());
    }
    None
}

/// Builds the JSON contract consumed by TokenBar's Swift core.
///
/// `messages` may contain a wider range than requested; this function applies the
/// range again so callers and tests get the same deterministic boundary behavior.
pub fn build_snapshot(
    messages: Vec<UnifiedMessage>,
    today: NaiveDate,
    generated_at_ms: i64,
    timezone: String,
    day_count: usize,
) -> Result<ActivitySnapshot, String> {
    build_snapshot_with_session_titles(
        messages,
        today,
        generated_at_ms,
        timezone,
        day_count,
        &HashMap::new(),
        None,
    )
}

pub fn build_snapshot_with_session_titles(
    messages: Vec<UnifiedMessage>,
    today: NaiveDate,
    generated_at_ms: i64,
    timezone: String,
    day_count: usize,
    session_titles: &SessionTitleMap,
    weekly_reset_at_ms: Option<i64>,
) -> Result<ActivitySnapshot, String> {
    let weekly_resets = weekly_reset_at_ms
        .map(|timestamp| HashMap::from([("codex".to_string(), timestamp)]))
        .unwrap_or_default();
    build_snapshot_with_platform_resets(
        messages,
        today,
        generated_at_ms,
        timezone,
        day_count,
        session_titles,
        &weekly_resets,
    )
}

pub fn build_snapshot_with_platform_resets(
    messages: Vec<UnifiedMessage>,
    today: NaiveDate,
    generated_at_ms: i64,
    timezone: String,
    day_count: usize,
    session_titles: &SessionTitleMap,
    weekly_reset_at_ms: &HashMap<String, i64>,
) -> Result<ActivitySnapshot, String> {
    let pricing_models = messages.iter()
        .filter(|message| !message.model_id.trim().is_empty() && message.timestamp <= generated_at_ms)
        .map(|message| (message.client.clone(), message.model_id.clone()))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .map(|(platform, model_id)| ObservedPricingModel { platform, model_id })
        .collect();
    let discovered_platforms = messages
        .iter()
        .map(|message| message.client.clone())
        .collect::<BTreeSet<_>>();
    let known_platforms = ["codex", "claude", "grok", "antigravity"];
    let mut platforms = known_platforms
        .iter()
        .map(|platform| (*platform).to_string())
        .collect::<Vec<_>>();
    platforms.extend(
        discovered_platforms
            .into_iter()
            .filter(|platform| !known_platforms.contains(&platform.as_str())),
    );

    let mut snapshot = build_snapshot_core(
        messages.clone(),
        today,
        generated_at_ms,
        timezone.clone(),
        day_count,
        session_titles,
        weekly_reset_at_ms.get("codex").copied(),
    )?;
    snapshot.sources = platforms
        .into_iter()
        .map(|platform| {
            let source_messages = messages
                .iter()
                .filter(|message| message.client == platform)
                .cloned()
                .collect();
            build_snapshot_core(
                source_messages,
                today,
                generated_at_ms,
                timezone.clone(),
                day_count,
                session_titles,
                weekly_reset_at_ms.get(&platform).copied(),
            )
            .map(|source| ActivitySourceSnapshot {
                platform,
                today: source.today,
                range_totals: source.range_totals,
                weekly_since_reset: source.weekly_since_reset,
                days: source.days,
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    snapshot.pricing_models = pricing_models;
    Ok(snapshot)
}

fn build_snapshot_core(
    messages: Vec<UnifiedMessage>,
    today: NaiveDate,
    generated_at_ms: i64,
    timezone: String,
    day_count: usize,
    session_titles: &SessionTitleMap,
    weekly_reset_at_ms: Option<i64>,
) -> Result<ActivitySnapshot, String> {
    if day_count == 0 {
        return Err("day count must be greater than zero".to_string());
    }

    let first_day = today
        .checked_sub_days(Days::new((day_count - 1) as u64))
        .ok_or_else(|| "day range is too large".to_string())?;

    let rows = messages
        .into_iter()
        .filter_map(request_row)
        .filter(|row| {
            row.timestamp <= generated_at_ms
                && row.date <= today
                && (row.date >= first_day
                    || weekly_reset_at_ms
                        .map(|started_at_ms| row.timestamp >= started_at_ms)
                        .unwrap_or(false))
        })
        .collect::<Vec<_>>();
    let weekly_since_reset = weekly_reset_at_ms
        .filter(|started_at_ms| *started_at_ms <= generated_at_ms)
        .map(|started_at_ms| {
            let weekly_turns = aggregate_requests(
                rows.iter()
                    .filter(|row| {
                        row.timestamp >= started_at_ms && row.timestamp <= generated_at_ms
                    })
                    .cloned()
                    .collect(),
            );
            ActivityRangeSummary {
                started_at_ms,
                totals: activity_totals(&weekly_turns, |_| true),
            }
        });
    let turns = aggregate_requests(rows);

    let mut daily: BTreeMap<NaiveDate, DailyAccumulator> = BTreeMap::new();
    for turn in &turns {
        for request in &turn.contributions {
            let entry = daily.entry(request.date).or_default();
            entry.tokens.add_assign(&request.tokens);
            entry.cost = add_cost(entry.cost, request.cost);
            entry.token_costs.add(request.token_costs.as_ref());
            if let Some(metrics) = request.generation_metrics.measured() {
                entry.generated_tokens += metrics.generated_tokens as f64;
                entry.model_duration_ms += metrics.duration_ms as f64;
            }
            entry.turn_ids.insert(turn.id.clone());
            entry
                .session_ids
                .insert((request.source.clone(), request.session_id.clone()));

            let model = entry
                .models
                .entry((
                    request.source.clone(),
                    request.provider.clone(),
                    request.model.clone(),
                ))
                .or_default();
            model.tokens.add_assign(&request.tokens);
            model.cost = add_cost(model.cost, request.cost);
            model.turn_ids.insert(turn.id.clone());
            model
                .session_ids
                .insert((request.source.clone(), request.session_id.clone()));
        }
        if let Some(time_to_first_token_ms) = turn
            .anchor
            .time_to_first_token_ms
            .filter(|duration| *duration >= 0)
        {
            let entry = daily.entry(turn.anchor.date).or_default();
            entry.first_token_total_ms += time_to_first_token_ms as f64;
            entry.first_token_sample_count = entry.first_token_sample_count.saturating_add(1);
        }
    }

    let today_totals = activity_totals(&turns, |request| request.date == today);
    let range_totals = activity_totals(&turns, |request| {
        request.date >= first_day && request.date <= today
    });

    let mut days = Vec::with_capacity(day_count);
    for offset in 0..day_count {
        let date = first_day
            .checked_add_days(Days::new(offset as u64))
            .ok_or_else(|| "day range is too large".to_string())?;
        let entry = daily.get(&date);
        let mut models = entry
            .map(|value| {
                value
                    .models
                    .iter()
                    .map(|((platform, provider, model), usage)| DailyModelSummary {
                        platform: platform.clone(),
                        model: model.clone(),
                        provider: provider.clone(),
                        tokens: usage.tokens.clone(),
                        cost_usd: usage.cost,
                        request_count: usage.turn_ids.len(),
                        session_count: usage.session_ids.len(),
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        models.sort_by(|left, right| {
            right
                .tokens
                .total()
                .cmp(&left.tokens.total())
                .then_with(|| right.cost_usd.total_cmp(&left.cost_usd))
                .then_with(|| left.provider.cmp(&right.provider))
                .then_with(|| left.model.cmp(&right.model))
        });
        days.push(DailySummary {
            date: date.format("%Y-%m-%d").to_string(),
            tokens: entry.map(|value| value.tokens.clone()).unwrap_or_default(),
            cost_usd: entry.map(|value| value.cost).unwrap_or(0.0),
            generation_metrics: entry.and_then(|value| GenerationMetrics {
                generated_tokens: value.generated_tokens as i64,
                duration_ms: value.model_duration_ms as i64,
            }.measured()),
            average_generation_tokens_per_second: entry.and_then(|value| {
                (value.generated_tokens > 0.0 && value.model_duration_ms > 0.0)
                    .then_some(value.generated_tokens * 1_000.0 / value.model_duration_ms)
            }),
            average_time_to_first_token_ms: entry.and_then(|value| {
                (value.first_token_sample_count > 0).then_some(
                    value.first_token_total_ms / value.first_token_sample_count as f64,
                )
            }),
            first_token_sample_count: entry
                .map(|value| value.first_token_sample_count)
                .unwrap_or(0),
            request_count: entry.map(|value| value.turn_ids.len()).unwrap_or(0),
            session_count: entry.map(|value| value.session_ids.len()).unwrap_or(0),
            models,
        });
    }

    let sessions = build_today_sessions(turns, today, session_titles);

    Ok(ActivitySnapshot {
        schema_version: SCHEMA_VERSION,
        generated_at_ms,
        timezone,
        today: today_totals,
        range_totals: Some(range_totals),
        weekly_since_reset,
        sessions,
        days,
        sources: Vec::new(),
        memory_usage: None,
        pricing_catalog: None,
        pricing_models: Vec::new(),
    })
}

fn activity_totals(turns: &[TurnRow], include: impl Fn(&RequestRow) -> bool) -> ActivityTotals {
    let mut tokens = TokenBreakdown::default();
    let mut cost_usd = 0.0;
    let mut token_costs = OptionalTokenCostAccumulator::default();
    let mut session_ids = HashSet::new();
    let mut turn_count = 0_usize;
    let mut generated_tokens = 0.0;
    let mut model_duration_ms = 0.0;
    let mut first_token_total_ms = 0.0;
    let mut first_token_sample_count = 0_usize;
    for turn in turns {
        let mut included_turn = false;
        for request in turn.contributions.iter().filter(|request| include(request)) {
            tokens.add_assign(&request.tokens);
            cost_usd = add_cost(cost_usd, request.cost);
            token_costs.add(request.token_costs.as_ref());
            session_ids.insert((request.source.clone(), request.session_id.clone()));
            if let Some(metrics) = request.generation_metrics.measured() {
                generated_tokens += metrics.generated_tokens as f64;
                model_duration_ms += metrics.duration_ms as f64;
            }
            included_turn = true;
        }
        if included_turn {
            turn_count = turn_count.saturating_add(1);
            if include(&turn.anchor) {
                if let Some(time_to_first_token_ms) = turn
                    .anchor
                    .time_to_first_token_ms
                    .filter(|duration| *duration >= 0)
                {
                    first_token_total_ms += time_to_first_token_ms as f64;
                    first_token_sample_count = first_token_sample_count.saturating_add(1);
                }
            }
        }
    }
    ActivityTotals {
        tokens,
        cost_usd,
        token_costs: token_costs.complete_costs(),
        generation_metrics: GenerationMetrics {
            generated_tokens: generated_tokens as i64,
            duration_ms: model_duration_ms as i64,
        }.measured(),
        average_generation_tokens_per_second: (generated_tokens.is_finite()
            && model_duration_ms.is_finite()
            && generated_tokens > 0.0
            && model_duration_ms > 0.0)
            .then_some(generated_tokens * 1_000.0 / model_duration_ms),
        average_time_to_first_token_ms: (first_token_sample_count > 0)
            .then_some(first_token_total_ms / first_token_sample_count as f64),
        first_token_sample_count,
        request_count: turn_count,
        session_count: session_ids.len(),
    }
}

fn request_row(message: UnifiedMessage) -> Option<RequestRow> {
    let date = NaiveDate::parse_from_str(&message.date, "%Y-%m-%d").ok()?;
    let tokens = TokenBreakdown::from_unified(&message.tokens);
    let cost = valid_cost(message.cost);
    if tokens.total() == 0 && cost == 0.0 {
        return None;
    }

    let model = normalize_model_for_grouping(&message.model_id);
    let reasoning_effort = message.reasoning_effort.as_deref()
        .and_then(usage::normalize_reasoning_effort)
        .or_else(|| usage::reasoning_effort_from_model(&message.model_id));
    let physical_session_id = physical_session_id(&message);
    // Codex and Claude can continue a user session in another transcript.
    // Their parsers determine subagent status from explicit lineage.
    let is_subagent = message.is_subagent
        || (!matches!(message.client.as_str(), "codex" | "claude")
            && physical_session_id != message.session_id);
    let request_start_timestamp = message
        .duration_ms
        .filter(|duration| *duration > 0)
        .map(|duration| message.timestamp.saturating_sub(duration));
    let model_duration_ms = if tokens.output.saturating_add(tokens.reasoning) > 0 {
        message.model_duration_ms.filter(|duration| *duration > 0)
    } else {
        Some(0)
    };

    let generation_metrics = model_duration_ms.filter(|duration| *duration > 0)
        .map(|duration_ms| GenerationMetrics {
            generated_tokens: tokens.output.max(0).saturating_add(tokens.reasoning.max(0)),
            duration_ms,
        }).unwrap_or_default();
    Some(RequestRow {
        date,
        timestamp: message.timestamp,
        source: message.client,
        provider: message.provider_id,
        model,
        reasoning_effort,
        session_id: message.session_id,
        physical_session_id,
        is_subagent,
        workspace_path: nonempty(message.workspace_key),
        workspace_label: nonempty(message.workspace_label),
        agent: nonempty(message.agent),
        session_path: nonempty(message.session_path),
        prompt_preview: message.content_preview,
        output_preview: message.output_preview,
        tokens,
        cost,
        token_costs: message.token_costs,
        cost_source: message.cost_source.into(),
        service_tier: message.service_tier.into(),
        duration_ms: message.duration_ms,
        model_duration_ms,
        generation_metrics,
        time_to_first_token_ms: message
            .time_to_first_token_ms
            .filter(|duration| *duration >= 0),
        request_start_timestamp,
        request_end_timestamp: message.timestamp,
        is_turn_start: message.is_turn_start,
    })
}

fn physical_session_id(message: &UnifiedMessage) -> String {
    if let Some(physical_session_id) = message
        .physical_session_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        return physical_session_id.to_string();
    }

    message
        .session_path
        .as_deref()
        .and_then(|path| Path::new(path).file_stem())
        .and_then(|stem| stem.to_str())
        .unwrap_or(&message.session_id)
        .to_string()
}

fn aggregate_requests(mut rows: Vec<RequestRow>) -> Vec<TurnRow> {
    rows.sort_by(|left, right| {
        left.source
            .cmp(&right.source)
            .then_with(|| left.session_id.cmp(&right.session_id))
            .then_with(|| left.timestamp.cmp(&right.timestamp))
            .then_with(|| left.is_subagent.cmp(&right.is_subagent))
            .then_with(|| {
                let left_starts = left.prompt_preview.is_some() || left.is_turn_start;
                let right_starts = right.prompt_preview.is_some() || right.is_turn_start;
                right_starts.cmp(&left_starts)
            })
            .then_with(|| left.physical_session_id.cmp(&right.physical_session_id))
            .then_with(|| left.provider.cmp(&right.provider))
            .then_with(|| left.model.cmp(&right.model))
            .then_with(|| left.agent.cmp(&right.agent))
            .then_with(|| left.date.cmp(&right.date))
    });

    let mut turns = Vec::with_capacity(rows.len());
    let mut active_request: HashMap<RequestKey, (usize, usize)> = HashMap::new();
    let mut current_group: Option<(String, String)> = None;
    let mut current_root_turn = None;
    let mut turn_occurrences: HashMap<String, usize> = HashMap::new();

    for row in rows {
        let group = (row.source.clone(), row.session_id.clone());
        if current_group.as_ref() != Some(&group) {
            current_group = Some(group);
            current_root_turn = None;
            active_request.clear();
        }

        let key = row.key();
        let starts_request = row.prompt_preview.is_some() || row.is_turn_start;
        let starts_root_turn = !row.is_subagent && starts_request;

        if starts_root_turn {
            // A new root prompt cuts every active main-thread stream, including
            // streams using a different model. Existing child requests stay
            // attached to the turn in which they started even if their final
            // token event lands after this boundary.
            active_request.retain(|_, (turn_index, contribution_index)| {
                turns
                    .get(*turn_index)
                    .and_then(|turn: &TurnRow| turn.contributions.get(*contribution_index))
                    .is_some_and(|request| request.is_subagent)
            });

            let turn_index = push_turn(&mut turns, &mut turn_occurrences, row.clone());
            turns[turn_index].contributions.push(row);
            active_request.insert(key, (turn_index, 0));
            current_root_turn = Some(turn_index);
            continue;
        }

        if !starts_request {
            if let Some((turn_index, contribution_index)) = active_request.get(&key).copied() {
                merge_request(
                    &mut turns[turn_index].contributions[contribution_index],
                    row,
                );
                continue;
            }
        }

        let turn_index = current_root_turn.unwrap_or_else(|| {
            let index = push_turn(&mut turns, &mut turn_occurrences, row.clone());
            if !row.is_subagent {
                current_root_turn = Some(index);
            }
            index
        });
        let contribution_index = turns[turn_index].contributions.len();
        turns[turn_index].contributions.push(row);
        active_request.insert(key, (turn_index, contribution_index));
    }

    turns
}

fn push_turn(
    turns: &mut Vec<TurnRow>,
    occurrences: &mut HashMap<String, usize>,
    anchor: RequestRow,
) -> usize {
    let base_id = turn_base_id(&anchor);
    let occurrence = occurrences.entry(base_id.clone()).or_default();
    let id = format!("{base_id}|{occurrence}");
    *occurrence = occurrence.saturating_add(1);
    let index = turns.len();
    turns.push(TurnRow {
        id,
        anchor,
        contributions: Vec::new(),
    });
    index
}

fn merge_request(target: &mut RequestRow, row: RequestRow) {
    target.generation_metrics.generated_tokens = target.generation_metrics.generated_tokens
        .saturating_add(row.generation_metrics.generated_tokens);
    target.generation_metrics.duration_ms = target.generation_metrics.duration_ms
        .saturating_add(row.generation_metrics.duration_ms);
    if target.reasoning_effort != row.reasoning_effort {
        target.reasoning_effort = None;
    }
    target.tokens.add_assign(&row.tokens);
    target.cost = add_cost(target.cost, row.cost);
    target.token_costs = merge_token_costs(target.token_costs, row.token_costs);
    target.cost_source = merge_cost_source(target.cost_source, row.cost_source);
    target.service_tier = merge_service_tier(target.service_tier, row.service_tier);
    target.duration_ms = match (target.duration_ms, row.duration_ms) {
        (Some(left), Some(right)) => Some(left.max(right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
        (None, None) => None,
    };
    target.model_duration_ms = match (target.model_duration_ms, row.model_duration_ms) {
        (Some(left), Some(right)) => Some(left.saturating_add(right)),
        _ => None,
    };
    if target.time_to_first_token_ms.is_none() {
        target.time_to_first_token_ms = row.time_to_first_token_ms;
    }
    target.request_start_timestamp =
        match (target.request_start_timestamp, row.request_start_timestamp) {
            (Some(left), Some(right)) => Some(left.min(right)),
            (Some(left), None) => Some(left),
            (None, Some(right)) => Some(right),
            (None, None) => None,
        };
    target.request_end_timestamp = target
        .request_end_timestamp
        .max(row.request_end_timestamp)
        .max(row.timestamp);
    target.duration_ms =
        request_wall_duration(target.request_start_timestamp, target.request_end_timestamp)
            .or(target.duration_ms);
    target.is_turn_start |= row.is_turn_start;
    if target.prompt_preview.is_none() {
        target.prompt_preview = row.prompt_preview;
    }
    if row.output_preview.is_some() {
        target.output_preview = row.output_preview;
    }
    if target.workspace_label.is_none() {
        target.workspace_label = row.workspace_label;
    }
    if target.workspace_path.is_none() {
        target.workspace_path = row.workspace_path;
    }
    if target.session_path.is_none() {
        target.session_path = row.session_path;
    }
}

fn merge_token_costs(
    left: Option<TokenCostBreakdown>,
    right: Option<TokenCostBreakdown>,
) -> Option<TokenCostBreakdown> {
    match (left, right) {
        (Some(mut left), Some(right)) => {
            left.add_assign(&right);
            Some(left)
        }
        _ => None,
    }
}

fn build_today_sessions(
    turns: Vec<TurnRow>,
    today: NaiveDate,
    session_titles: &SessionTitleMap,
) -> Vec<SessionSummary> {
    let mut grouped: HashMap<(String, String), Vec<TurnRow>> = HashMap::new();
    for mut turn in turns {
        turn.contributions.retain(|row| row.date == today);
        if turn.contributions.is_empty() {
            continue;
        }
        grouped
            .entry((
                turn.anchor.source.clone(),
                turn.anchor.session_id.clone(),
            ))
            .or_default()
            .push(turn);
    }

    let mut sessions = Vec::with_capacity(grouped.len());
    for ((platform, session_id), session_turns) in grouped {
        let rows = session_turns
            .iter()
            .flat_map(|turn| turn.contributions.iter())
            .collect::<Vec<_>>();

        let workspace_label = rows
            .iter()
            .filter(|row| !row.is_subagent)
            .find_map(|row| row.workspace_label.clone())
            .or_else(|| rows.iter().find_map(|row| row.workspace_label.clone()));
        let workspace_path = rows
            .iter()
            .filter(|row| !row.is_subagent)
            .find_map(|row| row.workspace_path.clone())
            .or_else(|| rows.iter().find_map(|row| row.workspace_path.clone()));
        let started_at_ms = rows
            .iter()
            .map(|row| row.started_at_ms())
            .min()
            .unwrap_or(0);
        let ended_at_ms = rows
            .iter()
            .map(|row| row.request_end_timestamp)
            .max()
            .unwrap_or(0);
        let mut tokens = TokenBreakdown::default();
        let mut cost_usd = 0.0;
        let mut models = BTreeSet::new();
        for row in &rows {
            tokens.add_assign(&row.tokens);
            cost_usd = add_cost(cost_usd, row.cost);
            models.insert(row.model.clone());
        }

        let mut occurrences: HashMap<String, usize> = HashMap::new();
        let mut request_summaries = session_turns
            .into_iter()
            .map(|turn| turn_summary(turn, &mut occurrences))
            .collect::<Vec<_>>();
        request_summaries.sort_by(|left, right| {
            right
                .ended_at_ms
                .cmp(&left.ended_at_ms)
                .then_with(|| right.started_at_ms.cmp(&left.started_at_ms))
        });

        sessions.push(SessionSummary {
            title: session_titles
                .get(&(platform.clone(), session_id.clone()))
                .cloned(),
            id: session_id,
            platform,
            workspace_path,
            workspace_label,
            started_at_ms,
            ended_at_ms,
            tokens,
            cost_usd,
            models: models.into_iter().collect(),
            requests: request_summaries,
        });
    }

    sessions.sort_by(|left, right| {
        right
            .ended_at_ms
            .cmp(&left.ended_at_ms)
            .then_with(|| left.platform.cmp(&right.platform))
            .then_with(|| left.id.cmp(&right.id))
    });
    sessions
}

fn turn_summary(turn: TurnRow, occurrences: &mut HashMap<String, usize>) -> RequestSummary {
    let mut rows = turn.contributions;
    rows.sort_by(|left, right| {
        left.is_subagent
            .cmp(&right.is_subagent)
            .then_with(|| left.started_at_ms().cmp(&right.started_at_ms()))
            .then_with(|| left.request_end_timestamp.cmp(&right.request_end_timestamp))
            .then_with(|| left.physical_session_id.cmp(&right.physical_session_id))
    });

    let root_output = rows
        .iter()
        .filter(|row| !row.is_subagent)
        .filter_map(|row| {
            row.output_preview
                .as_ref()
                .map(|output| (row.request_end_timestamp, output.clone()))
        })
        .max_by_key(|(timestamp, _)| *timestamp)
        .map(|(_, output)| output);
    let fallback_output = rows
        .iter()
        .filter_map(|row| {
            row.output_preview
                .as_ref()
                .map(|output| (row.request_end_timestamp, output.clone()))
        })
        .max_by_key(|(timestamp, _)| *timestamp)
        .map(|(_, output)| output);
    let root_workspace = rows
        .iter()
        .filter(|row| !row.is_subagent)
        .find_map(|row| row.workspace_label.clone());
    let root_workspace_path = rows
        .iter()
        .filter(|row| !row.is_subagent)
        .find_map(|row| row.workspace_path.clone());
    let root_session_path = rows
        .iter()
        .filter(|row| !row.is_subagent)
        .find_map(|row| row.session_path.clone());

    let mut aggregate = rows[0].clone();
    for row in rows.iter().skip(1).cloned() {
        merge_request(&mut aggregate, row);
    }
    aggregate.session_id.clone_from(&turn.anchor.session_id);
    aggregate
        .physical_session_id
        .clone_from(&turn.anchor.physical_session_id);
    aggregate.is_subagent = false;
    aggregate.agent = None;
    aggregate.model.clone_from(&turn.anchor.model);
    aggregate.provider.clone_from(&turn.anchor.provider);
    aggregate.workspace_path = turn
        .anchor
        .workspace_path
        .clone()
        .or(root_workspace_path);
    aggregate.workspace_label = turn.anchor.workspace_label.clone().or(root_workspace);
    aggregate.session_path = turn.anchor.session_path.clone().or(root_session_path);
    aggregate
        .prompt_preview
        .clone_from(&turn.anchor.prompt_preview);
    aggregate.output_preview = if turn.anchor.is_subagent {
        root_output.or(fallback_output)
    } else {
        root_output
    };
    aggregate.time_to_first_token_ms = turn.anchor.time_to_first_token_ms;

    let contributions = rows
        .into_iter()
        .map(|row| request_summary(row, occurrences, Vec::new()))
        .collect();
    request_summary_with_id(aggregate, turn.id, contributions)
}

fn request_summary(
    row: RequestRow,
    occurrences: &mut HashMap<String, usize>,
    contributions: Vec<RequestSummary>,
) -> RequestSummary {
    let base_id = request_base_id(&row);
    let occurrence = occurrences.entry(base_id.clone()).or_default();
    let id = format!("{base_id}|{occurrence}");
    *occurrence = occurrence.saturating_add(1);
    request_summary_with_id(row, id, contributions)
}

fn request_summary_with_id(
    row: RequestRow,
    id: String,
    contributions: Vec<RequestSummary>,
) -> RequestSummary {
    let started_at_ms = row.started_at_ms();
    RequestSummary {
        id,
        platform: row.source,
        session_id: row.session_id,
        physical_session_id: row.physical_session_id,
        is_subagent: row.is_subagent,
        agent: row.agent,
        model: row.model,
        reasoning_effort: row.reasoning_effort,
        provider: row.provider,
        started_at_ms,
        ended_at_ms: row.request_end_timestamp,
        duration_ms: row.duration_ms,
        model_duration_ms: row.model_duration_ms,
        generation_metrics: row.generation_metrics.measured(),
        time_to_first_token_ms: row.time_to_first_token_ms,
        tokens: row.tokens,
        cost_usd: row.cost,
        cost_source: row.cost_source,
        service_tier: row.service_tier,
        session_path: row.session_path,
        prompt_preview: row.prompt_preview,
        output_preview: row.output_preview,
        contributions,
    }
}

fn request_base_id(row: &RequestRow) -> String {
    let mut id = String::from("request");
    for component in [
        row.date.format("%Y-%m-%d").to_string(),
        row.source.clone(),
        row.session_id.clone(),
        row.physical_session_id.clone(),
        row.provider.clone(),
        row.model.clone(),
        row.agent.clone().unwrap_or_default(),
        row.timestamp.to_string(),
    ] {
        id.push('|');
        id.push_str(&component.len().to_string());
        id.push(':');
        id.push_str(&component);
    }
    id
}

fn turn_base_id(row: &RequestRow) -> String {
    let mut id = String::from("turn");
    for component in [
        row.date.format("%Y-%m-%d").to_string(),
        row.source.clone(),
        row.session_id.clone(),
        row.physical_session_id.clone(),
        row.timestamp.to_string(),
    ] {
        id.push('|');
        id.push_str(&component.len().to_string());
        id.push(':');
        id.push_str(&component);
    }
    id
}

fn request_wall_duration(start_timestamp: Option<i64>, end_timestamp: i64) -> Option<i64> {
    let duration = end_timestamp.saturating_sub(start_timestamp?);
    (duration > 0).then_some(duration)
}

fn merge_cost_source(left: ActivityCostSource, right: ActivityCostSource) -> ActivityCostSource {
    if left == right {
        return left;
    }
    match (left, right) {
        (ActivityCostSource::Unknown, value) | (value, ActivityCostSource::Unknown) => value,
        _ => ActivityCostSource::Unknown,
    }
}

fn merge_service_tier(
    left: ActivityServiceTier,
    right: ActivityServiceTier,
) -> ActivityServiceTier {
    match (left, right) {
        (ActivityServiceTier::Mixed, _) | (_, ActivityServiceTier::Mixed) => {
            ActivityServiceTier::Mixed
        }
        (ActivityServiceTier::Unknown, tier) | (tier, ActivityServiceTier::Unknown) => tier,
        (left, right) if left == right => left,
        _ => ActivityServiceTier::Mixed,
    }
}

fn valid_cost(cost: f64) -> f64 {
    if cost.is_finite() && cost >= 0.0 {
        cost
    } else {
        0.0
    }
}

fn add_cost(left: f64, right: f64) -> f64 {
    let sum = left + right;
    if sum.is_finite() {
        sum
    } else {
        f64::MAX
    }
}

fn nonempty(value: Option<String>) -> Option<String> {
    value.filter(|text| !text.trim().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usage::TokenBreakdown as UnifiedTokens;
    use std::io::Cursor;

    fn message(
        date: &str,
        timestamp: i64,
        session_id: &str,
        path: &str,
        input: i64,
        output: i64,
    ) -> UnifiedMessage {
        let physical_session_id = Path::new(path)
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or(session_id)
            .to_string();
        UnifiedMessage {
            client: "codex".to_string(),
            model_id: "gpt-5.4(high)".to_string(),
            reasoning_effort: None,
            provider_id: "openai".to_string(),
            session_id: session_id.to_string(),
            physical_session_id: Some(physical_session_id.clone()),
            is_subagent: physical_session_id != session_id,
            workspace_key: Some("/tmp/project".to_string()),
            workspace_label: Some("project".to_string()),
            session_path: Some(path.to_string()),
            timestamp,
            date: date.to_string(),
            tokens: UnifiedTokens {
                input,
                output,
                cache_read: 0,
                cache_write: 0,
                reasoning: 0,
            },
            cache_write_breakdown: None,
            cost: 0.25,
            token_costs: None,
            cost_source: CostSource::Estimated,
            service_tier: ServiceTier::Unknown,
            duration_ms: Some(2_000),
            model_duration_ms: Some(1_000),
            time_to_first_token_ms: None,
            source_turn_id: None,
            message_count: 1,
            agent: None,
            dedup_key: None,
            content_preview: None,
            output_preview: None,
            is_turn_start: false,
        }
    }

    #[test]
    fn aggregates_requests_and_keeps_subagents_under_the_logical_session() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let mut first = message(
            "2026-07-13",
            600_000,
            "root-session",
            "/tmp/root-session.jsonl",
            100,
            0,
        );
        first.content_preview = Some("First prompt".to_string());
        first.is_turn_start = true;
        first.time_to_first_token_ms = Some(400);
        first.session_path = None;

        let mut tail = message(
            "2026-07-13",
            610_000,
            "root-session",
            "/tmp/root-session.jsonl",
            0,
            20,
        );
        tail.duration_ms = Some(1_000);
        tail.output_preview = Some("First answer".to_string());

        let mut second = message(
            "2026-07-13",
            700_000,
            "root-session",
            "/tmp/root-session.jsonl",
            50,
            10,
        );
        second.content_preview = Some("Second prompt".to_string());
        second.is_turn_start = true;
        second.time_to_first_token_ms = Some(600);

        let mut child = message(
            "2026-07-13",
            800_000,
            "root-session",
            "/tmp/child-a.jsonl",
            40,
            5,
        );
        child.agent = Some("Faraday".to_string());
        child.is_turn_start = true;
        child.time_to_first_token_ms = Some(800);

        let snapshot = build_snapshot(
            vec![first, tail, second, child],
            today,
            900_000,
            "Asia/Shanghai".to_string(),
            30,
        )
        .unwrap();

        assert_eq!(snapshot.today.session_count, 1);
        assert_eq!(snapshot.today.request_count, 2);
        assert_eq!(snapshot.sessions.len(), 1);
        assert_eq!(snapshot.today.average_time_to_first_token_ms, Some(500.0));
        assert_eq!(snapshot.today.first_token_sample_count, 2);
        assert_eq!(snapshot.sessions[0].id, "root-session");
        assert_eq!(
            snapshot.sessions[0].workspace_path.as_deref(),
            Some("/tmp/project")
        );
        assert_eq!(snapshot.sessions[0].requests.len(), 2);

        let merged = snapshot.sessions[0]
            .requests
            .iter()
            .find(|request| request.prompt_preview.as_deref() == Some("First prompt"))
            .unwrap();
        assert_eq!(merged.tokens.input, 100);
        assert_eq!(merged.tokens.output, 20);
        assert_eq!(merged.started_at_ms, 598_000);
        assert_eq!(merged.ended_at_ms, 610_000);
        assert_eq!(merged.duration_ms, Some(12_000));
        assert_eq!(merged.model_duration_ms, Some(1_000));
        assert_eq!(merged.time_to_first_token_ms, Some(400));
        assert_eq!(merged.output_preview.as_deref(), Some("First answer"));
        assert_eq!(
            merged.session_path.as_deref(),
            Some("/tmp/root-session.jsonl")
        );

        let second_turn = snapshot.sessions[0]
            .requests
            .iter()
            .find(|request| request.prompt_preview.as_deref() == Some("Second prompt"))
            .unwrap();
        assert_eq!(second_turn.tokens.input, 90);
        assert_eq!(second_turn.tokens.output, 15);
        assert_eq!(second_turn.time_to_first_token_ms, Some(600));
        assert_eq!(second_turn.contributions.len(), 2);

        let child = second_turn
            .contributions
            .iter()
            .find(|request| request.physical_session_id == "child-a")
            .unwrap();
        assert!(child.is_subagent);
        assert_eq!(child.session_id, "root-session");
        assert_eq!(child.agent.as_deref(), Some("Faraday"));
        assert_eq!(child.time_to_first_token_ms, Some(800));
        assert_eq!(child.session_path.as_deref(), Some("/tmp/child-a.jsonl"));
    }

    fn request_detail_fixture(rows: Vec<serde_json::Value>, start: i64, end: i64) -> RequestDetail {
        let lines = rows
            .into_iter()
            .map(|row| row.to_string())
            .collect::<Vec<_>>()
            .join("\n");
        extract_request_detail_from_reader(Cursor::new(lines), start, end).unwrap()
    }

    #[test]
    fn request_detail_reads_response_items_and_preserves_text_parts() {
        let detail = request_detail_fixture(
            vec![
                serde_json::json!({"timestamp":1000,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"question"},{"type":"input_image","image_url":"hidden"}]}}),
                serde_json::json!({"timestamp":1100,"type":"response_item","payload":{"type":"message","role":"assistant","channel":"final","content":[{"type":"output_text","text":"first\nline"},{"type":"text","text":"second paragraph"}]}}),
            ],
            1000,
            1200,
        );
        assert_eq!(detail.prompt.as_deref(), Some("question"));
        assert_eq!(
            detail.output.as_deref(),
            Some("first\nline\n\nsecond paragraph")
        );
    }

    #[test]
    fn request_detail_deduplicates_mirrors_but_preserves_repeated_messages() {
        let mut rows = Vec::new();
        for offset in [0, 10] {
            rows.push(serde_json::json!({"timestamp":1000+offset,"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"repeat"}}));
            rows.push(serde_json::json!({"timestamp":1001+offset,"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"repeat"}]}}));
        }
        let detail = request_detail_fixture(rows, 1000, 1100);
        assert_eq!(detail.output.as_deref(), Some("repeat\n\nrepeat"));
    }
}
