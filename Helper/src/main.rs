use std::env;
use std::error::Error;
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::Arc;

use chrono::{Days, NaiveDate, Utc};
use tokenbar_helper::claude::{
    extract_request_detail as extract_claude_request_detail, parse_local_claude_messages,
    LocalParseOptions as ClaudeParseOptions,
};
use tokenbar_helper::antigravity::{
    extract_request_detail as extract_antigravity_request_detail,
    load_antigravity_session_titles, parse_local_antigravity_messages,
    LocalParseOptions as AntigravityParseOptions,
};
use tokenbar_helper::codex::{parse_local_codex_messages, LocalParseOptions};
use tokenbar_helper::custom_pricing::{quote_rates, CustomPricing, PriceQuote};
use tokenbar_helper::grok::{
    extract_request_detail as extract_grok_request_detail, load_grok_session_titles,
    parse_local_grok_messages, LocalParseOptions as GrokParseOptions,
};
use serde::Deserialize;
use tokenbar_helper::memory::{load_usage_snapshot, run_receiver, MemoryReceiverConfig, DEFAULT_PORT};
use tokenbar_helper::pricing::{
    AnthropicPricing, CodexPricing, FastPricingBasis, GooglePricing,
};
use tokenbar_helper::usage::ServiceTier;
use tokenbar_helper::{
    build_snapshot_with_platform_resets, extract_request_detail as extract_codex_request_detail,
    load_claude_session_titles, load_codex_session_titles, normalize_codex_reasoning_usage,
    StatisticsTimeZone,
};

const DEFAULT_DAYS: usize = 30;
use tokenbar_helper::zcode::{parse_local_zcode_messages, load_zcode_session_titles, extract_request_detail as extract_zcode_request_detail, LocalParseOptions as ZCodeParseOptions};

const USAGE: &str = "usage: tokenbar-helper [--days COUNT] [--end-date YYYY-MM-DD] [--home-dir PATH] [--statistics-timezone utc|local] [--weekly-reset-ms MS] [--claude-weekly-reset-ms MS] [--grok-weekly-reset-ms MS] [--antigravity-weekly-reset-ms MS] [--openai-pricing-markdown PATH] [--anthropic-pricing-markdown PATH] [--openrouter-pricing-json PATH] [--custom-pricing-json PATH] [--memory-database PATH] [--offline-pricing]\n       tokenbar-helper price-quote --platform codex|claude|grok|antigravity|zcode --model ID --service-tier standard|fast [--home-dir PATH] [--openai-pricing-markdown PATH] [--anthropic-pricing-markdown PATH] [--openrouter-pricing-json PATH] [--offline-pricing]\n       tokenbar-helper request-detail [--platform codex|claude|grok|antigravity|zcode] --session-path PATH --start-ms MS --end-ms MS\n       tokenbar-helper memory-receiver --database PATH [--status-file PATH] [--port PORT] [--parent-pid PID]";

#[derive(Debug, Clone, PartialEq, Eq)]
struct SnapshotConfig {
    days: usize,
    end_date: Option<NaiveDate>,
    home_dir: Option<PathBuf>,
    statistics_time_zone: StatisticsTimeZone,
    weekly_reset_ms: Option<i64>,
    claude_weekly_reset_ms: Option<i64>,
    grok_weekly_reset_ms: Option<i64>,
    antigravity_weekly_reset_ms: Option<i64>,
    openai_pricing_markdown: Option<PathBuf>,
    anthropic_pricing_markdown: Option<PathBuf>,
    openrouter_pricing_json: Option<PathBuf>,
    custom_pricing_json: Option<PathBuf>,
    memory_database: Option<PathBuf>,
    offline_pricing: bool,
}

impl Default for SnapshotConfig {
    fn default() -> Self {
        Self {
            days: DEFAULT_DAYS,
            end_date: None,
            home_dir: None,
            statistics_time_zone: StatisticsTimeZone::default(),
            weekly_reset_ms: None,
            claude_weekly_reset_ms: None,
            grok_weekly_reset_ms: None,
            antigravity_weekly_reset_ms: None,
            openai_pricing_markdown: None,
            anthropic_pricing_markdown: None,
            openrouter_pricing_json: None,
            custom_pricing_json: None,
            memory_database: None,
            offline_pricing: false,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct RequestDetailConfig {
    platform: String,
    session_path: PathBuf,
    start_ms: i64,
    end_ms: i64,
}

#[derive(Debug, PartialEq, Eq)]
struct PriceQuoteConfig {
    platform: String,
    model_id: String,
    service_tier: ServiceTier,
    pricing: SnapshotConfig,
}

#[derive(Debug, PartialEq, Eq)]
enum Command {
    Snapshot(SnapshotConfig),
    PriceQuote(PriceQuoteConfig),
    RequestDetail(RequestDetailConfig),
    MemoryReceiver(MemoryReceiverConfig),
}

#[derive(Debug, Deserialize)]
struct CodexAuthConfig {
    auth_mode: Option<String>,
}

fn main() -> Result<(), Box<dyn Error>> {
    match parse_args(env::args_os().skip(1))? {
        Command::Snapshot(config) => run_snapshot(config),
        Command::PriceQuote(config) => write_json(&automatic_price_quote(&config)),
        Command::RequestDetail(config) => {
            let detail = match config.platform.as_str() {
                "codex" => {
                    extract_codex_request_detail(
                        &config.session_path,
                        config.start_ms,
                        config.end_ms,
                    )
                }
                "claude" => {
                    extract_claude_request_detail(
                        &config.session_path,
                        config.start_ms,
                        config.end_ms,
                    )
                }
                "zcode" => extract_zcode_request_detail(&config.session_path, config.start_ms, config.end_ms),
                "grok" => extract_grok_request_detail(
                    &config.session_path,
                    config.start_ms,
                    config.end_ms,
                ),
                "antigravity" => extract_antigravity_request_detail(
                    &config.session_path,
                    config.start_ms,
                    config.end_ms,
                ),
                platform => Err(format!("unsupported request-detail platform: {platform}")),
            }
            .map_err(io::Error::other)?;
            write_json(&detail)
        }
        Command::MemoryReceiver(config) => run_receiver(config).map_err(io::Error::other).map_err(Into::into),
    }
}

fn run_snapshot(config: SnapshotConfig) -> Result<(), Box<dyn Error>> {
    let custom_pricing = config
        .custom_pricing_json
        .as_deref()
        .map(CustomPricing::from_file)
        .transpose()
        .map_err(io::Error::other)?;
    let generated_at_ms = Utc::now().timestamp_millis();
    let current_day = config
        .statistics_time_zone
        .date_at_ms(generated_at_ms)
        .ok_or("the current time is outside the supported range")?;
    let today = config.end_date.unwrap_or(current_day);
    if today > current_day {
        return Err("end date must not be in the future".into());
    }
    let first_day = today
        .checked_sub_days(Days::new((config.days - 1) as u64))
        .ok_or("day range is too large")?;
    let scan_first_day = [
        config.weekly_reset_ms,
        config.claude_weekly_reset_ms,
        config.grok_weekly_reset_ms,
        config.antigravity_weekly_reset_ms,
    ]
        .into_iter()
        .flatten()
        .filter_map(|timestamp| config.statistics_time_zone.date_at_ms(timestamp))
        .fold(first_day, |earliest, reset_day| earliest.min(reset_day));
    // Parsers perform an inexpensive date prefilter before returning timestamped
    // rows. Scan one boundary day on either side, then recompute every row's date
    // below so UTC and local mode stay correct even on Windows where TZ is ignored.
    let parse_first_day = scan_first_day
        .checked_sub_days(Days::new(1))
        .unwrap_or(scan_first_day);
    let parse_last_day = today.checked_add_days(Days::new(1)).unwrap_or(today);
    let session_index_path = codex_session_index_path(&config);
    let home_dir = config
        .home_dir
        .as_ref()
        .map(|path| {
            path.to_str()
                .map(str::to_string)
                .ok_or("home directory is not valid UTF-8")
        })
        .transpose()?;
    let use_env_roots = home_dir.is_none();

    let catalog_load = load_openrouter_pricing(&config);
    let catalog = catalog_load.catalog.map(Arc::new);
    let fast_pricing_basis = codex_fast_pricing_basis(&config);
    let pricing = config
        .openai_pricing_markdown
        .as_deref()
        .and_then(|path| {
            CodexPricing::from_official_markdown_file(path, fast_pricing_basis).ok()
        })
        .unwrap_or_else(|| CodexPricing::with_fast_pricing(fast_pricing_basis))
        .with_openrouter_catalog(catalog.clone());
    let mut codex_messages = parse_local_codex_messages(
        LocalParseOptions {
            home_dir: home_dir.clone(),
            use_env_roots,
            since: Some(parse_first_day.format("%Y-%m-%d").to_string()),
            until: Some(parse_last_day.format("%Y-%m-%d").to_string()),
        },
        &pricing,
    )
    .map_err(io::Error::other)?;
    normalize_codex_reasoning_usage(&mut codex_messages, |message| {
        pricing.calculate_token_costs_with_service_tier(
            &message.model_id,
            Some(&message.provider_id),
            &message.tokens,
            message.service_tier,
        )
    });
    let mut session_titles = session_index_path
        .as_deref()
        .map(|path| load_codex_session_titles(&codex_messages, path))
        .unwrap_or_default();
    let anthropic_pricing = config
        .anthropic_pricing_markdown
        .as_deref()
        .and_then(|path| AnthropicPricing::from_official_markdown_file(path, today).ok())
        .unwrap_or_else(|| AnthropicPricing::bundled_for_date(today))
        .with_openrouter_catalog(catalog);
    let claude_messages = parse_local_claude_messages(
        ClaudeParseOptions {
            home_dir: home_dir.clone(),
            use_env_roots,
            since: Some(parse_first_day.format("%Y-%m-%d").to_string()),
            until: Some(parse_last_day.format("%Y-%m-%d").to_string()),
        },
        &anthropic_pricing,
    )
    .map_err(io::Error::other)?;
    session_titles.extend(load_claude_session_titles(&claude_messages));
    let zcode_options=ZCodeParseOptions {home_dir:home_dir.clone(),use_env_roots,since:Some(parse_first_day.format("%Y-%m-%d").to_string()),until:Some(parse_last_day.format("%Y-%m-%d").to_string())};
    let mut zcode_messages=parse_local_zcode_messages(zcode_options.clone()).map_err(io::Error::other)?;
    session_titles.extend(load_zcode_session_titles(&zcode_options));
    let antigravity_home_dir = home_dir.clone();
    let grok_messages = parse_local_grok_messages(GrokParseOptions {
        home_dir,
        use_env_roots,
        since: Some(parse_first_day.format("%Y-%m-%d").to_string()),
        until: Some(parse_last_day.format("%Y-%m-%d").to_string()),
    })
    .map_err(io::Error::other)?;
    session_titles.extend(load_grok_session_titles(&grok_messages));
    let antigravity_options = AntigravityParseOptions {
        home_dir: antigravity_home_dir,
        use_env_roots,
        since: Some(parse_first_day.format("%Y-%m-%d").to_string()),
        until: Some(parse_last_day.format("%Y-%m-%d").to_string()),
    };
    let google_pricing = config
        .openrouter_pricing_json
        .as_deref()
        .and_then(|path| GooglePricing::from_openrouter_catalog_file(path, today).ok())
        .unwrap_or_else(|| GooglePricing::bundled_for_date(today));
    for message in &mut zcode_messages {
        if let Some(costs)=zcode_token_costs(&message.model_id,&message.tokens,&pricing,&anthropic_pricing,&google_pricing,message.service_tier) {
            message.cost=costs.total();message.token_costs=Some(costs);message.cost_source=tokenbar_helper::usage::CostSource::Estimated;
        }
    }
    let antigravity_messages = parse_local_antigravity_messages(
        antigravity_options.clone(),
        &anthropic_pricing,
        &google_pricing,
    )
    .map_err(io::Error::other)?;
    session_titles.extend(load_antigravity_session_titles(&antigravity_options));
    let mut messages = codex_messages;
    messages.extend(claude_messages);
    messages.extend(grok_messages);
    messages.extend(antigravity_messages);
    messages.extend(zcode_messages);
    if let Some(pricing) = custom_pricing {
        pricing.apply(&mut messages);
    }
    config
        .statistics_time_zone
        .normalize_message_dates(&mut messages);

    let timezone = config.statistics_time_zone.snapshot_name();
    let mut weekly_resets = std::collections::HashMap::new();
    if let Some(timestamp) = config.weekly_reset_ms {
        weekly_resets.insert("codex".to_string(), timestamp);
    }
    if let Some(timestamp) = config.claude_weekly_reset_ms {
        weekly_resets.insert("claude".to_string(), timestamp);
    }
    if let Some(timestamp) = config.grok_weekly_reset_ms {
        weekly_resets.insert("grok".to_string(), timestamp);
    }
    if let Some(timestamp) = config.antigravity_weekly_reset_ms {
        weekly_resets.insert("antigravity".to_string(), timestamp);
    }
    let mut snapshot = build_snapshot_with_platform_resets(
        messages,
        today,
        generated_at_ms,
        timezone,
        config.days,
        &session_titles,
        &weekly_resets,
    )
    .map_err(io::Error::other)?;
    if let Some(database_path) = config.memory_database.as_deref() {
        snapshot.memory_usage = load_usage_snapshot(
            database_path,
            today,
            generated_at_ms,
            config.days,
        )
        .map_err(io::Error::other)?;
    }

    snapshot.pricing_catalog = Some(catalog_load.status);
    write_json(&snapshot)
}

fn automatic_price_quote(config: &PriceQuoteConfig) -> PriceQuote {
    // Quotes read the existing cache, even when --offline-pricing was omitted.
    // Refresh/download behavior remains confined to the snapshot command.
    let today = Utc::now().date_naive();
    let readonly_pricing = SnapshotConfig {
        offline_pricing: true,
        ..config.pricing.clone()
    };
    let catalog = load_openrouter_pricing(&readonly_pricing)
        .catalog
        .map(Arc::new);
    let basis = codex_fast_pricing_basis(&config.pricing);
    let codex = config
        .pricing
        .openai_pricing_markdown
        .as_deref()
        .and_then(|path| CodexPricing::from_official_markdown_file(path, basis).ok())
        .unwrap_or_else(|| CodexPricing::with_fast_pricing(basis))
        .with_openrouter_catalog(catalog.clone());
    let anthropic = config
        .pricing
        .anthropic_pricing_markdown
        .as_deref()
        .and_then(|path| AnthropicPricing::from_official_markdown_file(path, today).ok())
        .unwrap_or_else(|| AnthropicPricing::bundled_for_date(today))
        .with_openrouter_catalog(catalog);
    let google = config
        .pricing
        .openrouter_pricing_json
        .as_deref()
        .and_then(|path| GooglePricing::from_openrouter_catalog_file(path, today).ok())
        .unwrap_or_else(|| GooglePricing::bundled_for_date(today));
    let rates = quote_rates(|tokens| match config.platform.as_str() {
        "codex" => codex.calculate_token_costs_with_service_tier(
            &config.model_id,
            None,
            tokens,
            config.service_tier,
        ),
        "claude" => anthropic.calculate_token_costs(&config.model_id, tokens),
        "zcode" => zcode_token_costs(&config.model_id,tokens,&codex,&anthropic,&google,config.service_tier),
        "antigravity" => {
            let model = config.model_id.trim().to_ascii_lowercase();
            if model.starts_with("claude") || model.starts_with("anthropic/claude") {
                anthropic.calculate_token_costs(&config.model_id, tokens)
            } else {
                google.calculate_token_costs(&config.model_id, tokens)
            }
        }
        _ => None,
    });
    PriceQuote {
        platform: config.platform.clone(),
        model_id: config.model_id.clone(),
        service_tier: config.service_tier,
        rates,
    }
}

fn zcode_token_costs(model_id:&str,tokens:&tokenbar_helper::usage::TokenBreakdown,codex:&CodexPricing,anthropic:&AnthropicPricing,google:&GooglePricing,tier:ServiceTier)->Option<tokenbar_helper::usage::TokenCostBreakdown>{
    let model=model_id.trim();
    let model=if let Some((route,id))=model.split_once('/') {if matches!(route.to_ascii_lowercase().as_str(),"codex"|"antigravity"|"workbuddy"|"openai"|"anthropic"|"google"){id}else{return None}}else{model};
    let normalized=model.to_ascii_lowercase();
    if normalized.starts_with("claude"){anthropic.calculate_token_costs(model,tokens)}else if normalized.starts_with("gpt-"){codex.calculate_token_costs_with_service_tier(model,None,tokens,tier)}else if normalized.starts_with("gemini-"){google.calculate_token_costs(model,tokens)}else{None}
}

fn load_openrouter_pricing(config: &SnapshotConfig) -> tokenbar_helper::openrouter::CatalogLoad {
    use tokenbar_helper::openrouter::{self, Catalog, CatalogLoad, CatalogStatus};
    if let Some(path) = &config.openrouter_pricing_json {
        // A supplied catalog may contain only Gemini models or be stale.
        // Keep its fallback behavior without triggering a second download.
        let catalog = std::fs::metadata(path).ok()
            .filter(|meta| meta.len() <= 16 * 1024 * 1024)
            .and_then(|_| std::fs::read(path).ok())
            .and_then(|bytes| Catalog::from_json(&bytes).ok());
        let status = CatalogStatus {
            source: if catalog.is_some() { "openrouter" } else { "bundled" }.into(),
            updated_at_ms: None,
            model_count: catalog.as_ref().map_or(0, Catalog::model_count),
            status: "file".into(),
        };
        return CatalogLoad { catalog, status };
    }
    if let Some(dir) = openrouter::default_cache_dir() {
        return openrouter::refresh(&dir, config.offline_pricing);
    }
    CatalogLoad { catalog: None, status: CatalogStatus {
        source: "bundled".into(), updated_at_ms: None, model_count: 0,
        status: "cache-unavailable".into(),
    }}
}

fn codex_session_index_path(config: &SnapshotConfig) -> Option<PathBuf> {
    codex_home_path(config).map(|path| path.join("session_index.jsonl"))
}

fn codex_home_path(config: &SnapshotConfig) -> Option<PathBuf> {
    if let Some(home_dir) = config.home_dir.as_ref() {
        return Some(home_dir.join(".codex"));
    }
    if let Some(codex_home) = env::var_os("CODEX_HOME") {
        return Some(PathBuf::from(codex_home));
    }
    env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .map(|home| home.join(".codex"))
}

fn codex_fast_pricing_basis(config: &SnapshotConfig) -> FastPricingBasis {
    codex_home_path(config)
        .and_then(|path| File::open(path.join("auth.json")).ok())
        .and_then(|file| serde_json::from_reader::<_, CodexAuthConfig>(file).ok())
        .and_then(|auth| auth.auth_mode)
        .and_then(|mode| fast_pricing_basis_for_auth_mode(&mode))
        .unwrap_or_default()
}

fn fast_pricing_basis_for_auth_mode(auth_mode: &str) -> Option<FastPricingBasis> {
    match auth_mode.trim().to_ascii_lowercase().as_str() {
        "chatgpt" => Some(FastPricingBasis::ChatGptSubscription),
        "api" | "api-key" | "api_key" | "apikey" => Some(FastPricingBasis::ApiPriority),
        _ => None,
    }
}

fn write_json(value: &impl serde::Serialize) -> Result<(), Box<dyn Error>> {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    serde_json::to_writer(&mut output, value)?;
    writeln!(output)?;
    Ok(())
}

fn parse_args(args: impl IntoIterator<Item = OsString>) -> Result<Command, String> {
    let mut args = args.into_iter();
    let Some(first) = args.next() else {
        return Ok(Command::Snapshot(SnapshotConfig::default()));
    };

    if first.to_str() == Some("request-detail") {
        return parse_request_detail_args(args).map(Command::RequestDetail);
    }
    if first.to_str() == Some("price-quote") {
        return parse_price_quote_args(args).map(Command::PriceQuote);
    }
    if first.to_str() == Some("memory-receiver") {
        return parse_memory_receiver_args(args).map(Command::MemoryReceiver);
    }

    parse_snapshot_args(std::iter::once(first).chain(args)).map(Command::Snapshot)
}

fn parse_snapshot_args(args: impl IntoIterator<Item = OsString>) -> Result<SnapshotConfig, String> {
    let mut config = SnapshotConfig::default();
    let mut args = args.into_iter();

    while let Some(argument) = args.next() {
        match argument.to_str() {
            Some("--offline-pricing") => config.offline_pricing = true,
            Some("--days") => {
                let value = args.next().ok_or("--days requires a value")?;
                let value = value.to_str().ok_or("--days must be valid UTF-8")?;
                config.days = value
                    .parse::<usize>()
                    .map_err(|_| "--days must be a positive integer")?;
                if config.days == 0 {
                    return Err("--days must be a positive integer".to_string());
                }
            }
            Some("--end-date") => {
                let value = args.next().ok_or("--end-date requires a value")?;
                let value = value.to_str().ok_or("--end-date must be valid UTF-8")?;
                config.end_date = Some(
                    NaiveDate::parse_from_str(value, "%Y-%m-%d")
                        .map_err(|_| "--end-date must use YYYY-MM-DD")?,
                );
            }
            Some("--home-dir") => {
                let value = args.next().ok_or("--home-dir requires a path")?;
                config.home_dir = Some(PathBuf::from(value));
            }
            Some("--statistics-timezone") => {
                let value = args
                    .next()
                    .ok_or("--statistics-timezone requires a value")?;
                let value = value
                    .to_str()
                    .ok_or("--statistics-timezone must be valid UTF-8")?;
                config.statistics_time_zone = value
                    .parse()
                    .map_err(|_| "--statistics-timezone must be utc or local".to_string())?;
            }
            Some("--weekly-reset-ms") => {
                let value = args.next().ok_or("--weekly-reset-ms requires a value")?;
                let value = value
                    .to_str()
                    .ok_or("--weekly-reset-ms must be valid UTF-8")?;
                config.weekly_reset_ms = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| "--weekly-reset-ms must be an integer")?,
                );
            }
            Some("--claude-weekly-reset-ms") => {
                let value = args
                    .next()
                    .ok_or("--claude-weekly-reset-ms requires a value")?;
                let value = value
                    .to_str()
                    .ok_or("--claude-weekly-reset-ms must be valid UTF-8")?;
                config.claude_weekly_reset_ms = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| "--claude-weekly-reset-ms must be an integer")?,
                );
            }
            Some("--grok-weekly-reset-ms") => {
                let value = args
                    .next()
                    .ok_or("--grok-weekly-reset-ms requires a value")?;
                let value = value
                    .to_str()
                    .ok_or("--grok-weekly-reset-ms must be valid UTF-8")?;
                config.grok_weekly_reset_ms = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| "--grok-weekly-reset-ms must be an integer")?,
                );
            }
            Some("--openrouter-pricing-json") => {
                let value = args
                    .next()
                    .ok_or("--openrouter-pricing-json requires a path")?;
                config.openrouter_pricing_json = Some(PathBuf::from(value));
            }
            Some("--custom-pricing-json") => {
                let value = args.next().ok_or("--custom-pricing-json requires a path")?;
                config.custom_pricing_json = Some(PathBuf::from(value));
            }
            Some("--antigravity-weekly-reset-ms") => {
                let value = args
                    .next()
                    .ok_or("--antigravity-weekly-reset-ms requires a value")?;
                let value = value
                    .to_str()
                    .ok_or("--antigravity-weekly-reset-ms must be valid UTF-8")?;
                config.antigravity_weekly_reset_ms = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| "--antigravity-weekly-reset-ms must be an integer")?,
                );
            }
            Some("--memory-database") => {
                let value = args.next().ok_or("--memory-database requires a path")?;
                config.memory_database = Some(PathBuf::from(value));
            }
            Some("--openai-pricing-markdown") => {
                let value = args
                    .next()
                    .ok_or("--openai-pricing-markdown requires a path")?;
                config.openai_pricing_markdown = Some(PathBuf::from(value));
            }
            Some("--anthropic-pricing-markdown") => {
                let value = args
                    .next()
                    .ok_or("--anthropic-pricing-markdown requires a path")?;
                config.anthropic_pricing_markdown = Some(PathBuf::from(value));
            }
            Some("--help" | "-h") => {
                return Err(USAGE.to_string());
            }
            Some(value) => return Err(format!("unknown argument: {value}")),
            None => return Err("arguments must be valid UTF-8".to_string()),
        }
    }

    Ok(config)
}

fn parse_price_quote_args(
    args: impl IntoIterator<Item = OsString>,
) -> Result<PriceQuoteConfig, String> {
    let mut platform = None;
    let mut model_id = None;
    let mut service_tier = None;
    let mut pricing = SnapshotConfig {
        offline_pricing: true,
        ..Default::default()
    };
    let mut args = args.into_iter();
    while let Some(argument) = args.next() {
        match argument.to_str() {
            Some("--platform") => {
                let value = args.next().ok_or("--platform requires a value")?;
                let value = value.to_str().ok_or("--platform must be valid UTF-8")?;
                if !matches!(value, "codex" | "claude" | "grok" | "antigravity" | "zcode") {
                    return Err("--platform must be codex, claude, grok, antigravity, or zcode".into());
                }
                platform = Some(value.to_string());
            }
            Some("--model") => {
                let value = args.next().ok_or("--model requires a value")?;
                let value = value.to_str().ok_or("--model must be valid UTF-8")?;
                if value.trim().is_empty() {
                    return Err("--model requires a non-empty model ID".into());
                }
                model_id = Some(value.to_string());
            }
            Some("--service-tier") => {
                let value = args.next().ok_or("--service-tier requires a value")?;
                service_tier = Some(match value.to_str() {
                    Some("standard") => ServiceTier::Standard,
                    Some("fast") => ServiceTier::Fast,
                    _ => return Err("--service-tier must be standard or fast".into()),
                });
            }
            Some(
                "--home-dir"
                | "--openai-pricing-markdown"
                | "--anthropic-pricing-markdown"
                | "--openrouter-pricing-json",
            ) => {
                let option = argument.to_str().unwrap();
                let value = args
                    .next()
                    .ok_or_else(|| format!("{option} requires a path"))?;
                let path = Some(PathBuf::from(value));
                match option {
                    "--home-dir" => pricing.home_dir = path,
                    "--openai-pricing-markdown" => pricing.openai_pricing_markdown = path,
                    "--anthropic-pricing-markdown" => pricing.anthropic_pricing_markdown = path,
                    _ => pricing.openrouter_pricing_json = path,
                }
            }
            Some("--offline-pricing") => pricing.offline_pricing = true,
            Some("--help" | "-h") => return Err(USAGE.to_string()),
            Some(value) => return Err(format!("unknown price-quote argument: {value}")),
            None => return Err("arguments must be valid UTF-8".into()),
        }
    }
    Ok(PriceQuoteConfig {
        platform: platform.ok_or("price-quote requires --platform")?,
        model_id: model_id.ok_or("price-quote requires --model")?,
        service_tier: service_tier.ok_or("price-quote requires --service-tier")?,
        pricing,
    })
}

fn parse_memory_receiver_args(
    args: impl IntoIterator<Item = OsString>,
) -> Result<MemoryReceiverConfig, String> {
    let mut database_path = None;
    let mut status_path = None;
    let mut port = DEFAULT_PORT;
    let mut parent_pid = None;
    let mut args = args.into_iter();
    while let Some(argument) = args.next() {
        match argument.to_str() {
            Some("--database") => {
                database_path = Some(PathBuf::from(
                    args.next().ok_or("--database requires a path")?,
                ));
            }
            Some("--status-file") => {
                status_path = Some(PathBuf::from(
                    args.next().ok_or("--status-file requires a path")?,
                ));
            }
            Some("--port") => {
                let value = args.next().ok_or("--port requires a value")?;
                let value = value.to_str().ok_or("--port must be valid UTF-8")?;
                port = value
                    .parse::<u16>()
                    .map_err(|_| "--port must be between 1 and 65535")?;
                if port == 0 {
                    return Err("--port must be between 1 and 65535".to_string());
                }
            }
            Some("--parent-pid") => {
                let value = args.next().ok_or("--parent-pid requires a value")?;
                let value = value
                    .to_str()
                    .ok_or("--parent-pid must be valid UTF-8")?;
                parent_pid = Some(
                    value
                        .parse::<u32>()
                        .map_err(|_| "--parent-pid must be a positive integer")?,
                );
                if parent_pid == Some(0) {
                    return Err("--parent-pid must be a positive integer".to_string());
                }
            }
            Some("--help" | "-h") => return Err(USAGE.to_string()),
            Some(value) => return Err(format!("unknown memory-receiver argument: {value}")),
            None => return Err("arguments must be valid UTF-8".to_string()),
        }
    }
    Ok(MemoryReceiverConfig {
        database_path: database_path.ok_or("memory-receiver requires --database")?,
        status_path,
        port,
        parent_pid,
    })
}

fn parse_request_detail_args(
    args: impl IntoIterator<Item = OsString>,
) -> Result<RequestDetailConfig, String> {
    let mut platform = "codex".to_string();
    let mut session_path = None;
    let mut start_ms = None;
    let mut end_ms = None;
    let mut args = args.into_iter();

    while let Some(argument) = args.next() {
        match argument.to_str() {
            Some("--platform") => {
                let value = args.next().ok_or("--platform requires a value")?;
                let value = value.to_str().ok_or("--platform must be valid UTF-8")?;
                if !matches!(value, "codex" | "claude" | "grok" | "antigravity" | "zcode") {
                    return Err(
                        "--platform must be codex, claude, grok, antigravity, or zcode".to_string()
                    );
                }
                platform = value.to_string();
            }
            Some("--session-path") => {
                let value = args.next().ok_or("--session-path requires a path")?;
                session_path = Some(PathBuf::from(value));
            }
            Some("--start-ms") => {
                let value = args.next().ok_or("--start-ms requires a value")?;
                let value = value.to_str().ok_or("--start-ms must be valid UTF-8")?;
                start_ms = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| "--start-ms must be an integer")?,
                );
            }
            Some("--end-ms") => {
                let value = args.next().ok_or("--end-ms requires a value")?;
                let value = value.to_str().ok_or("--end-ms must be valid UTF-8")?;
                end_ms = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| "--end-ms must be an integer")?,
                );
            }
            Some("--help" | "-h") => return Err(USAGE.to_string()),
            Some(value) => return Err(format!("unknown request-detail argument: {value}")),
            None => return Err("arguments must be valid UTF-8".to_string()),
        }
    }

    let config = RequestDetailConfig {
        platform,
        session_path: session_path.ok_or("request-detail requires --session-path")?,
        start_ms: start_ms.ok_or("request-detail requires --start-ms")?,
        end_ms: end_ms.ok_or("request-detail requires --end-ms")?,
    };
    if config.start_ms > config.end_ms {
        return Err("request start must not be after request end".to_string());
    }
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zcode_routed_prices_preserve_unknown_models() {
        let codex=CodexPricing::bundled();let today=chrono::NaiveDate::from_ymd_opt(2026,10,18).unwrap();let anthropic=AnthropicPricing::bundled_for_date(today);let google=GooglePricing::bundled_for_date(today);let tokens=tokenbar_helper::usage::TokenBreakdown{input:1000,..Default::default()};
        assert_eq!(zcode_token_costs("codex/gpt-5.4-mini",&tokens,&codex,&anthropic,&google,ServiceTier::Standard),zcode_token_costs("gpt-5.4-mini",&tokens,&codex,&anthropic,&google,ServiceTier::Standard));
        assert!(zcode_token_costs("GLM-5.3-Flash",&tokens,&codex,&anthropic,&google,ServiceTier::Standard).is_none());
        assert!(parse_price_quote_args([OsString::from("--platform"),OsString::from("zcode"),OsString::from("--model"),OsString::from("GLM-5.3-Flash"),OsString::from("--service-tier"),OsString::from("standard")].into_iter()).is_ok());
    }

    #[test]
    fn zero_arguments_use_the_thirty_day_default() {
        assert_eq!(
            parse_args(Vec::<OsString>::new()).unwrap(),
            Command::Snapshot(SnapshotConfig::default())
        );
    }

    #[test]
    fn request_detail_requires_all_arguments_and_an_ordered_range() {
        let missing = parse_args([
            OsString::from("request-detail"),
            OsString::from("--session-path"),
            OsString::from("/tmp/session.jsonl"),
        ])
        .unwrap_err();
        assert_eq!(missing, "request-detail requires --start-ms");

        let reversed = parse_args([
            OsString::from("request-detail"),
            OsString::from("--session-path"),
            OsString::from("/tmp/session.jsonl"),
            OsString::from("--start-ms"),
            OsString::from("2"),
            OsString::from("--end-ms"),
            OsString::from("1"),
        ])
        .unwrap_err();
        assert_eq!(reversed, "request start must not be after request end");
    }

    #[test]
    fn rejects_incomplete_or_invalid_quote_arguments() {
        for args in [
            vec![],
            vec!["--platform", "codex"],
            vec!["--platform", "codex", "--model", "gpt-5.6"],
            vec![
                "--platform",
                "invalid",
                "--model",
                "gpt-5.6",
                "--service-tier",
                "standard",
            ],
            vec![
                "--platform",
                "codex",
                "--model",
                " ",
                "--service-tier",
                "standard",
            ],
            vec![
                "--platform",
                "codex",
                "--model",
                "gpt-5.6",
                "--service-tier",
                "any",
            ],
            vec![
                "--platform",
                "codex",
                "--model",
                "gpt-5.6",
                "--service-tier",
                "standard",
                "--custom-pricing-json",
                "prices.json",
            ],
            vec![
                "--platform",
                "codex",
                "--model",
                "gpt-5.6",
                "--service-tier",
                "standard",
                "--home-dir",
            ],
        ] {
            assert!(parse_args(
                std::iter::once(OsString::from("price-quote"))
                    .chain(args.into_iter().map(OsString::from))
            )
            .is_err());
        }
    }
}
