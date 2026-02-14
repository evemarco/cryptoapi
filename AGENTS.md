# AGENTS.md

This document contains essential information for working with the cryptoapi Vlang project.

## Project Overview

A REST API server written in Vlang that provides real-time cryptocurrency prices and exchange rates. The server fetches prices from external APIs (CoinGecko for crypto, Coinbase for EUR/USD, THB/USD, and VND/USD) and updates them every 5 minutes.

**Tech Stack**: Vlang (vweb framework), JSON file-based caching, curl for HTTP requests
**Listening Port**: 3040 (configurable in `main.v:52`)
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
- `/tmp/crypto_prices.json` - cached price data (auto-generated)
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
- **Structs**: PascalCase (`App`, `PriceData`, `CoingeckoPrice`)
- **Constants**: snake_case (`update_interval`, `prices_file`)
- **Functions**: snake_case (`update_prices_loop`, `fetch_coingecko_prices`)
- **Mutable struct fields**: marked with `mut:`
- **Private functions**: no `pub` keyword
- **Public functions**: `pub` keyword

### Vlang Patterns

**Struct definitions**:
```v
struct App {
    vweb.Context
    mut:
        prices map[string]f64
        last_update time.Time
}
```

**Route handlers** (vweb framework):
```v
@['/route']
pub fn (mut app App) handler() vweb.Result {
    return app.json(data)
}
```

**JSON decoding** (V builtin):
```v
if decoded := json.decode(StructType, json_string) {
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
**Problem**: vweb creates new `App` instance per request, so in-memory state isn't shared
**Solution**: Use shared JSON file at `/tmp/crypto_prices.json` for data persistence

### HTTP Requests
**Problem**: V's HTTP module blocks on HTTPS requests
**Solution**: Use `curl` via `os.system()` in `curl_get()` function

### Price Updates
- Background goroutine updates prices every 5 minutes (`update_interval` constant)
- Fallback to static values if API fetches fail
- Updates are written to shared file immediately

## Key Constants (configurable in `main.v`)

```v
const update_interval = 5 * time.minute  // How often to fetch prices
const prices_file = '/tmp/crypto_prices.json'  // Where to cache prices
```

## API Endpoints

- `GET /` - Returns all prices (JSON)
- `GET /prices` - Returns all prices (JSON)

Response format:
```json
{
  "BTC": 69832.0,
  "BNB": 634.58,
  "XMR": 355.33,
  "DOGE": 0.102899,
  "XRP": 1.47,
  "POL": 0.111061,
  "SOL": 87.29,
  "EUR": 1.18699,
  "THB": 0.03226
}
```

## Adding New Cryptocurrencies

1. Update `fetch_coingecko_prices()` URL to include new coin IDs:
```v
url := 'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum,...&vs_currencies=usd'
```

2. Add parsing logic in `update_prices_and_write()`:
```v
if ethereum := coingecko_map["ethereum"] {
    prices["ETH"] = ethereum.usd
}
```

3. Optionally add static fallback values in the fallback block

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
    if decoded := json.decode(CoinbaseResponse, coinbase_jpy_data) {
        if usd_str := decoded.data.rates["USD"] {
            prices["JPY"] = usd_str.f64()
        }
    } else {
        log.warn("Failed to parse Coinbase JPY data")
    }
}
```

4. Add a static fallback value in the fallback block:
```v
prices["JPY"] = 0.0067  // Approximate JPY/USD rate
```

## External Dependencies

- **vweb**: V's builtin web framework (imported as `vweb`)
- **curl**: System curl binary (for HTTP requests to external APIs)
- **CoinGecko API**: https://api.coingecko.com/api/v3/simple/price
- **Coinbase API**: https://api.coinbase.com/v2/exchange-rates

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
4. **Permission denied on /tmp/**crypto_prices.json**: Check write permissions
5. **V not found**: Install Vlang from https://github.com/vlang/v
6. **Missing new currency/rate in API response**: The cache file `/tmp/crypto_prices.json` may contain old data without newly added currencies. After adding new currencies/rates to the code, either:
   - Delete the cache: `rm /tmp/crypto_prices.json` and restart
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

No external V module dependencies - uses only stdlib (vweb, time, log, json, os).

## Testing

No formal test suite currently. Manual testing via curl:
```bash
# Test endpoint
curl http://localhost:3040/prices

# Check cache file
cat /tmp/crypto_prices.json

# Check logs (stdout/stderr from running server)
```

## Deployment Notes

- Binary output should be named `cryptoapi` (as per .gitignore)
- Uses `/tmp` for caching (ensure persistence is acceptable or change path)
- Requires curl installed on deployment target
- Can run standalone without additional files
