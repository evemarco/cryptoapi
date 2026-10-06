# AGENTS.md

This document contains essential information for working with the cryptoapi Vlang project.

## Project Overview

A REST API server written in Vlang that provides real-time cryptocurrency prices and exchange rates. The server fetches prices from external APIs (Coinbase for crypto USD prices and fiat rates, Kraken for XMR) and updates them every 5 minutes. CoinGecko was dropped on 2026-09-29 (commit `142c388`) because it rejected requests from the hosting datacenter with HTTP 403.

**Tech Stack**: Vlang (veb framework), JSON file-based caching, curl for HTTP requests
**Listening Port**: 3040 (configurable in `config.toml`)
**Executable Name**: `cryptoapi` (built via `./build.sh`)

## Build & Run Commands

### Development
```bash
v run main.v
```

### Production Build (optimized)
**Using build script (recommended):**
```bash
./build.sh
./cryptoapi
```

**Manual build:**
```bash
v -prod -o cryptoapi main.v
./cryptoapi
```

Note: The executable is named `cryptoapi`, not `main`.

### Production Run (without service)
```bash
v -prod run main.v
# or
./cryptoapi
```

### Systemd Service (Production)
```bash
# Build
./build.sh

# Install service
sudo cp cryptoapi.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable cryptoapi
sudo systemctl start cryptoapi

# Check status
sudo systemctl status cryptoapi

# View logs
sudo journalctl -u cryptoapi -f

# Manage service
sudo systemctl stop cryptoapi
sudo systemctl restart cryptoapi
sudo systemctl disable cryptoapi
```

### Test the API
```bash
# Get all prices
curl http://localhost:3040/prices
curl http://localhost:3040/

# Verbose output
curl -i http://localhost:3040/
```

## Code Organization

**Single-file architecture**: All code is in `main.v`
- Module declaration at top
- Struct definitions (App, PriceData, API response types)
- `main()` function - server entry point
- Route handlers (decorated with `@['/path']`)
- Helper functions (update logic, file I/O, HTTP fetching)

**Build & deployment files**:
- `build.sh` - Build script that creates the `cryptoapi` executable
- `cryptoapi.service` - systemd service file for production deployment

**Runtime files**:
- `/var/lib/cryptoapi/prices.json` - cached price data (auto-generated)
- `cryptoapi` - Compiled executable (created by build script)

## Code Style & Conventions

### Formatting (from .editorconfig)
- **Indentation**: Tabs (`\t`)
- **Charset**: UTF-8
- **Line endings**: LF (Unix)
- **Final newline**: Required
- **Trailing whitespace**: Trimmed

### Naming Conventions
- **Modules**: lowercase (`module main`)
- **Structs**: PascalCase (`App`, `PriceData`, `KrakenTicker`)
- **Constants**: snake_case
- **Functions**: snake_case (`update_prices_loop`, `fetch_coinbase_prices`)
- **Mutable struct fields**: marked with `mut:`
- **Private functions**: no `pub` keyword
- **Public functions**: `pub` keyword

### Vlang Patterns

**Struct definitions** (veb model: shared `App` + per-request `Context`):
```v
pub struct App {}

pub struct Context {
    veb.Context
}
```

**Route handlers** (veb framework):
```v
@['/route']
pub fn (app &App) handler(mut ctx Context) veb.Result {
    return ctx.json(data)
}
```

**JSON decoding** (`json2` module):
```v
if decoded := json2.decode[StructType](json_string) {
    // Success - use decoded
} else {
    log.warn("Failed to decode JSON")
}
```

**Error handling** with or-else pattern:
```v
content := os.read_file(path) or {
    log.error("Failed to read: ${err}")
    return default_value
}
```

**Goroutines**:
```v
spawn update_prices_loop()  // Runs in background
```

**HTTP requests**: Uses curl via os.system (not V's HTTP client):
```v
fn curl_get(url string) string {
    pid := os.getpid()
    tmp_file := '/tmp/curl_response_${pid}'
    command := 'curl -s "${url}" > "${tmp_file}"'
    os.system(command)
    content := os.read_file(tmp_file) or { '' }
    os.rm(tmp_file) or {}
    return content
}
```

## Important Architecture Decisions

### Shared State Management
**Context**: price state is not kept in `App`; handlers re-read a shared JSON file on each request
**Solution**: Use shared JSON file at `/var/lib/cryptoapi/prices.json` for data persistence

### HTTP Requests
**Problem**: V's HTTP module blocks on HTTPS requests
**Solution**: Use `curl` via `os.system()` in `curl_get()` function

### Price Updates
- Background goroutine updates prices every 5 minutes (`update_interval_seconds` config setting)
- On failed or incomplete API fetch, keep the last known values (from the cache file); static fallback values are only used before the first successful fetch ever
- Updates are written to shared file immediately
- Grist is only updated if API fetch was successful (not on last known / static fallback)
- `last_success_update` tracks the timestamp of the last successful API fetch

## Runtime Configuration (`config.toml`)

Settings are loaded from `config.toml` in the working directory at startup — no recompile needed. Missing file or missing keys fall back to the defaults declared in the `Config` struct in `main.v`:

```toml
port = 3040                      # HTTP listen port
update_interval_seconds = 300    # How often to fetch prices
prices_file = "/var/lib/cryptoapi/prices.json"  # Where to cache prices
grist_api_url = "https://grist.dedimarco.com/api/docs/pgozipRBTC2UkXzdRM6ixp/tables/Coins/records"
grist_bearer_token = "your_token_here"   # Bearer token for Grist API authentication
```

A malformed `config.toml` aborts startup with an error (exit code 1).

## API Endpoints

- `GET /` - Returns all prices (JSON)
- `GET /prices` - Returns all prices with metadata (JSON)

Response format:
```json
{
  "prices": {
    "BTC": 69832.0,
    "BNB": 634.58,
    "XMR": 355.33,
    "DOGE": 0.102899,
    "XRP": 1.47,
    "POL": 0.111061,
    "SOL": 120.07,
    "ETH": 2701.17,
    "EUR": 1.1217,
    "THB": 33.664,
    "VND": 25991.49
  },
  "last_update": "2026-10-06 05:02:54",
  "last_success_update": "2026-10-06 05:02:54"
}
```

**Fields:**
- `prices`: Map of currency symbols to values (crypto and EUR are USD per 1 unit; THB and VND are fiat per 1 USD)
- `last_update`: Timestamp of the last update attempt (successful or not)
- `last_success_update`: Timestamp of the last successful API fetch (preserved on fallback)

## Adding New Cryptocurrencies

1. If the coin is listed on Coinbase, add its ticker to the `coinbase_symbols` const in `main.v`:
```v
const coinbase_symbols = ['BTC', 'ETH', 'SOL', 'XRP', 'DOGE', 'BNB', 'POL']
```
For a coin not on Coinbase (like XMR), add a dedicated fetch function (see `fetch_kraken_xmr`).

2. Add the symbol to `crypto_symbols` too — a fetch cycle only counts as successful when every symbol in that const was freshly fetched:
```v
const crypto_symbols = ['BTC', 'BNB', 'XMR', 'DOGE', 'XRP', 'POL', 'SOL', 'ETH']
```

3. Optionally add a value in `static_fallback_prices()` (only used before the first successful fetch ever)

## Adding New Exchange Rates

To add a new exchange rate (like JPY, GBP, etc.) similar to EUR and THB:

1. Create a new fetch function for the currency (e.g., `fetch_coinbase_jpy()`):
```v
fn fetch_coinbase_jpy() string {
    url := 'https://api.coinbase.com/v2/exchange-rates?currency=JPY'
    return curl_get(url)
}
```

2. Call it in `update_prices_and_write()`:
```v
coinbase_jpy_data := fetch_coinbase_jpy()
```

3. Parse the response:
```v
if coinbase_jpy_data != "" {
    if decoded := json2.decode[CoinbaseResponse](coinbase_jpy_data) {
        if usd_str := decoded.data.rates["USD"] {
            prices["JPY"] = usd_str.f64()
        }
    } else {
        log.warn("Failed to parse Coinbase JPY data")
    }
}
```

4. Add a static fallback value in `static_fallback_prices()`:
```v
'JPY': 0.0067  // Approximate JPY/USD rate
```

## Grist Integration

The server automatically sends price updates to a Grist table via PATCH requests after each successful API fetch (every 5 minutes if APIs respond correctly).

**Important:** Grist is NOT updated when the fetch is incomplete or failed; in that case the last known values are kept in the cache and served. Static fallback values are only used before the first successful fetch ever.

**Configuration:**
- `grist_api_url`: Grist API endpoint for the Coins table (set in `config.toml`)
- `grist_bearer_token`: Bearer token for API authentication (set in `config.toml`)

**Data sent to Grist:**
The `send_to_grist()` function sends 8 records with the following structure:
- Record 1: BTC with EUR fiat rate
- Record 2: BNB with THB fiat rate
- Record 3: XMR with VND fiat rate
- Records 4-8: DOGE, XRP, POL, SOL, ETH (crypto only)

**Response handling:**
- curl exit 0 → Success (logs "Sent prices to Grist")
- Any other exit code → Error logged as `Grist update failed (curl exit N): <stderr>`

**Grist request format:**
```json
{
  "records": [
    {
      "id": 1,
      "fields": {
        "coin": "BTC",
        "usd": <btc_value>,
        "fiat": "EUR",
        "fiat_usd": <eur_value>,
        "last_success_update": "2026-03-02 12:48:22"
      }
    },
    ...
  ]
}
```

**Required Grist columns:**
- `coin`: Currency symbol (BTC, ETH, etc.)
- `usd`: USD price value
- `fiat`: Associated fiat currency (EUR, THB, VND, USD, or null)
- `fiat_usd`: Fiat rate in units of fiat per 1 USD (for the BTC record, `1 / EUR` rate, i.e. EUR per USD)
- `last_success_update`: Timestamp of successful data fetch

**To update Grist configuration:**
1. Edit `grist_api_url` in `config.toml` to change the endpoint
2. Edit `grist_bearer_token` in `config.toml` to update authentication
3. Restart the service (no rebuild needed)

## External Dependencies

- **veb**: V's builtin web framework (imported as `veb`)
- **curl**: System curl binary (for HTTP requests to external APIs)
- **Coinbase API**: https://api.coinbase.com/v2/exchange-rates (crypto USD base + fiat EUR base)
- **Kraken API**: https://api.kraken.com/0/public/Ticker (XMR, delisted from Coinbase)

## Systemd Service

For production deployment, a systemd service file is provided (`cryptoapi.service`):

**Installation:**
```bash
# Build the executable
./build.sh

# Copy service file
sudo cp cryptoapi.service /etc/systemd/system/

# Edit service file if needed (adjust user and paths)
sudo nano /etc/systemd/system/cryptoapi.service

# Reload systemd
sudo systemctl daemon-reload

# Enable and start
sudo systemctl enable cryptoapi
sudo systemctl start cryptoapi
```

**Management:**
```bash
# Check status
sudo systemctl status cryptoapi

# View logs
sudo journalctl -u cryptoapi -f

# Restart service
sudo systemctl restart cryptoapi

# Stop service
sudo systemctl stop cryptoapi
```

**Key service features:**
- Auto-restart on failure (Restart=always)
- Auto-start on boot (enabled with systemctl enable)
- Logs sent to systemd journal
- 10 second restart delay on failure

## Gotchas & Common Issues

1. **Port 3040 in use**: Kill existing process with `kill -9 $(lsof -ti:3040)`
2. **curl not found**: Install curl with package manager (apt, brew, yum)
3. **Prices not updating**: Check internet connectivity and API endpoints
4. **Permission denied on the cache file** (default `/var/lib/cryptoapi/prices.json`): check write permissions on the directory (the server creates it with `mkdir_all` at startup)
5. **V not found**: Install Vlang from https://github.com/vlang/v
6. **Missing new currency/rate in API response**: The cache file `/var/lib/cryptoapi/prices.json` may contain old data without newly added currencies. After adding new currencies/rates to the code, either:
   - Delete the cache: `rm /var/lib/cryptoapi/prices.json` and restart
   - Wait 5 minutes for automatic update cycle
   - Restart the service: `sudo systemctl restart cryptoapi`

## Module Configuration

From `v.mod`:
```v
Module {
    name: 'cryptoapi'
    description: 'Crypto API'
    version: '1.0.0'
    license: 'MIT'
    dependencies: []
}
```

No external V module dependencies - uses only stdlib (veb, time, log, json2, toml, os).

## Testing

No formal test suite currently. Manual testing via curl:
```bash
# Test endpoint
curl http://localhost:3040/prices

# Check cache file
cat /var/lib/cryptoapi/prices.json

# Check logs (stdout/stderr from running server)
```

## Deployment Notes

- Binary output should be named `cryptoapi` (as per .gitignore)
- Cache lives in `/var/lib/cryptoapi/prices.json` by default (persistent across restarts and reboots; configurable via `prices_file`)
- Requires curl installed on deployment target
- Can run standalone without additional files
