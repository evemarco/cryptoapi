module main

import vweb
import time
import log
import json
import os

struct App {
	vweb.Context
mut:
	prices map[string]f64
	last_update time.Time
}

const update_interval = 5 * time.minute
const prices_file = '/tmp/crypto_prices.json'

struct PriceData {
mut:
	prices map[string]f64
	last_update string
}

struct CoingeckoPrice {
	usd f64
}

struct CoinbaseData {
	currency string
	rates map[string]string
}

struct CoinbaseResponse {
	data CoinbaseData
}

fn main() {
	log.info("Starting server on 0.0.0.0:3040")

	mut app := &App{
		prices: map[string]f64{}
		last_update: time.now()
	}

	// Initialize prices and write to file
	update_prices_and_write()

	// Start update goroutine
	spawn update_prices_loop()

	vweb.run(app, 3040)
}

@['/']
pub fn (mut app App) index() vweb.Result {
	return app.get_prices()
}

@['/prices']
pub fn (mut app App) get_prices() vweb.Result {
	// Read prices from file
	app.prices = read_prices_from_file()
	println("Serving ${app.prices.len} prices")
	return app.json(app.prices)
}

fn update_prices_loop() {
	log.info("Starting price update loop")
	for {
		time.sleep(update_interval)
		update_prices_and_write()
	}
}

fn update_prices_and_write() {
	mut prices := map[string]f64{}

	// Fetch prices from APIs using curl
	coingecko_data := fetch_coingecko_prices()
	coinbase_data := fetch_coinbase_eur()

	// Parse and store crypto prices
	if coingecko_data != "" {
		// Parse Coingecko JSON: {"bitcoin":{"usd":69801}, ...}
		if decoded := json.decode(map[string]CoingeckoPrice, coingecko_data) {
			coingecko_map := decoded.clone()
			if bitcoin := coingecko_map["bitcoin"] {
				prices["BTC"] = bitcoin.usd
			}
			if binancecoin := coingecko_map["binancecoin"] {
				prices["BNB"] = binancecoin.usd
			}
			if monero := coingecko_map["monero"] {
				prices["XMR"] = monero.usd
			}
			if dogecoin := coingecko_map["dogecoin"] {
				prices["DOGE"] = dogecoin.usd
			}
			if ripple := coingecko_map["ripple"] {
				prices["XRP"] = ripple.usd
			}
			if polygon := coingecko_map["polygon-ecosystem-token"] {
				prices["POL"] = polygon.usd
			}
			if solana := coingecko_map["solana"] {
				prices["SOL"] = solana.usd
			}
		} else {
			log.warn("Failed to parse Coingecko data")
		}
	}

	// Parse EUR rate from Coinbase
	if coinbase_data != "" {
		if decoded := json.decode(CoinbaseResponse, coinbase_data) {
			if usd_str := decoded.data.rates["USD"] {
				prices["EUR"] = usd_str.f64()
			}
		} else {
			log.warn("Failed to parse Coinbase data")
		}
	}

	// If fetch failed, use static values
	if prices.len == 0 {
		log.warn("API fetch failed, using static values")
		prices["XMR"] = 354.77
		prices["BNB"] = 634.98
		prices["BTC"] = 69763.00
		prices["DOGE"] = 0.1028
		prices["XRP"] = 1.47
		prices["POL"] = 0.1109
		prices["SOL"] = 87.35
		prices["EUR"] = 1.1865
	}

	// Write to file
	data := PriceData{
		prices: prices
		last_update: time.now().str()
	}

	json_str := json.encode(data)
	os.write_file(prices_file, json_str) or {
		log.error("Failed to write prices file: ${err}")
		return
	}

	log.info("Updated prices at ${time.now()}")
	for k, v in prices {
		log.info("${k}: ${v}")
	}
}

fn read_prices_from_file() map[string]f64 {
	content := os.read_file(prices_file) or {
		log.error("Failed to read prices file: ${err}")
		return map[string]f64{}
	}

	if decoded := json.decode(PriceData, content) {
		return decoded.prices
	}

	return map[string]f64{}
}

fn fetch_coingecko_prices() string {
	url := 'https://api.coingecko.com/api/v3/simple/price?ids=monero,binancecoin,bitcoin,dogecoin,ripple,polygon-ecosystem-token,solana&vs_currencies=usd'
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
