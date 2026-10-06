# CryptoAPI Vlang REST API

A simple REST API server written in Vlang that provides real-time cryptocurrency prices and fiat exchange rates relative to the US Dollar (USD).

## Features

- **Tracked Cryptocurrencies**: BTC, ETH, XMR (Monero), BNB, SOL, XRP, DOGE, POL
- **Exchange Rates**: EUR (USD per 1 EUR), THB and VND (fiat per 1 USD)
- **Automatic Updates**: Prices fetched every 5 minutes by default (configurable)
- **External APIs**: Coinbase (crypto USD prices + fiat rates) and Kraken (XMR only)
- **Resilience**: On a failed or incomplete fetch, the last known prices are served instead of stale hard-coded values
- **Grist Sync**: Prices pushed to a Grist table after every successful fetch
- **HTTP Server**: Listens on `0.0.0.0:3040`
- **Response Format**: JSON
- **Caching**: Persistent JSON cache file (last known values survive restarts and reboots)

## Endpoints

### `GET /` or `GET /prices`

Returns all current prices with metadata (both routes are identical).

**Example response:**
```json
{
  "prices": {
    "BTC": 85601.37,
    "BNB": 781.33,
    "XMR": 561.93,
    "DOGE": 0.09486,
    "XRP": 1.5006,
    "POL": 0.10915,
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
- `prices`: Map of currency symbols to values (see semantics below)
- `last_update`: Timestamp of the last update attempt (successful or not)
- `last_success_update`: Timestamp of the last successful API fetch — compare it with `last_update` to detect a degraded feed

## Data Sources

| Source | Used for | Endpoint |
|---|---|---|
| Coinbase exchange-rates | Crypto USD prices (BTC, ETH, SOL, XRP, DOGE, BNB, POL) and fiat rates (EUR, THB, VND) | `https://api.coinbase.com/v2/exchange-rates?currency=USD` and `?currency=EUR` |
| Kraken ticker | XMR (delisted from Coinbase) | `https://api.kraken.com/0/public/Ticker?pair=XMRUSD` |

**Price semantics** (directions follow the live fetch code):

- Crypto: Coinbase returns units of crypto per 1 USD; the value is inverted, so `prices["BTC"]` is USD per 1 BTC.
- `EUR`: USD per 1 EUR (e.g. `1.1217`).
- `THB`, `VND`: units of fiat per 1 USD (e.g. `33.664` THB per USD), derived from the EUR-base Coinbase response.
- XMR comes from Kraken's last trade price (`c[0]`).
- All values are rounded to 6 significant digits, clamped to 2–6 decimals, to remove float noise from the inversions.

### Why Coinbase + Kraken instead of CoinGecko?

The server runs in a datacenter, and CoinGecko's public REST API started rejecting requests coming from it (HTTP 403 error pages, which the old code silently parsed as broken JSON). The sources were therefore switched to Coinbase (crypto + fiat) and Kraken (XMR, which Coinbase no longer lists). HTTP errors are now detected and logged (`curl -fsS` with exit-code checks) instead of being parsed as data.

## Update & Fallback Behavior

- A background goroutine refreshes prices every `update_interval_seconds` (default `300`), plus once at startup.
- A fetch cycle counts as **successful** only when every symbol in `crypto_symbols` (8 coins) was freshly fetched. Fiat rates are secondary and may carry over from the last known values.
- **On failure or incomplete fetch**: the last known values from the cache file are kept and re-served; a warning is logged.
- **Static fallback values** (hard-coded in `main.v`) are used only before the first successful fetch ever (missing or unreadable cache file). Live updates never reset to them.
- **Grist is updated only on a fully successful fetch.**

## Grist Integration

After each successful fetch, the server sends a PATCH with 8 records to the Grist `Coins` table (`grist_api_url` in `config.toml`):

| Record | coin | fiat | fiat_usd |
|---|---|---|---|
| 1 | BTC | EUR | 1 / EUR rate |
| 2 | BNB | THB | THB rate |
| 3 | XMR | VND | VND rate |
| 4 | DOGE | USD | 1.0 |
| 5–8 | XRP, POL, SOL, ETH | null | 0.0 |

Every record carries `last_success_update`. Required columns in the Grist table: `coin`, `usd`, `fiat`, `fiat_usd`, `last_success_update`. A failed Grist call is logged but does not affect the prices cache.

## Configuration

Runtime settings live in `config.toml` (in the working directory) — edit and restart the service, no recompile needed. Any missing key falls back to its default value; if the file is missing entirely, all defaults are used.

```toml
port = 3040                                  # HTTP listen port
update_interval_seconds = 300                # Price fetch interval, in seconds
prices_file = "/var/lib/cryptoapi/prices.json" # Price cache file (persistent, kept across restarts)
grist_api_url = "https://..."                # Grist API endpoint (Coins table)
grist_bearer_token = "your_token_here"       # Grist API authentication token
```

### Change the listening port

Edit `port` in `config.toml` and restart the service.

### Change the update interval

Edit `update_interval_seconds` in `config.toml` (e.g. `600` for 10 minutes, `3600` for 1 hour) and restart the service.

### Change tracked cryptocurrencies

Prices come from two sources: Coinbase exchange-rates (all cryptos except XMR, delisted there) and Kraken (XMR only). To track another crypto listed on Coinbase, add its ticker to the `coinbase_symbols` const in `main.v`:

```v
const coinbase_symbols = ['BTC', 'ETH', 'SOL', 'XRP', 'DOGE', 'BNB', 'POL']
```

A fetch cycle only counts as successful (and is pushed to Grist) when every symbol in `crypto_symbols` was freshly fetched, so keep both consts in sync when adding or removing a coin.

### Change the cache file

Edit `prices_file` in `config.toml` (e.g. `prices_file = "./cache/prices.json"` for a local directory) and restart the service.

## Building

### Prerequisites

- **Vlang** (>= 0.5.x): [Installation instructions](https://github.com/vlang/v#installing-v-from-source)
- **curl**: For fetching external data

### Build and run in development mode

```bash
v run main.v
```

### Build in release mode (optimized)

```bash
v -prod run main.v
```

### Build as a standalone executable

**Using the build script (recommended):**
```bash
./build.sh
./cryptoapi
```

**Manual build:**
```bash
v -prod -o cryptoapi main.v
./cryptoapi
```

## Deployment

### Local deployment (Linux/Mac)

```bash
# Build
./build.sh

# Run in background
./cryptoapi &

# Verify server is running
curl http://localhost:3040/prices
```

### Deployment with systemd (Linux - Recommended)

**Quick setup using provided service file:**

```bash
# Build the executable
./build.sh

# Copy service file to systemd
sudo cp cryptoapi.service /etc/systemd/system/

# Update the service file if needed (adjust paths/user):
sudo nano /etc/systemd/system/cryptoapi.service

# Reload systemd and enable service
sudo systemctl daemon-reload
sudo systemctl enable cryptoapi

# Start the service
sudo systemctl start cryptoapi

# Check service status
sudo systemctl status cryptoapi

# View logs
sudo journalctl -u cryptoapi -f
```

**Service management commands:**
```bash
# Stop the service
sudo systemctl stop cryptoapi

# Restart the service
sudo systemctl restart cryptoapi

# Disable service from auto-start
sudo systemctl disable cryptoapi
```

**The service file (`cryptoapi.service`)** is already provided in the repository. You may need to adjust:
- `User=root` - Set to your system user if needed
- `WorkingDirectory=/data/cryptoapi` - Path to the project directory
- `ExecStart=/data/cryptoapi/cryptoapi` - Path to the executable

### Deployment with Docker

Create a `Dockerfile`:

```dockerfile
FROM vlang/v:latest

WORKDIR /app
COPY main.v v.mod config.toml ./

RUN v -prod -o cryptoapi main.v

EXPOSE 3040

CMD ["./cryptoapi"]
```

Build and run:

```bash
docker build -t cryptoapi .
docker run -d -p 3040:3040 --name cryptoapi cryptoapi
```

### Deployment with Docker Compose

Create a `docker-compose.yml`:

```yaml
services:
  cryptoapi:
    build: .
    ports:
      - "3040:3040"
    restart: unless-stopped
    volumes:
      - cryptoapi-data:/var/lib/cryptoapi   # persistent price cache

volumes:
  cryptoapi-data:
```

Run:

```bash
docker compose up -d
```

### Deployment on VPS (e.g., DigitalOcean, Hetzner)

```bash
# On your local machine
scp cryptoapi user@vps-ip:/home/user/

# On the VPS
ssh user@vps-ip
cd /home/user
chmod +x cryptoapi
sudo ./cryptoapi &

# Optional: configure nginx as reverse proxy
```

### Deployment with process manager (PM2)

Install PM2:

```bash
npm install -g pm2
```

Start the application:

```bash
pm2 start cryptoapi --name cryptoapi
pm2 save
pm2 startup
```

## Verification

### Test the server

```bash
curl http://localhost:3040/prices
```

### Test with verbose curl

```bash
curl -i http://localhost:3040/
```

### Test with httpie

```bash
http GET localhost:3040/prices
```

### Monitor logs

Run standalone, logs go to the terminal. Under systemd:

```bash
sudo journalctl -u cryptoapi -f
```

You should see price updates every 5 minutes, and warnings like `API fetch incomplete` or `keeping last known prices` when a source fails.

### Check the cache

```bash
cat /var/lib/cryptoapi/prices.json
```

## Architecture

### Why Vlang?

- **Performance**: Native compilation, comparable to C/C++
- **Simplicity**: Clear syntax, fast compilation
- **Safety**: Automatic memory management without GC
- **Rapid development**: Type inference, builtin JSON

### Problems Solved

1. **Shared state**: veb handlers run per-request → price state is re-read from a shared JSON file on each request
2. **HTTPS with V**: V's HTTP module blocks on HTTPS → Using `os.system()` with curl (`-fsS` so HTTP errors fail loudly)
3. **Persistence**: Last known prices survive restarts and reboots → Cache in `/var/lib/cryptoapi/prices.json`

## Project Structure

```
cryptoapi/
├── main.v            # Main source code (single-file architecture)
├── v.mod             # Module metadata
├── build.sh          # Production build script (creates ./cryptoapi)
├── config.toml       # Runtime configuration (port, interval, cache path, Grist)
├── cryptoapi.service # systemd service file
├── .gitignore        # Files ignored by Git
├── README.md         # This file
└── AGENTS.md         # Notes for AI coding agents
```

Runtime files (not in the repo):
- `/var/lib/cryptoapi/prices.json` — persistent price cache, created automatically

## Troubleshooting

### Server won't start

Check if port 3040 is already in use:

```bash
lsof -ti:3040
# If a process is running, kill it:
kill -9 $(lsof -ti:3040)
```

A malformed `config.toml` also aborts startup with an error — check the log output.

### Error "curl not found"

Install curl:

```bash
# Ubuntu/Debian
sudo apt-get install curl

# macOS
brew install curl

# CentOS/RHEL
sudo yum install curl
```

### Prices not updating

Check connectivity to the price sources:

```bash
curl 'https://api.coinbase.com/v2/exchange-rates?currency=USD'
curl 'https://api.kraken.com/0/public/Ticker?pair=XMRUSD'
```

Check the cache file:

```bash
cat /var/lib/cryptoapi/prices.json
```

If `last_success_update` is older than `last_update`, at least one source is failing — check the logs for the failing endpoint (curl exit codes are logged with the error output).

### Error "v: command not found"

Install Vlang:

```bash
git clone https://github.com/vlang/v
cd v
make
sudo ./v symlink
```

## License

MIT License - Adapt as needed.

## Contributing

Contributions are welcome! Feel free to open an issue or pull request.
