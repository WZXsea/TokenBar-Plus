//! Read-only ZCode usage adapter. SQLite is authoritative; older model-I/O
//! rollouts fill requests absent from the database. Cached rollouts contain
//! normalized accounting only, never request/response bodies.
use crate::usage::{
    normalize_workspace_key, workspace_label_from_key, TokenBreakdown, UnifiedMessage,
};
use crate::{RequestDetail, SessionTitleMap};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

#[derive(Clone, Default)]
pub struct LocalParseOptions {
    pub home_dir: Option<String>,
    pub use_env_roots: bool,
    pub since: Option<String>,
    pub until: Option<String>,
}
#[derive(Default)]
struct Session {
    parent: Option<String>,
    directory: String,
    title: String,
}
#[derive(Default, Serialize, Deserialize)]
struct CachedFile {
    size: u64,
    modified_ns: u128,
    messages: Vec<CachedMessage>,
}
#[derive(Serialize, Deserialize)]
struct CachedMessage {
    turn_id: Option<String>,
    message: UnifiedMessage,
}
#[derive(Default, Serialize, Deserialize)]
struct Cache {
    version: u32,
    files: HashMap<String, CachedFile>,
}

fn roots(options: &LocalParseOptions) -> Vec<PathBuf> {
    let home = options
        .home_dir
        .as_ref()
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from));
    let mut roots = home
        .into_iter()
        .map(|p| p.join(".zcode/cli"))
        .collect::<Vec<_>>();
    let override_base = options
        .use_env_roots
        .then(|| std::env::var_os("ZCODE_DATA_BASE_DIR"))
        .flatten()
        .filter(|s| !s.is_empty());
    if options.home_dir.is_none() {
        if let Some(base) = override_base.as_ref() {
            roots.push(PathBuf::from(base).join(".zcode/cli"));
        }
    }
    if options.use_env_roots && options.home_dir.is_none() && override_base.is_none() {
        if let Some(home) = std::env::var_os("HOME") {
            if let Ok(bytes) = fs::read(PathBuf::from(home).join(".zcode/v2/setting.json")) {
                if let Ok(v) = serde_json::from_slice::<Value>(&bytes) {
                    if let Some(base) = v
                        .get("dataBaseDir")
                        .and_then(Value::as_str)
                        .filter(|s| !s.trim().is_empty())
                    {
                        roots.push(PathBuf::from(base).join(".zcode/cli"));
                    }
                }
            }
        }
    }
    roots.sort();
    roots.dedup();
    roots
}
fn readonly(path: &Path) -> Result<Connection, String> {
    let db = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| format!("ZCode database: {e}"))?;
    db.busy_timeout(std::time::Duration::from_millis(250))
        .map_err(|e| e.to_string())?;
    Ok(db)
}
fn sessions(db: &Connection) -> Result<HashMap<String, Session>, String> {
    let mut query = db
        .prepare("SELECT id,parent_id,directory,title FROM session")
        .map_err(|e| e.to_string())?;
    let rows = query
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                Session {
                    parent: r.get(1)?,
                    directory: r.get(2)?,
                    title: r.get(3)?,
                },
            ))
        })
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<_, _>>().map_err(|e| e.to_string())
}
fn root_session(id: &str, metadata: &HashMap<String, Session>) -> String {
    let mut current = id.to_owned();
    let mut seen = HashSet::new();
    while seen.insert(current.clone()) {
        match metadata.get(&current).and_then(|s| s.parent.as_ref()) {
            Some(parent) if metadata.contains_key(parent) => current = parent.clone(),
            _ => break,
        }
    }
    current
}
fn tokens_with_total(
    input: i64,
    output: i64,
    read: i64,
    write: i64,
    reason: i64,
    total: i64,
) -> TokenBreakdown {
    let cache = read.max(0).saturating_add(write.max(0));
    let input = input.max(0);
    let output = output.max(0);
    let inclusive = input.saturating_add(output);
    let exclusive = inclusive.saturating_add(cache);
    let normalized =
        if input == 0 || (total > 0 && total.abs_diff(exclusive) < total.abs_diff(inclusive)) {
            input.saturating_add(cache)
        } else {
            input
        };
    tokens(normalized, output, read, write, reason)
}
fn tokens(input: i64, output: i64, read: i64, write: i64, reason: i64) -> TokenBreakdown {
    let input = input.max(0);
    let output = output.max(0);
    let read = read.max(0).min(input);
    let write = write.max(0).min(input - read);
    let reason = reason.max(0).min(output);
    TokenBreakdown {
        input: input - read - write,
        output: output - reason,
        cache_read: read,
        cache_write: write,
        reasoning: reason,
    }
}
fn db_messages(path: &Path) -> Result<(Vec<UnifiedMessage>, HashMap<String, Session>), String> {
    let db = readonly(path)?;
    let metadata = sessions(&db)?;
    let mut query=db.prepare("SELECT logical_request_id,attempt_index,session_id,turn_id,provider_id,model_id,started_at,first_token_at,completed_at,duration_ms,time_to_first_token_ms,input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens,reasoning_tokens,agent,query_source,COALESCE(provider_total_tokens,computed_total_tokens) FROM model_usage ORDER BY started_at,id").map_err(|e|e.to_string())?;
    let rows = query
        .query_map([], |r| {
            let physical = r.get::<_, String>(2)?;
            let start = r.get::<_, i64>(6)?;
            let first = r.get::<_, Option<i64>>(7)?;
            let end = r.get::<_, Option<i64>>(8)?;
            let mut message = UnifiedMessage::new_with_agent(
                "zcode",
                r.get::<_, String>(5)?,
                r.get::<_, String>(4)?,
                &physical,
                end.unwrap_or(start),
                tokens_with_total(
                    r.get(11)?,
                    r.get(12)?,
                    r.get(13)?,
                    r.get(14)?,
                    r.get(15)?,
                    r.get(18)?,
                ),
                0.0,
                r.get(16)?,
            );
            message.duration_ms = r
                .get::<_, Option<i64>>(9)?
                .filter(|v| *v > 0)
                .or_else(|| end.and_then(|e| (e > start).then_some(e - start)));
            message.time_to_first_token_ms = r
                .get::<_, Option<i64>>(10)?
                .filter(|v| *v >= 0)
                .or_else(|| first.filter(|v| *v >= start).map(|v| v - start));
            message.model_duration_ms = message.duration_ms;
            message.physical_session_id = Some(physical.clone());
            message.source_turn_id = r.get(3)?;
            message.dedup_key = Some(format!(
                "zcode:{}:{}",
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?
            ));
            message.session_path = Some(format!("{}#{physical}", path.display()));
            let logical = root_session(&physical, &metadata);
            message.is_subagent = logical != physical || r.get::<_, String>(17)? == "subagent";
            message.session_id = logical;
            if let Some(session) = metadata.get(&physical) {
                let key = normalize_workspace_key(&session.directory);
                message.set_workspace(
                    key.clone(),
                    key.as_deref().and_then(workspace_label_from_key),
                );
            }
            Ok(message)
        })
        .map_err(|e| e.to_string())?;
    Ok((
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?,
        metadata,
    ))
}
fn number(value: &Value, key: &str) -> i64 {
    value.get(key).and_then(Value::as_i64).unwrap_or(0)
}
fn timestamp(value: &Value, key: &str) -> Option<i64> {
    value.get(key).and_then(|v| {
        v.as_i64().or_else(|| {
            v.as_str().and_then(|s| {
                chrono::DateTime::parse_from_rfc3339(s)
                    .ok()
                    .map(|d| d.timestamp_millis())
            })
        })
    })
}
fn rollout_message(value: &Value, path: &Path) -> Option<UnifiedMessage> {
    if value.get("type")?.as_str()? != "model_io" {
        return None;
    }
    let usage = value.pointer("/response/usage")?;
    let session = value.get("sessionId")?.as_str()?;
    let request = value.get("requestId")?.as_str()?;
    let start = timestamp(value, "startedAt")?;
    let end = timestamp(value, "completedAt");
    let model = value.pointer("/model/modelId")?.as_str()?;
    let provider = value
        .pointer("/model/providerId")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let mut message = UnifiedMessage::new_with_agent(
        "zcode",
        model,
        provider,
        session,
        end.unwrap_or(start),
        tokens_with_total(
            number(usage, "inputTokens"),
            number(usage, "outputTokens"),
            number(usage, "cacheReadTokens"),
            number(usage, "cacheWriteTokens"),
            number(usage, "reasoningTokens"),
            number(usage, "totalTokens"),
        ),
        0.0,
        None,
    );
    message.duration_ms = value
        .get("durationMs")
        .and_then(Value::as_i64)
        .filter(|v| *v > 0)
        .or_else(|| end.and_then(|e| (e > start).then_some(e - start)));
    // ZCode reports per-API response throughput, including first-token wait.
    message.model_duration_ms = message.duration_ms;
    message.source_turn_id = value
        .get("turnId")
        .and_then(Value::as_str)
        .map(str::to_owned);
    message.physical_session_id = Some(session.to_owned());
    message.session_path = Some(path.to_string_lossy().into_owned());
    message.dedup_key = Some(format!("zcode:{request}:{}", number(value, "attempt")));
    message.is_subagent = value.get("querySource").and_then(Value::as_str) == Some("subagent");
    Some(message)
}
fn parse_rollout(path: &Path) -> Vec<UnifiedMessage> {
    let Ok(file) = fs::File::open(path) else {
        return Vec::new();
    };
    BufReader::new(file)
        .lines()
        .map_while(Result::ok)
        .filter_map(|line| {
            serde_json::from_str::<Value>(&line)
                .ok()
                .and_then(|v| rollout_message(&v, path))
        })
        .collect()
}
fn cache_path(options: &LocalParseOptions) -> Option<PathBuf> {
    options
        .home_dir
        .as_ref()
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .map(|p| p.join("Library/Caches/TokenBar/zcode-rollouts-v1.json"))
}
fn write_cache(path: &Path, cache: &Cache) {
    let Some(parent) = path.parent() else { return };
    if fs::create_dir_all(parent).is_err() {
        return;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
    }
    let temp = path.with_extension(format!("{}.tmp", std::process::id()));
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    if let Ok(mut file) = options.open(&temp) {
        let success = serde_json::to_writer(&mut file, cache).is_ok() && file.flush().is_ok();
        drop(file);
        if success {
            let _ = fs::rename(&temp, path);
        }
        let _ = fs::remove_file(temp);
    }
}
pub fn parse_local_zcode_messages(
    options: LocalParseOptions,
) -> Result<Vec<UnifiedMessage>, String> {
    let cache_path = cache_path(&options);
    let mut cache = cache_path
        .as_ref()
        .and_then(|p| fs::read(p).ok())
        .and_then(|b| serde_json::from_slice::<Cache>(&b).ok())
        .filter(|c| c.version == 3)
        .unwrap_or(Cache {
            version: 3,
            ..Default::default()
        });
    let mut messages = Vec::new();
    let mut all_metadata = HashMap::new();
    let mut seen = HashSet::new();
    let mut changed = false;
    let mut files = HashSet::new();
    let mut historical = Vec::new();
    for root in roots(&options) {
        let db_path = root.join("db/db.sqlite");
        if db_path.is_file() {
            // Older ZCode schemas and brief SQLite locks can still use durable
            // rollouts. An optional provider must keep other platforms usable.
            if let Ok((rows, metadata)) = db_messages(&db_path) {
                all_metadata.extend(metadata);
                for row in rows {
                    if seen.insert(row.dedup_key.clone()) {
                        messages.push(row)
                    }
                }
            }
        }
        for dir in [root.join("rollout"), root.join("debug")] {
            let Ok(entries) = fs::read_dir(dir) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
                    continue;
                }
                let Ok(meta) = entry.metadata() else { continue };
                let modified_ns = meta
                    .modified()
                    .ok()
                    .and_then(|v| v.duration_since(std::time::UNIX_EPOCH).ok())
                    .map_or(0, |v| v.as_nanos());
                let key = path.to_string_lossy().into_owned();
                files.insert(key.clone());
                let valid = cache
                    .files
                    .get(&key)
                    .is_some_and(|c| c.size == meta.len() && c.modified_ns == modified_ns);
                if !valid {
                    cache.files.insert(
                        key.clone(),
                        CachedFile {
                            size: meta.len(),
                            modified_ns,
                            messages: parse_rollout(&path)
                                .into_iter()
                                .map(|message| CachedMessage {
                                    turn_id: message.source_turn_id.clone(),
                                    message,
                                })
                                .collect(),
                        },
                    );
                    changed = true;
                }
                if let Some(cached) = cache.files.get(&key) {
                    for cached_message in &cached.messages {
                        let mut message = cached_message.message.clone();
                        message.source_turn_id = cached_message.turn_id.clone();
                        message.model_duration_ms = message.duration_ms;
                        if seen.insert(message.dedup_key.clone()) {
                            historical.push(message)
                        }
                    }
                }
            }
        }
    }
    let mut unmatched = (0..messages.len()).collect::<HashSet<_>>();
    for message in historical {
        let matching = unmatched
            .iter()
            .copied()
            .filter(|i| {
                let db = &messages[*i];
                db.physical_session_id == message.physical_session_id
                    && db.model_id == message.model_id
                    && db.tokens == message.tokens
                    && (db.timestamp.abs_diff(message.timestamp) <= 1000
                        || db
                            .timestamp
                            .saturating_sub(db.duration_ms.unwrap_or(0))
                            .abs_diff(
                                message
                                    .timestamp
                                    .saturating_sub(message.duration_ms.unwrap_or(0)),
                            )
                            <= 1000)
            })
            .min_by_key(|i| messages[*i].timestamp.abs_diff(message.timestamp));
        if let Some(index) = matching {
            unmatched.remove(&index);
        } else {
            messages.push(message);
        }
    }
    let old_count = cache.files.len();
    cache.files.retain(|path, _| files.contains(path));
    changed |= old_count != cache.files.len();
    if changed {
        if let Some(path) = cache_path {
            write_cache(&path, &cache)
        }
    }
    let mut turns = HashSet::new();
    messages.sort_by_key(|m| m.timestamp);
    for message in &mut messages {
        let physical = message
            .physical_session_id
            .as_deref()
            .unwrap_or(&message.session_id)
            .to_owned();
        message.session_id = root_session(&physical, &all_metadata);
        message.is_subagent |= physical != message.session_id;
        if let Some(session) = all_metadata.get(&physical) {
            let key = normalize_workspace_key(&session.directory);
            message.set_workspace(
                key.clone(),
                key.as_deref().and_then(workspace_label_from_key),
            );
        }
        message.is_turn_start = turns.insert((
            physical,
            message
                .source_turn_id
                .clone()
                .unwrap_or_else(|| message.dedup_key.clone().unwrap_or_default()),
        ));
    }
    messages.retain(|m| {
        options.since.as_ref().is_none_or(|d| &m.date >= d)
            && options.until.as_ref().is_none_or(|d| &m.date <= d)
    });
    Ok(messages)
}
pub fn load_zcode_session_titles(options: &LocalParseOptions) -> SessionTitleMap {
    let mut titles = SessionTitleMap::new();
    for root in roots(options) {
        if let Ok(db) = readonly(&root.join("db/db.sqlite")) {
            if let Ok(metadata) = sessions(&db) {
                for (id, session) in &metadata {
                    if !session.title.trim().is_empty() {
                        titles.insert(("zcode".into(), id.clone()), session.title.clone());
                    }
                }
            }
        }
    }
    titles
}
fn message_text(value: &Value) -> Option<String> {
    if let Some(text) = value.get("text").and_then(Value::as_str) {
        return Some(text.to_owned());
    }
    if let Some(text) = value.get("content").and_then(Value::as_str) {
        return Some(text.to_owned());
    }
    let parts = value.get("content")?.as_array()?;
    let text = parts
        .iter()
        .filter(|p| {
            matches!(
                p.get("type").and_then(Value::as_str),
                Some("text" | "input_text" | "output_text")
            )
        })
        .filter_map(|p| p.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    (!text.is_empty()).then_some(text)
}
pub fn extract_request_detail(path: &Path, start: i64, end: i64) -> Result<RequestDetail, String> {
    if start > end {
        return Err("request start must not be after request end".into());
    }
    let path_text = path.to_string_lossy();
    let mut prompts = Vec::new();
    let mut outputs = Vec::new();
    if let Some((database, session)) = path_text.rsplit_once('#') {
        let db = readonly(Path::new(database))?;
        let mut query=db.prepare("SELECT m.data,p.data FROM message m JOIN part p ON p.message_id=m.id AND p.session_id=m.session_id WHERE m.session_id=?1 AND m.id IN (SELECT assistant_message_id FROM model_usage WHERE session_id=?1 AND COALESCE(completed_at,started_at) BETWEEN ?2 AND ?3 UNION SELECT parent_user_message_id FROM model_usage WHERE session_id=?1 AND COALESCE(completed_at,started_at) BETWEEN ?2 AND ?3) ORDER BY m.time_created,p.sequence,p.time_created").map_err(|e|e.to_string())?;
        let rows = query
            .query_map(rusqlite::params![session, start, end], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            let (message, part) = row.map_err(|e| e.to_string())?;
            let (Ok(message), Ok(part)) = (
                serde_json::from_str::<Value>(&message),
                serde_json::from_str::<Value>(&part),
            ) else {
                continue;
            };
            if part.get("type").and_then(Value::as_str) != Some("text") {
                continue;
            }
            let Some(text) = message_text(&part) else {
                continue;
            };
            match message.get("role").and_then(Value::as_str) {
                Some("user") => prompts.push(text),
                Some("assistant") => outputs.push(text),
                _ => {}
            }
        }
    } else {
        let file = fs::File::open(path).map_err(|e| e.to_string())?;
        for line in BufReader::new(file).lines().map_while(Result::ok) {
            let Ok(value) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            let Some(message) = rollout_message(&value, path) else {
                continue;
            };
            if message.timestamp < start || message.timestamp > end {
                continue;
            }
            if let Some(list) = value.pointer("/request/messages").and_then(Value::as_array) {
                if let Some(text) = list
                    .iter()
                    .rev()
                    .filter(|item| item.get("role").and_then(Value::as_str) == Some("user"))
                    .find_map(message_text)
                {
                    if prompts.last() != Some(&text) {
                        prompts.push(text)
                    }
                }
            }
            if let Some(response) = value.get("response") {
                if let Some(text) = message_text(response) {
                    outputs.push(text)
                } else if let Some(content) = response.get("text").and_then(Value::as_str) {
                    outputs.push(content.to_owned())
                }
            }
        }
    }
    Ok(RequestDetail {
        prompt: (!prompts.is_empty()).then(|| prompts.join("\n\n")),
        output: (!outputs.is_empty()).then(|| outputs.join("\n\n")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn token_subcategories_are_disjoint() {
        let exclusive = tokens_with_total(20, 25, 70, 10, 5, 125);
        assert_eq!(exclusive.total(), 125);
        assert_eq!(exclusive.input, 20);
        let t = tokens(100, 25, 70, 10, 5);
        assert_eq!(t.total(), 125);
        assert_eq!(t.input, 20);
        assert_eq!(t.output, 20);
        assert_eq!(tokens(10, 2, 99, 99, 99).total(), 12);
    }
    #[test]
    fn rollout_response_throughput_uses_one_api_duration() {
        let v = serde_json::json!({"type":"model_io","requestId":"r","attempt":1,"sessionId":"s","turnId":"t","model":{"modelId":"m","providerId":"p"},"startedAt":1000,"completedAt":2000,"response":{"usage":{"inputTokens":100,"cacheReadTokens":75,"outputTokens":20,"reasoningTokens":5}}});
        let m = rollout_message(&v, Path::new("fixture.jsonl")).unwrap();
        assert_eq!(m.tokens.total(), 120);
        assert_eq!(m.duration_ms, Some(1000));
        assert_eq!(m.model_duration_ms, Some(1000));
        assert_eq!(m.cost_source, crate::usage::CostSource::Unknown);
        assert_eq!(m.dedup_key.as_deref(), Some("zcode:r:1"));
    }
    #[test]
    fn parent_chain_is_bounded() {
        let mut s = HashMap::new();
        s.insert(
            "child".into(),
            Session {
                parent: Some("root".into()),
                ..Default::default()
            },
        );
        s.insert("root".into(), Session::default());
        assert_eq!(root_session("child", &s), "root");
        s.get_mut("root").unwrap().parent = Some("child".into());
        assert!(!root_session("child", &s).is_empty());
    }
    #[test]
    fn sqlite_is_authoritative_and_cache_retains_turns() {
        let home = tempfile::tempdir().unwrap();
        let root = home.path().join(".zcode/cli");
        fs::create_dir_all(root.join("db")).unwrap();
        fs::create_dir_all(root.join("rollout")).unwrap();
        let path = root.join("db/db.sqlite");
        let db = Connection::open(&path).unwrap();
        db.execute_batch("CREATE TABLE session(id TEXT,parent_id TEXT,directory TEXT,title TEXT);INSERT INTO session VALUES('s',NULL,'/tmp/project','example');CREATE TABLE model_usage(logical_request_id TEXT,attempt_index INTEGER,session_id TEXT,turn_id TEXT,provider_id TEXT,model_id TEXT,started_at INTEGER,first_token_at INTEGER,completed_at INTEGER,duration_ms INTEGER,time_to_first_token_ms INTEGER,input_tokens INTEGER,output_tokens INTEGER,cache_read_input_tokens INTEGER,cache_creation_input_tokens INTEGER,reasoning_tokens INTEGER,agent TEXT,query_source TEXT,provider_total_tokens INTEGER,computed_total_tokens INTEGER,id TEXT);INSERT INTO model_usage VALUES('db-id',0,'s','t','p','m',1000,1200,2000,1000,200,100,20,75,0,5,NULL,'main_turn',120,120,'db-id');").unwrap();
        drop(db);
        let original = fs::read(&path).unwrap();
        let value = serde_json::json!({"type":"model_io","requestId":"different-rollout-id","sessionId":"s","turnId":"t","model":{"modelId":"m","providerId":"p"},"startedAt":1005,"completedAt":1995,"response":{"usage":{"inputTokens":100,"cacheReadTokens":75,"outputTokens":20,"reasoningTokens":5,"totalTokens":120}}});
        fs::write(root.join("rollout/example.jsonl"), value.to_string()).unwrap();
        let options = LocalParseOptions {
            home_dir: Some(home.path().to_string_lossy().into_owned()),
            ..Default::default()
        };
        let rows = parse_local_zcode_messages(options.clone()).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].model_duration_ms, Some(1000));
        assert_eq!(rows[0].tokens.total(), 120);
        let cached = parse_local_zcode_messages(options.clone()).unwrap();
        assert_eq!(cached.len(), 1);
        assert_eq!(cached[0].source_turn_id.as_deref(), Some("t"));
        assert_eq!(fs::read(&path).unwrap(), original);
        // An unsupported/temporarily unreadable optional database falls back
        // to rollouts without interrupting another platform's snapshot.
        let db = Connection::open(&path).unwrap();
        db.execute("ALTER TABLE model_usage RENAME TO older_usage", [])
            .unwrap();
        let fallback = parse_local_zcode_messages(options).unwrap();
        assert_eq!(fallback.len(), 1);
        assert_eq!(fallback[0].tokens.total(), 120);
    }
}
