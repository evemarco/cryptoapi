# CryptoAPI Vlang REST API

A simple REST API server written in Vlang that provides real-time cryptocurrency prices relative to the US Dollar (USD).

## Features

- **Tracked Cryptocurrencies**: XMR (Monero), BNB (Binance Coin), BTC (Bitcoin), DOGE (Dogecoin), XRP (Ripple), POL (Polygon), SOL (Solana)
- **Exchange Rates**: EUR, THB, and VND relative to USD
- **Automatic Updates**: Prices fetched every 5 minutes
- **External APIs**: CoinGecko (crypto) and Coinbase (EUR/USD, THB/USD, and VND/USD rates)
- **HTTP Server**: Listens on `0.0.0.0:3040`
- **Response Format**: JSON
- **Caching**: Shared JSON file for data persistence

## Endpoints

### `GET /` or `GET /prices`

Returns all current prices in JSON format.

**Example response:**
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
  "THB": 0.03226,
  "VND": 0.0000385
}
```

## Configuration

### Change the listening port

Modify the port number in `main.v`:

```v
vweb.run(app, 3040)  // Replace 3040 with your desired port
```

### Change the update interval

Modify the `update_interval` constant in `main.v`:

```v
const update_interval = 5 * time.minute  // 5 minutes by default
```

Other examples:
```v
const update_interval = 10 * time.minute  // 10 minutes
const update_interval = 30 * time.second  // 30 seconds
const update_interval = time.hour          // 1 hour
```

### Change tracked cryptocurrencies

Modify the CoinGecko URL in `fetch_coingecko_prices()` and add corresponding structures:

```v
fn fetch_coingecko_prices() string {
    url := 'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum,dogecoin&vs_currencies=usd'
    return curl_get(url)
}
```

Then add the parsing in `update_prices_and_write()`:

```v
if ethereum := coingecko_map["ethereum"] {
    prices["ETH"] = ethereum.usd
}
```

### Change the cache file

Modify the `prices_file` constant:

```v
const prices_file = '/tmp/crypto_prices.json'  // Default
// OR
const prices_file = './cache/prices.json'     // Local directory
```

## Building

### Prerequisites

- **Vlang** (>= 0.4.x): [Installation instructions](https://github.com/vlang/v#installing-v-from-source)
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
COPY main.v v.mod ./

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
version: '3.8'

services:
  cryptoapi:
    build: .
    ports:
      - "3040:3040"
    restart: unless-stopped
    volumes:
      - ./cache:/tmp
```

Run:

```bash
docker-compose up -d
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

The server displays logs in the terminal:
- Server initialization
- Price updates
- Any errors

## Architecture

### Why Vlang?

- **Performance**: Native compilation, comparable to C/C++
- **Simplicity**: Clear syntax, fast compilation
- **Safety**: Automatic memory management without GC
- **Rapid development**: Type inference, builtin JSON

### Problems Solved

1. **Shared state**: vweb creates a new instance per request → Using a shared JSON file
2. **HTTPS with V**: V's HTTP module blocks on HTTPS → Using `os.system()` with curl
3. **Persistence**: Data survives restarts → Cache in `/tmp/crypto_prices.json`

## Project Structure

```
cryptoapi/
├── main.v          # Main source code
├── v.mod           # Module metadata
├── .gitignore      # Files ignored by Git
├── README.md       # This file
└── cache/          # Cache directory (optional)
```

## Troubleshooting

### Server won't start

Check if port 3040 is already in use:

```bash
lsof -ti:3040
# If a process is running, kill it:
kill -9 $(lsof -ti:3040)
```

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

Check internet connectivity:

```bash
curl https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd
```

Check cache file:

```bash
cat /tmp/crypto_prices.json
```

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
