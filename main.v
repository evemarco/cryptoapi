module main

import veb
import time
import log
import json2
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
	prices_file             string = '/tmp/crypto_prices.json'
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

struct PriceData {
mut:
	prices              map[string]f64
	last_update         string
	last_success_update string
}

struct CoingeckoPrice {
	usd f64
}

struct CoinbaseData {
	currency string
	rates    map[string]string
}

struct CoinbaseResponse {
	data CoinbaseData
}

fn main() {
	cfg := load_config()
	log.info('Starting server on 0.0.0.0:${cfg.port}')

	mut app := &App{
		cfg: cfg
	}

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

fn update_prices_and_write(cfg Config) {
	mut prices := map[string]f64{}
	mut fetch_success := false

	// Fetch prices from APIs using curl
	coingecko_data := fetch_coingecko_prices()
	coinbase_data := fetch_coinbase_eur()

	// Parse and store crypto prices
	if coingecko_data != '' {
		// Parse Coingecko JSON: {"bitcoin":{"usd":69801}, ...}
		if decoded := json2.decode[map[string]CoingeckoPrice](coingecko_data) {
			coingecko_map := decoded.clone()
			if bitcoin := coingecko_map['bitcoin'] {
				prices['BTC'] = bitcoin.usd
			}
			if binancecoin := coingecko_map['binancecoin'] {
				prices['BNB'] = binancecoin.usd
			}
			if monero := coingecko_map['monero'] {
				prices['XMR'] = monero.usd
			}
			if dogecoin := coingecko_map['dogecoin'] {
				prices['DOGE'] = dogecoin.usd
			}
			if ripple := coingecko_map['ripple'] {
				prices['XRP'] = ripple.usd
			}
			if polygon := coingecko_map['polygon-ecosystem-token'] {
				prices['POL'] = polygon.usd
			}
			if solana := coingecko_map['solana'] {
				prices['SOL'] = solana.usd
			}
			if ethereum := coingecko_map['ethereum'] {
				prices['ETH'] = ethereum.usd
			}
		} else {
			log.warn('Failed to parse Coingecko data')
		}
	}

	// Parse EUR, THB, VND rates from Coinbase (single API call)
	if coinbase_data != '' {
		if decoded := json2.decode[CoinbaseResponse](coinbase_data) {
			// EUR/USD rate
			if usd_str := decoded.data.rates['USD'] {
				prices['EUR'] = usd_str.f64()
			}
			// THB/USD rate (convert from EUR base)
			if thb_str := decoded.data.rates['THB'] {
				usd_per_eur := decoded.data.rates['USD'].f64()
				thb_per_eur := thb_str.f64()
				prices['THB'] = thb_per_eur / usd_per_eur
			}
			// VND/USD rate (convert from EUR base)
			if vnd_str := decoded.data.rates['VND'] {
				usd_per_eur := decoded.data.rates['USD'].f64()
				vnd_per_eur := vnd_str.f64()
				prices['VND'] = vnd_per_eur / usd_per_eur
			}
		} else {
			log.warn('Failed to parse Coinbase EUR data')
		}
	}

	// Check if we got valid data from APIs (need at least crypto + fiat)
	if prices.len >= 10 {
		fetch_success = true
	}

	// Read previous last_success_update from file if exists
	mut prev_last_success := ''
	if content := os.read_file(cfg.prices_file) {
		if decoded := json2.decode[PriceData](content) {
			prev_last_success = decoded.last_success_update
		}
	}

	// If fetch failed, use static values
	if !fetch_success {
		log.warn('API fetch failed, using static values (not sending to Grist)')
		prices['XMR'] = 354.77
		prices['BNB'] = 634.98
		prices['BTC'] = 69763.00
		prices['DOGE'] = 0.1028
		prices['XRP'] = 1.47
		prices['POL'] = 0.1109
		prices['SOL'] = 87.35
		prices['EUR'] = 1.1865
		prices['THB'] = 0.0304
		prices['VND'] = 0.0000385
		prices['ETH'] = 1976.84
	}

	// Determine last_success_update
	mut last_success_update := prev_last_success
	if fetch_success {
		last_success_update = time.now().str()
	}

	// Write to file
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

	// Only send to Grist if fetch was successful
	if fetch_success {
		send_to_grist(cfg, prices, last_success_update)
	} else {
		log.warn('Skipping Grist update due to failed API fetch')
	}
}

fn fetch_coingecko_prices() string {
	url := 'https://api.coingecko.com/api/v3/simple/price?ids=monero,binancecoin,bitcoin,dogecoin,ripple,polygon-ecosystem-token,solana,ethereum&vs_currencies=usd'
	return curl_get(url)
}

fn fetch_coinbase_eur() string {
	url := 'https://api.coinbase.com/v2/exchange-rates?currency=EUR'
	return curl_get(url)
}

fn curl_get(url string) string {
	// Use process ID to generate unique filename
	pid := os.getpid()
	tmp_file := '/tmp/curl_response_${pid}'
	command := 'curl -s "${url}" > "${tmp_file}"'
	os.system(command)
	content := os.read_file(tmp_file) or { '' }
	os.rm(tmp_file) or {}
	return content
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
	eur_value := 1 / prices['EUR'] or { 0.0 }
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

	command := 'curl -X "PATCH" "${cfg.grist_api_url}" -H "accept: */*" -H "Authorization: Bearer ${cfg.grist_bearer_token}" -H "Content-Type: application/json" -d @${tmp_file}'
	os.system(command)
	os.rm(tmp_file) or {}

	log.info('Sent prices to Grist')
}
