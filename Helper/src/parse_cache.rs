//! Reuse derived per-file accounting inside a long-lived helper process.
//! Complete source records and derived previews stay in memory; this module
//! creates no disk cache, preserving TokenBar's persistent-cache redaction policy.

use std::any::Any;
use std::collections::HashMap;
use std::fs::Metadata;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::usage::{CacheWriteBreakdown, UnifiedMessage};

const MAX_BYTES: usize = 64 * 1024 * 1024;
const MAX_ENTRIES: usize = 4096;
const TTL: Duration = Duration::from_secs(30 * 60);
const SWEEP_INTERVAL: Duration = Duration::from_secs(60);
const ADMISSION_PROTECTION: Duration = Duration::from_secs(30);

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct FileRead<T> {
    pub(crate) value: T,
    #[serde(skip, default = "complete_read")]
    pub(crate) complete: bool,
}

fn complete_read() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Fingerprint(String);

impl Fingerprint {
    pub(crate) fn read(path: &Path) -> Option<Self> {
        let metadata = path.metadata().ok()?;
        let modified = metadata
            .modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_nanos();
        Some(Self(format!(
            "{}:{modified}:{}",
            metadata.len(),
            file_identity(&metadata)
        )))
    }
}

#[cfg(unix)]
fn file_identity(metadata: &Metadata) -> String {
    use std::os::unix::fs::MetadataExt;
    format!(
        "{}:{}:{}:{}",
        metadata.dev(),
        metadata.ino(),
        metadata.ctime(),
        metadata.ctime_nsec()
    )
}

#[cfg(not(unix))]
fn file_identity(metadata: &Metadata) -> String {
    format!("{:?}", metadata.created().ok())
}

#[derive(Clone, PartialEq, Eq, Hash)]
struct CacheKey {
    home: PathBuf,
    kind: String,
    path: PathBuf,
}

struct Entry {
    fingerprint: Fingerprint,
    payload: Arc<dyn Any + Send + Sync>,
    estimated_bytes: usize,
    last_used: Instant,
}

#[derive(Default)]
struct ByteCount(usize);

impl io::Write for ByteCount {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0 += bytes.len();
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct MemoryCache {
    entries: HashMap<CacheKey, Entry>,
    bytes: usize,
    last_sweep: Instant,
}

impl Default for MemoryCache {
    fn default() -> Self {
        Self {
            entries: HashMap::new(),
            bytes: 0,
            last_sweep: Instant::now(),
        }
    }
}

impl MemoryCache {
    fn remove(&mut self, key: &CacheKey) {
        if let Some(entry) = self.entries.remove(key) {
            self.bytes -= entry.estimated_bytes;
        }
    }

    fn sweep(&mut self, now: Instant) {
        if now.duration_since(self.last_sweep) < SWEEP_INTERVAL {
            return;
        }
        self.entries
            .retain(|_, entry| now.duration_since(entry.last_used) <= TTL);
        self.bytes = self
            .entries
            .values()
            .map(|entry| entry.estimated_bytes)
            .sum();
        self.last_sweep = now;
    }

    fn admit(
        &mut self,
        key: CacheKey,
        entry: Entry,
        now: Instant,
        maximum_bytes: usize,
        maximum_entries: usize,
    ) -> bool {
        let replacing = self.entries.contains_key(&key);
        self.remove(&key);
        if entry.estimated_bytes > maximum_bytes || maximum_entries == 0 {
            return false;
        }
        while self.bytes + entry.estimated_bytes > maximum_bytes
            || self.entries.len() >= maximum_entries
        {
            let Some(oldest) = self
                .entries
                .iter()
                .filter(|(_, current)| {
                    replacing || now.duration_since(current.last_used) >= ADMISSION_PROTECTION
                })
                .min_by_key(|(_, entry)| entry.last_used)
                .map(|(key, _)| key.clone())
            else {
                // Retain the hot working set instead of making a sequential
                // scan just over capacity evict itself on every refresh.
                return false;
            };
            self.remove(&oldest);
        }
        self.bytes += entry.estimated_bytes;
        self.entries.insert(key, entry);
        true
    }
}

static CACHE: OnceLock<Mutex<MemoryCache>> = OnceLock::new();

fn memory_cache() -> &'static Mutex<MemoryCache> {
    CACHE.get_or_init(|| Mutex::new(MemoryCache::default()))
}

pub(crate) struct ParseCache {
    home: PathBuf,
}

impl ParseCache {
    pub(crate) fn open(home: Option<&str>) -> Option<Self> {
        let home = home
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(PathBuf::from))?;
        Some(Self { home })
    }

    fn key(&self, kind: &str, path: &Path) -> CacheKey {
        CacheKey {
            home: self.home.clone(),
            kind: kind.to_string(),
            path: path.to_path_buf(),
        }
    }

    pub(crate) fn load<T: Clone + Send + Sync + 'static>(
        &self,
        kind: &str,
        path: &Path,
        fingerprint: &Fingerprint,
    ) -> Option<T> {
        let key = self.key(kind, path);
        let payload = {
            let now = Instant::now();
            let mut cache = memory_cache().lock().ok()?;
            cache.sweep(now);
            let usable = cache.entries.get(&key).is_some_and(|entry| {
                entry.fingerprint == *fingerprint && now.duration_since(entry.last_used) <= TTL
            });
            if !usable {
                if cache
                    .entries
                    .get(&key)
                    .is_some_and(|entry| now.duration_since(entry.last_used) > TTL)
                {
                    cache.remove(&key);
                }
                return None;
            }
            let entry = cache.entries.get_mut(&key)?;
            entry.last_used = now;
            Arc::clone(&entry.payload)
        };
        payload.downcast_ref::<T>().cloned()
    }

    pub(crate) fn store<T: Serialize + Clone + Send + Sync + 'static>(
        &self,
        kind: &str,
        path: &Path,
        fingerprint: &Fingerprint,
        value: &T,
    ) {
        // Estimate the retained payload once without allocating a second JSON
        // buffer. Warm reads clone typed data instead of deserializing it again.
        let mut size = ByteCount::default();
        if serde_json::to_writer(&mut size, value).is_err() {
            return;
        }
        if size.0 > MAX_BYTES {
            if let Ok(mut cache) = memory_cache().lock() {
                cache.remove(&self.key(kind, path));
            }
            return;
        }
        let payload: Arc<dyn Any + Send + Sync> = Arc::new(value.clone());
        let Ok(mut cache) = memory_cache().lock() else {
            return;
        };
        let key = self.key(kind, path);
        let now = Instant::now();
        cache.sweep(now);
        cache.admit(
            key,
            Entry {
                fingerprint: fingerprint.clone(),
                payload,
                estimated_bytes: size.0,
                last_used: now,
            },
            now,
            MAX_BYTES,
            MAX_ENTRIES,
        );
    }

    #[cfg(test)]
    fn get_or_parse<T: Serialize + Clone + Send + Sync + 'static>(
        &self,
        kind: &str,
        path: &Path,
        parse: impl FnOnce() -> T,
    ) -> T {
        self.get_or_try_parse(kind, path, || Ok::<_, std::convert::Infallible>(parse()))
            .unwrap()
    }

    pub(crate) fn get_or_try_parse<T: Serialize + Clone + Send + Sync + 'static, E>(
        &self,
        kind: &str,
        path: &Path,
        parse: impl FnOnce() -> Result<T, E>,
    ) -> Result<T, E> {
        self.get_or_try_parse_when(kind, path, parse, |_| true)
    }

    pub(crate) fn get_or_try_parse_when<T: Serialize + Clone + Send + Sync + 'static, E>(
        &self,
        kind: &str,
        path: &Path,
        parse: impl FnOnce() -> Result<T, E>,
        cacheable: impl FnOnce(&T) -> bool,
    ) -> Result<T, E> {
        let before = Fingerprint::read(path);
        if let Some(value) = before
            .as_ref()
            .and_then(|fingerprint| self.load(kind, path, fingerprint))
        {
            return Ok(value);
        }
        let value = parse()?;
        if let Some(fingerprint) = before.filter(|fingerprint| {
            cacheable(&value) && Some(fingerprint) == Fingerprint::read(path).as_ref()
        }) {
            self.store(kind, path, &fingerprint, &value);
        }
        Ok(value)
    }
}

/// UnifiedMessage intentionally omits these internal fields from snapshot JSON.
/// Retain them explicitly so an in-memory hit preserves turn grouping and pricing.
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct CachedMessage {
    message: UnifiedMessage,
    source_turn_id: Option<String>,
    cache_write_breakdown: Option<CacheWriteBreakdown>,
}

impl From<UnifiedMessage> for CachedMessage {
    fn from(mut message: UnifiedMessage) -> Self {
        // Parsers already bound previews; keep the cache bounded even if another
        // adapter starts supplying a larger string in a future version.
        message.content_preview = message
            .content_preview
            .map(|text| text.chars().take(163).collect());
        message.output_preview = message
            .output_preview
            .map(|text| text.chars().take(163).collect());
        Self {
            source_turn_id: message.source_turn_id.clone(),
            cache_write_breakdown: message.cache_write_breakdown.clone(),
            message,
        }
    }
}

impl From<CachedMessage> for UnifiedMessage {
    fn from(value: CachedMessage) -> Self {
        let mut message = value.message;
        message.source_turn_id = value.source_turn_id;
        message.cache_write_breakdown = value.cache_write_breakdown;
        message
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn unchanged_files_reuse_memory_and_mutations_or_invalid_payloads_reparse() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join("session.jsonl");
        let cache = ParseCache::open(home.path().to_str()).unwrap();
        let calls = AtomicUsize::new(0);
        let parse = || {
            calls.fetch_add(1, Ordering::Relaxed);
            fs::read_to_string(&path).unwrap()
        };
        fs::write(&path, "prefix").unwrap();
        assert_eq!(cache.get_or_parse("test", &path, parse), "prefix");
        assert_eq!(cache.get_or_parse("test", &path, parse), "prefix");
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        fs::write(&path, "update").unwrap();
        assert_eq!(cache.get_or_parse("test", &path, parse), "update");
        cache.store("test", &path, &Fingerprint::read(&path).unwrap(), &123);
        assert_eq!(cache.get_or_parse("test", &path, parse), "update");
        assert_eq!(calls.load(Ordering::Relaxed), 3);
        fs::remove_file(&path).unwrap();
        assert!(Fingerprint::read(&path).is_none());
        assert!(!home.path().join("Library").exists());
    }

    #[test]
    fn accounting_cache_roundtrips_internal_fields_and_bounds_previews() {
        let mut message = UnifiedMessage::new_with_agent(
            "claude",
            "test",
            "provider",
            "session",
            0,
            Default::default(),
            0.0,
            None,
        );
        message.source_turn_id = Some("turn-id".to_string());
        message.cache_write_breakdown = Some(CacheWriteBreakdown {
            five_minute: 3,
            one_hour: 5,
        });
        message.content_preview = Some("a".repeat(160));
        message.output_preview = Some("b".repeat(10_000));
        let payload = serde_json::to_vec(&CachedMessage::from(message.clone())).unwrap();
        let cached: CachedMessage = serde_json::from_slice(&payload).unwrap();
        let restored = UnifiedMessage::from(cached);
        assert_eq!(restored.source_turn_id, message.source_turn_id);
        assert_eq!(
            restored.cache_write_breakdown,
            message.cache_write_breakdown
        );
        assert_eq!(restored.content_preview, message.content_preview);
        assert_eq!(
            restored.output_preview.as_ref().unwrap().chars().count(),
            163
        );
        assert!(payload.len() < 2_000);
    }

    #[test]
    fn transient_read_errors_are_retried_without_requiring_a_file_change() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join("session.jsonl");
        fs::write(&path, "unchanged").unwrap();
        let cache = ParseCache::open(home.path().to_str()).unwrap();
        let failed =
            cache.get_or_try_parse::<String, _>("test", &path, || Err("temporary read error"));
        assert!(failed.is_err());
        let prefix = cache
            .get_or_try_parse_when(
                "test",
                &path,
                || Ok::<_, &str>("partial".to_string()),
                |_| false,
            )
            .unwrap();
        assert_eq!(prefix, "partial");
        let retried = cache
            .get_or_try_parse("test", &path, || Ok::<_, &str>("complete".to_string()))
            .unwrap();
        assert_eq!(retried, "complete");
        assert_eq!(
            cache
                .get_or_try_parse("test", &path, || Err::<String, _>("cache should be reused"))
                .unwrap(),
            "complete"
        );
    }

    #[test]
    fn memory_policy_evicts_oldest_by_capacity_and_expires_idle_entries() {
        let home = tempfile::tempdir().unwrap();
        let cache = ParseCache::open(home.path().to_str()).unwrap();
        let now = Instant::now();
        let mut bounded = MemoryCache::default();
        let entry = |instant, bytes| Entry {
            fingerprint: Fingerprint("unchanged".to_string()),
            payload: Arc::new(vec![0_u8; bytes]),
            estimated_bytes: bytes,
            last_used: instant,
        };
        // Four sequential files just exceed a three-file budget. Once warm,
        // retain three hits each round rather than cycling through all misses.
        for round in 0..4 {
            let current = now + Duration::from_secs(round);
            let mut hits = 0;
            for index in 0..4 {
                let key = cache.key("test", Path::new(&index.to_string()));
                if let Some(hit) = bounded.entries.get_mut(&key) {
                    hit.last_used = current;
                    hits += 1;
                } else {
                    bounded.admit(key, entry(current, 3), current, 9, 3);
                }
            }
            assert_eq!(hits, if round == 0 { 0 } else { 3 });
            assert_eq!((bounded.bytes, bounded.entries.len()), (9, 3));
        }
        let current = now + Duration::from_secs(5);
        // Existing active files may replace their own entry even when the hot
        // set fills the budget; a payload larger than the budget is skipped.
        assert!(bounded.admit(
            cache.key("test", Path::new("0")),
            entry(current, 6),
            current,
            9,
            3
        ));
        assert_eq!(bounded.bytes, 9);
        assert!(!bounded.admit(
            cache.key("test", Path::new("oversized")),
            entry(current, 10),
            current,
            9,
            3
        ));
        let aged = current + ADMISSION_PROTECTION;
        assert!(bounded.admit(
            cache.key("test", Path::new("new-file")),
            entry(aged, 3),
            aged,
            9,
            3
        ));

        let path = home.path().join("session.jsonl");
        fs::write(&path, "sentinel").unwrap();
        let fingerprint = Fingerprint::read(&path).unwrap();
        cache.store(
            "test",
            &path,
            &fingerprint,
            &"private preview sentinel".to_string(),
        );
        assert_eq!(
            cache.load::<String>("test", &path, &fingerprint).as_deref(),
            Some("private preview sentinel")
        );
        memory_cache()
            .lock()
            .unwrap()
            .entries
            .get_mut(&cache.key("test", &path))
            .unwrap()
            .last_used = Instant::now() - TTL - Duration::from_secs(1);
        assert!(cache.load::<String>("test", &path, &fingerprint).is_none());
        assert!(!home.path().join("Library").exists());
    }
}
