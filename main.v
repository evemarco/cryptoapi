module main

import veb
import time
import log
import json2
import math
import os
import toml

pub struct App {
	cfg Config
}

pub struct Context {
	veb.Context
}

pub struct Config {
	port                    int    = 3040
	update_interval_seconds int    = 300
	prices_file             string = '/var/lib/cryptoapi/prices.json'
	grist_api_url           string = 'https://grist.dedimarco.com/api/docs/pgozipRBTC2UkXzdRM6ixp/tables/Coins/records'
	grist_bearer_token      string = 'c749fb13bb8bbeafb5841d54e4c6c05011aa51c9'
}

fn load_config() Config {
	content := os.read_file('config.toml') or {
		log.info('No config.toml found, using default configuration')
		return Config{}
	}
	cfg := toml.decode[Config](content) or {
		log.error('Failed to parse config.toml: ${err}')
		exit(1)
	}
	log.info('Loaded configuration from config.toml')
	return cfg
}

// A fetch cycle only counts as successful (and is pushed to Grist) when every
// crypto symbol was freshly fetched; fiat rates are secondary and may carry
// over from the last known values.
const crypto_symbols = ['BTC', 'BNB', 'XMR', 'DOGE', 'XRP', 'POL', 'SOL', 'ETH']

// Coinbase exchange-rates covers these directly. XMR is delisted from Coinbase
// and comes from Kraken instead (fetch_kraken_xmr).
const coinbase_symbols = ['BTC', 'ETH', 'SOL', 'XRP', 'DOGE', 'BNB', 'POL']

struct PriceData {
mut:
	prices              map[string]f64
	last_update         string
	last_success_update string
}

struct CoinbaseData {
	currency string
	rates    map[string]string
}

struct CoinbaseResponse {
	data CoinbaseData
}

struct KrakenTicker {
	c []string // last trade: [price, volume]
}

struct KrakenResponse {
	error  []string
	result map[string]KrakenTicker
}

fn main() {
	cfg := load_config()
	log.info('Starting server on 0.0.0.0:${cfg.port}')

	mut app := &App{
		cfg: cfg
	}

	// The cache holds the last known prices across restarts, make sure its
	// directory exists before the first write.
	os.mkdir_all(os.dir(cfg.prices_file)) or {}

	// Initialize prices and write to file
	update_prices_and_write(cfg)

	// Start update goroutine
	spawn update_prices_loop(cfg)

	veb.run[App, Context](mut app, cfg.port)
}

@['/']
pub fn (app &App) index(mut ctx Context) veb.Result {
	return app.get_prices(mut ctx)
}

@['/prices']
pub fn (app &App) get_prices(mut ctx Context) veb.Result {
	content := os.read_file(app.cfg.prices_file) or {
		log.error('Failed to read prices file: ${err}')
		return ctx.json(PriceData{})
	}

	if decoded := json2.decode[PriceData](content) {
		return ctx.json(decoded)
	}

	return ctx.json(PriceData{})
}

fn update_prices_loop(cfg Config) {
	log.info('Starting price update loop')
	for {
		time.sleep(cfg.update_interval_seconds * time.second)
		update_prices_and_write(cfg)
	}
}

// Used only before the first successful fetch ever (missing or unreadable
// cache file); live updates never reset to these values. Key directions follow
// the live fetch code: 'EUR' is USD per 1 EUR, 'THB' and 'VND' are units of
// fiat per 1 USD.
fn static_fallback_prices() map[string]f64 {
	return {
		'BTC':  69763.0
		'ETH':  1976.84
		'XMR':  354.77
		'BNB':  634.98
		'SOL':  87.35
		'XRP':  1.47
		'DOGE': 0.1028
		'POL':  0.1109
		'EUR':  1.1865
		'THB':  32.89
		'VND':  25974.0
	}
}

fn read_previous_prices(path string) PriceData {
	if content := os.read_file(path) {
		if decoded := json2.decode[PriceData](content) {
			return decoded
		}
		log.warn('Failed to parse prices cache ${path}, ignoring previous values')
	}
	return PriceData{}
}

// Round to 6 significant digits, clamped to 2–6 decimals. Finer precision is
// float noise from the 1/rate inversions, not real market data; the 2-decimal
// floor keeps familiar cent-precision on large values (BTC, VND, ...).
fn round_price(v f64) f64 {
	if v == 0 {
		return 0
	}
	mut decimals := 5 - int(math.floor(math.log10(math.abs(v))))
	if decimals < 2 {
		decimals = 2
	}
	if decimals > 6 {
		decimals = 6
	}
	factor := math.pow(10, f64(decimals))
	return math.round(v * factor) / factor
}

fn update_prices_and_write(cfg Config) {
	// Start from the last known values: on a failed or incomplete fetch they
	// are kept and re-served instead of resetting to hard-coded prices.
	prev := read_previous_prices(cfg.prices_file)
	mut prices := prev.prices.clone()

	mut fresh := map[string]f64{}

	coinbase_prices := fetch_coinbase_prices()
	for k, v in coinbase_prices {
		fresh[k] = v
	}

	xmr := fetch_kraken_xmr()
	if xmr > 0 {
		fresh['XMR'] = xmr
	}

	fiat_prices := fetch_fiat_prices()
	for k, v in fiat_prices {
		fresh[k] = v
	}

	mut fresh_crypto := 0
	for sym in crypto_symbols {
		if sym in fresh {
			fresh_crypto++
		}
	}
	fetch_success := fresh_crypto == crypto_symbols.len

	if !fetch_success {
		if prev.prices.len == 0 {
			log.warn('API fetch failed with no previous prices, using static fallback values')
			prices = static_fallback_prices()
		} else {
			log.warn('API fetch incomplete (${fresh_crypto}/${crypto_symbols.len} crypto fresh), keeping last known prices from ${prev.last_success_update}')
		}
	}
	for k, v in fresh {
		prices[k] = v
	}

	mut last_success_update := prev.last_success_update
	if fetch_success {
		last_success_update = time.now().str()
	}

	data := PriceData{
		prices:              prices
		last_update:         time.now().str()
		last_success_update: last_success_update
	}

	json_str := json2.encode(data)
	os.write_file(cfg.prices_file, json_str) or {
		log.error('Failed to write prices file: ${err}')
		return
	}

	log.info('Updated prices at ${time.now()}')
	for k, v in prices {
		log.info('${k}: ${v}')
	}
	log.info('Last successful fetch: ${last_success_update}')

	if fetch_success {
		send_to_grist(cfg, prices, last_success_update)
	} else {
		log.warn('Skipping Grist update due to failed API fetch')
	}
}

// Coinbase returns units of crypto per 1 USD, so invert to get the price.
fn fetch_coinbase_prices() map[string]f64 {
	mut prices := map[string]f64{}
	body := curl_get('https://api.coinbase.com/v2/exchange-rates?currency=USD')
	if body == '' {
		return prices
	}
	decoded := json2.decode[CoinbaseResponse](body) or {
		log.warn('Failed to parse Coinbase USD data')
		return prices
	}
	for sym in coinbase_symbols {
		if rate_str := decoded.data.rates[sym] {
			rate := rate_str.f64()
		if rate > 0 {
			prices[sym] = round_price(1.0 / rate)
		}
		}
	}
	return prices
}

fn fetch_kraken_xmr() f64 {
	body := curl_get('https://api.kraken.com/0/public/Ticker?pair=XMRUSD')
	if body == '' {
		return 0.0
	}
	decoded := json2.decode[KrakenResponse](body) or {
		log.warn('Failed to parse Kraken XMR data')
		return 0.0
	}
	if decoded.error.len > 0 {
		log.warn('Kraken API error: ${decoded.error[0]}')
		return 0.0
	}
	if ticker := decoded.result['XXMRZUSD'] {
		if ticker.c.len > 0 {
			return round_price(ticker.c[0].f64())
		}
	}
	log.warn('Kraken response missing XMR ticker')
	return 0.0
}

// Fiat rates from the EUR-base Coinbase response. 'EUR' is stored as USD per
// 1 EUR; 'THB' and 'VND' are units of fiat per 1 USD.
fn fetch_fiat_prices() map[string]f64 {
	mut prices := map[string]f64{}
	body := curl_get('https://api.coinbase.com/v2/exchange-rates?currency=EUR')
	if body == '' {
		return prices
	}
	decoded := json2.decode[CoinbaseResponse](body) or {
		log.warn('Failed to parse Coinbase EUR data')
		return prices
	}
	if usd_str := decoded.data.rates['USD'] {
		usd_per_eur := usd_str.f64()
		if usd_per_eur > 0 {
			prices['EUR'] = round_price(usd_per_eur)
			if thb_str := decoded.data.rates['THB'] {
				prices['THB'] = round_price(thb_str.f64() / usd_per_eur)
			}
			if vnd_str := decoded.data.rates['VND'] {
				prices['VND'] = round_price(vnd_str.f64() / usd_per_eur)
			}
		}
	}
	return prices
}

// -f makes curl fail on HTTP >= 400 (a 403 error page no longer parses as
// broken JSON silently), -m bounds the request time.
fn curl_get(url string) string {
	pid := os.getpid()
	tmp_file := '/tmp/curl_response_${pid}'
	err_file := '/tmp/curl_error_${pid}'
	defer {
		os.rm(tmp_file) or {}
		os.rm(err_file) or {}
	}
	command := 'curl -fsS -m 20 "${url}" -o "${tmp_file}" 2> "${err_file}"'
	exit_code := os.system(command)
	if exit_code != 0 {
		err_msg := os.read_file(err_file) or { '' }
		log.error('curl exit ${exit_code} for ${url}: ${err_msg.trim_space()}')
		return ''
	}
	return os.read_file(tmp_file) or { '' }
}

fn send_to_grist(cfg Config, prices map[string]f64, last_success_update string) {
	btc_value := prices['BTC'] or { 0.0 }
	bnb_value := prices['BNB'] or { 0.0 }
	xmr_value := prices['XMR'] or { 0.0 }
	doge_value := prices['DOGE'] or { 0.0 }
	xrp_value := prices['XRP'] or { 0.0 }
	pol_value := prices['POL'] or { 0.0 }
	sol_value := prices['SOL'] or { 0.0 }
	eth_value := prices['ETH'] or { 0.0 }
	eur_value := round_price(1 / prices['EUR'] or { 0.0 })
	thb_value := prices['THB'] or { 0.0 }
	vnd_value := prices['VND'] or { 0.0 }

	json_payload := '{
  "records": [
    {
      "id": 1,
      "fields": {
        "coin": "BTC",
        "usd": ${btc_value},
        "fiat": "EUR",
        "fiat_usd": ${eur_value},
        "last_success_update": "${last_success_update}"
      }
    },
    {
      "id": 2,
      "fields": {
        "coin": "BNB",
        "usd": ${bnb_value},
        "fiat": "THB",
        "fiat_usd": ${thb_value},
        "last_success_update": "${last_success_update}"
      }
    },
    {
      "id": 3,
      "fields": {
        "coin": "XMR",
        "usd": ${xmr_value},
        "fiat": "VND",
        "fiat_usd": ${vnd_value},
        "last_success_update": "${last_success_update}"
      }
    },
    {
      "id": 4,
      "fields": {
        "coin": "DOGE",
        "usd": ${doge_value},
        "fiat": "USD",
        "fiat_usd": 1.0,
        "last_success_update": "${last_success_update}"
      }
    },
    {
      "id": 5,
      "fields": {
        "coin": "XRP",
        "usd": ${xrp_value},
        "fiat": null,
        "fiat_usd": 0.0,
        "last_success_update": "${last_success_update}"
      }
    },
    {
      "id": 6,
      "fields": {
        "coin": "POL",
        "usd": ${pol_value},
        "fiat": null,
        "fiat_usd": 0.0,
        "last_success_update": "${last_success_update}"
      }
    },
    {
      "id": 7,
      "fields": {
        "coin": "SOL",
        "usd": ${sol_value},
        "fiat": null,
        "fiat_usd": 0.0,
        "last_success_update": "${last_success_update}"
      }
    },
    {
      "id": 8,
      "fields": {
        "coin": "ETH",
        "usd": ${eth_value},
        "fiat": null,
        "fiat_usd": 0.0,
        "last_success_update": "${last_success_update}"
      }
    }
  ]
}'

	pid := os.getpid()
	tmp_file := '/tmp/grist_payload_${pid}'
	os.write_file(tmp_file, json_payload) or {
		log.error('Failed to write Grist payload: ${err}')
		return
	}

	err_file := '/tmp/grist_error_${pid}'
	command := 'curl -fsS -X "PATCH" "${cfg.grist_api_url}" -H "accept: */*" -H "Authorization: Bearer ${cfg.grist_bearer_token}" -H "Content-Type: application/json" -d @${tmp_file} -o /dev/null 2> "${err_file}"'
	exit_code := os.system(command)
	if exit_code != 0 {
		err_msg := os.read_file(err_file) or { '' }
		log.error('Grist update failed (curl exit ${exit_code}): ${err_msg.trim_space()}')
	} else {
		log.info('Sent prices to Grist')
	}
	os.rm(tmp_file) or {}
	os.rm(err_file) or {}
}
