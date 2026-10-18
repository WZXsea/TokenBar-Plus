//! Exact local price overrides applied after parser token normalization.
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::usage::{CostSource, ServiceTier, TokenBreakdown, TokenCostBreakdown, UnifiedMessage};

const MAX_FILE_BYTES: usize = 1024 * 1024;
const PER_MILLION: f64 = 1_000_000.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize)]
#[serde(rename_all = "lowercase")]
enum OverrideTier {
    Any,
    Standard,
    Fast,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PriceOverride {
    id: String,
    platform: String,
    #[serde(rename = "modelID")]
    model_id: String,
    #[serde(default)]
    service_tier: Option<OverrideTier>,
    input_per_million: f64,
    cached_input_per_million: f64,
    cache_write_per_million: f64,
    output_per_million: f64,
    #[serde(default)]
    enabled: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PricingFile {
    schema_version: u32,
    overrides: Vec<PriceOverride>,
}

#[derive(Debug, Default)]
pub struct CustomPricing {
    rules: HashMap<(String, String, OverrideTier), PriceOverride>,
}

impl CustomPricing {
    pub fn from_file(path: &Path) -> Result<Self, String> {
        let file = File::open(path).map_err(|error| format!("读取自定义价格文件失败：{error}"))?;
        let metadata = file
            .metadata()
            .map_err(|error| format!("检查自定义价格文件失败：{error}"))?;
        if !metadata.is_file() || metadata.len() > MAX_FILE_BYTES as u64 {
            return Err("自定义价格须为大小在 1 MiB 以内的文件".into());
        }
        // Bound the read too, in case a writer grows the file after metadata().
        let mut bytes = Vec::new();
        file.take((MAX_FILE_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|error| format!("读取自定义价格文件失败：{error}"))?;
        Self::from_json(&bytes)
    }

    pub fn from_json(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > MAX_FILE_BYTES {
            return Err("自定义价格文件超出 1 MiB 上限".into());
        }
        let file: PricingFile = serde_json::from_slice(bytes)
            .map_err(|error| format!("自定义价格 JSON 无效：{error}"))?;
        if file.schema_version != 1 {
            return Err(format!(
                "自定义价格 schemaVersion 须为 1，当前为 {}",
                file.schema_version
            ));
        }
        let mut ids = HashSet::new();
        let mut keys = HashSet::new();
        let mut rules = HashMap::new();
        for rule in file.overrides {
            if !valid_uuid(&rule.id) {
                return Err("自定义价格 id 须为 UUID".into());
            }
            if !ids.insert(rule.id.to_ascii_lowercase()) {
                return Err("自定义价格包含重复 id".into());
            }
            let platform = matching_key(&rule.platform);
            if !matches!(
                platform.as_str(),
                "codex" | "claude" | "grok" | "antigravity" | "zcode"
            ) {
                return Err(format!("自定义价格平台无效：{}", rule.platform));
            }
            let trimmed_model = rule.model_id.trim();
            if trimmed_model.is_empty()
                || trimmed_model.chars().count() > 200
                || trimmed_model.chars().any(is_control_character)
            {
                return Err("模型 ID 应为 1 至 200 个字符，并使用可显示字符".into());
            }
            let model = matching_key(trimmed_model);
            for rate in [
                rule.input_per_million,
                rule.cached_input_per_million,
                rule.cache_write_per_million,
                rule.output_per_million,
            ] {
                validate_rate(rate)?;
            }
            let key = (
                platform,
                model,
                rule.service_tier.unwrap_or(OverrideTier::Any),
            );
            if !keys.insert(key.clone()) {
                return Err("自定义价格包含重复的平台、模型与服务层级组合".into());
            }
            if rule.enabled.unwrap_or(true) {
                rules.insert(key, rule);
            }
        }
        Ok(Self { rules })
    }

    pub fn apply(&self, messages: &mut [UnifiedMessage]) {
        if self.rules.is_empty() {
            return;
        }
        for message in messages {
            if message.cost_source == CostSource::ProviderReported {
                continue;
            }
            let platform = matching_key(&message.client);
            let model = matching_key(&message.model_id);
            let tier = match message.service_tier {
                ServiceTier::Fast => OverrideTier::Fast,
                ServiceTier::Standard | ServiceTier::Unknown => OverrideTier::Standard,
            };
            let rule = self
                .rules
                .get(&(platform.clone(), model.clone(), tier))
                .or_else(|| self.rules.get(&(platform, model, OverrideTier::Any)));
            let Some(rule) = rule else { continue };
            let tokens = &message.tokens;
            let costs = TokenCostBreakdown {
                input: tokens.input.max(0) as f64 * rule.input_per_million / PER_MILLION,
                cache_read: tokens.cache_read.max(0) as f64 * rule.cached_input_per_million
                    / PER_MILLION,
                cache_write: tokens.cache_write.max(0) as f64 * rule.cache_write_per_million
                    / PER_MILLION,
                output: tokens.output.max(0) as f64 * rule.output_per_million / PER_MILLION,
                reasoning: tokens.reasoning.max(0) as f64 * rule.output_per_million / PER_MILLION,
            };
            message.cost = costs.total();
            message.token_costs = Some(costs);
            message.cost_source = CostSource::Estimated;
        }
    }
}

fn matching_key(value: &str) -> String {
    value.trim().to_lowercase()
}

// Foundation's controlCharacters includes both Unicode Cc and Cf. Rust's
// is_control covers Cc; include format controls too to match the editor's check.
fn is_control_character(character: char) -> bool {
    character.is_control()
        || matches!(character,
            '\u{00ad}' | '\u{0600}'..='\u{0605}' | '\u{061c}' | '\u{06dd}' | '\u{070f}'
            | '\u{0890}'..='\u{0891}' | '\u{08e2}' | '\u{180e}' | '\u{200b}'..='\u{200f}'
            | '\u{202a}'..='\u{202e}' | '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{206f}'
            | '\u{feff}' | '\u{fff9}'..='\u{fffb}' | '\u{110bd}' | '\u{110cd}'
            | '\u{13430}'..='\u{1343f}' | '\u{1bca0}'..='\u{1bca3}'
            | '\u{1d173}'..='\u{1d17a}' | '\u{e0001}' | '\u{e0020}'..='\u{e007f}')
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn validate_rate(rate: f64) -> Result<(), String> {
    if rate.is_finite() && (0.0..=PER_MILLION).contains(&rate) {
        Ok(())
    } else {
        Err("自定义单价须为 0 至 1000000 之间的有限数值".into())
    }
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotedRates {
    pub input_per_million: Option<f64>,
    pub cached_input_per_million: Option<f64>,
    pub cache_write_per_million: Option<f64>,
    pub output_per_million: Option<f64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PriceQuote {
    pub platform: String,
    #[serde(rename = "modelID")]
    pub model_id: String,
    pub service_tier: ServiceTier,
    pub rates: Option<QuotedRates>,
}

/// Sample buckets separately so an unknown cache-write tariff cannot hide a
/// known input/output tariff, and a long-context threshold stays untriggered.
pub fn quote_rates(
    mut calculate: impl FnMut(&TokenBreakdown) -> Option<TokenCostBreakdown>,
) -> Option<QuotedRates> {
    fn sample(
        calculate: &mut impl FnMut(&TokenBreakdown) -> Option<TokenCostBreakdown>,
        tokens: TokenBreakdown,
        select: impl FnOnce(TokenCostBreakdown) -> f64,
    ) -> Option<f64> {
        let rate = select(calculate(&tokens)?) * PER_MILLION;
        (rate.is_finite() && rate >= 0.0).then_some(rate)
    }
    let rates = QuotedRates {
        input_per_million: sample(
            &mut calculate,
            TokenBreakdown {
                input: 1,
                ..Default::default()
            },
            |costs| costs.input,
        ),
        cached_input_per_million: sample(
            &mut calculate,
            TokenBreakdown {
                cache_read: 1,
                ..Default::default()
            },
            |costs| costs.cache_read,
        ),
        cache_write_per_million: sample(
            &mut calculate,
            TokenBreakdown {
                cache_write: 1,
                ..Default::default()
            },
            |costs| costs.cache_write,
        ),
        output_per_million: sample(
            &mut calculate,
            TokenBreakdown {
                output: 1,
                ..Default::default()
            },
            |costs| costs.output,
        ),
    };
    [
        rates.input_per_million,
        rates.cached_input_per_million,
        rates.cache_write_per_million,
        rates.output_per_million,
    ]
    .iter()
    .any(Option::is_some)
    .then_some(rates)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn rule(id: u8, tier: &str, rate: f64) -> Value {
        json!({"id":format!("12345678-1234-1234-1234-{id:012}"), "platform":"codex",
            "modelID":"exact-model", "serviceTier":tier, "inputPerMillion":rate,
            "cachedInputPerMillion":0.2, "cacheWritePerMillion":2.5,
            "outputPerMillion":10.0, "enabled":true})
    }

    fn prices(rules: Vec<Value>) -> CustomPricing {
        CustomPricing::from_json(
            &serde_json::to_vec(&json!({"schemaVersion":1,"overrides":rules})).unwrap(),
        )
        .unwrap()
    }

    fn message() -> UnifiedMessage {
        let mut message = UnifiedMessage::new_with_agent(
            "codex",
            "exact-model",
            "openai",
            "session",
            1_788_350_400_000,
            TokenBreakdown {
                input: 1_000_000,
                cache_read: 2_000_000,
                cache_write: 3_000_000,
                output: 4_000_000,
                reasoning: 5_000_000,
            },
            987.0,
            None,
        );
        message.model_duration_ms = Some(1000);
        message.time_to_first_token_ms = Some(120);
        message
    }

    #[test]
    fn overrides_each_bucket_once_without_automatic_fast_or_context_multipliers() {
        let custom = prices(vec![rule(1, "any", 2.0)]);
        let mut rows = vec![message()];
        rows[0].model_id = " Exact-Model ".into();
        rows[0].service_tier = ServiceTier::Fast;
        let mut expected = rows[0].clone();
        let costs = TokenCostBreakdown {
            input: 2.0,
            cache_read: 0.4,
            cache_write: 7.5,
            output: 40.0,
            reasoning: 50.0,
        };
        expected.cost = costs.total();
        expected.token_costs = Some(costs);
        expected.cost_source = CostSource::Estimated;
        custom.apply(&mut rows);
        assert_eq!(rows, vec![expected]);
    }

    #[test]
    fn exact_tiers_beat_any_and_unknown_uses_standard() {
        let custom = prices(vec![
            rule(1, "any", 1.0),
            rule(2, "fast", 3.0),
            rule(3, "standard", 2.0),
        ]);
        let mut rows = vec![message(), message(), message()];
        for (row, tier) in rows.iter_mut().zip([
            ServiceTier::Fast,
            ServiceTier::Standard,
            ServiceTier::Unknown,
        ]) {
            row.service_tier = tier;
            row.tokens = TokenBreakdown {
                input: 1_000_000,
                ..Default::default()
            };
        }
        custom.apply(&mut rows);
        assert_eq!(
            rows.iter().map(|row| row.cost).collect::<Vec<_>>(),
            vec![3.0, 2.0, 2.0]
        );
        let any = prices(vec![rule(1, "any", 4.0)]);
        any.apply(&mut rows);
        assert!(rows.iter().all(|row| row.cost == 4.0));
    }

    #[test]
    fn accepts_zero_rates_and_rejects_invalid_numbers_duplicates_and_schema() {
        for rate in [0.0, 1_000_000.0] {
            assert!(validate_rate(rate).is_ok());
        }
        for rate in [
            -0.1,
            1_000_000.1,
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
        ] {
            assert!(validate_rate(rate).is_err());
        }
        let zero = json!({"id":"12345678-1234-1234-1234-123456789abc","platform":"codex",
            "modelID":"exact-model","serviceTier":"any","inputPerMillion":0,
            "cachedInputPerMillion":0,"cacheWritePerMillion":0,"outputPerMillion":0,"enabled":true});
        let mut rows = vec![message()];
        prices(vec![zero]).apply(&mut rows);
        assert_eq!(rows[0].cost, 0.0);
        assert_eq!(rows[0].cost_source, CostSource::Estimated);
        for rules in [
            vec![rule(1, "any", 2.0), rule(1, "fast", 3.0)],
            vec![rule(1, "any", 2.0), rule(2, "any", 3.0)],
        ] {
            assert!(CustomPricing::from_json(
                &serde_json::to_vec(&json!({"schemaVersion":1,"overrides":rules})).unwrap()
            )
            .is_err());
        }
        let mut duplicate = rule(2, "any", 3.0);
        duplicate["modelID"] = json!(" EXACT-MODEL ");
        assert!(CustomPricing::from_json(
            &serde_json::to_vec(
                &json!({"schemaVersion":1,"overrides":[rule(1,"any",2.0),duplicate]})
            )
            .unwrap()
        )
        .is_err());
        for bytes in [
            br#"{"schemaVersion":2,"overrides":[]}"#.as_slice(),
            br#"{"schemaVersion":1,"overrides":[{"inputPerMillion":NaN}]}"#,
            br#"{"schemaVersion":1,"overrides":[{"inputPerMillion":1e309}]}"#,
        ] {
            assert!(CustomPricing::from_json(bytes).is_err());
        }
    }
}
