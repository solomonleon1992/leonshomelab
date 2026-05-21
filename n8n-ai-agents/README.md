# n8n AI Agents

## Overview
AI agent automation platform running n8n with Claude API integration and local Ollama LLM. Deployed as a standalone Ubuntu Server for autonomous workflow execution and business process automation.

## Server Details
| Configuration | Value |
|---|---|
| **Hostname** | n8n-ai-stack |
| **OS** | Ubuntu Server 22.04 LTS (minimized) |
| **IP Address** | 192.168.0.28 |
| **CPU** | 4 cores |
| **RAM** | 8GB |
| **Disk** | 64GB |
| **Platform** | Bare metal / Separate machine |

## Stack Architecture
All services run as Docker containers managed via Docker Compose:

| Service | Container | Port | Purpose |
|---|---|---|---|
| n8n | n8nio/n8n:latest | 5678 | Workflow automation platform |
| PostgreSQL | postgres:15 | 5432 | n8n database backend |
| Ollama | ollama/ollama | 11434 | Local LLM inference server |

## Docker Compose Configuration
Located at: `~/n8n-stack/docker-compose.yml`

### Key Environment Variables
- `N8N_SECURE_COOKIE=false` - Required for HTTP access on local network
- `N8N_ENCRYPTION_KEY` - Used for credential encryption
- `DB_TYPE=postgresdb` - Production-grade database backend
- PostgreSQL credentials stored in compose file

### Data Persistence
All data persists across container restarts via Docker volumes:
- `n8n_data` - Workflow definitions and execution history
- `postgres_data` - Database storage
- `ollama_data` - Downloaded LLM models

## Installed Models
| Model | Size | Provider | Purpose |
|---|---|---|---|
| Claude Sonnet 4.6 | API | Anthropic | Complex reasoning and content generation |
| nemotron-mini | 4GB | Ollama (local) | Fast local inference for simple tasks |

## Configured Credentials
| Service | Type | Purpose |
|---|---|---|
| Anthropic API | API Key | Claude Sonnet 4.6 access |
| Ollama | Base URL | Local LLM connection (http://ollama:11434) |
| SerpAPI | API Key | eBay/web search API (250 free searches/month) |
| Telegram | Bot Token | Terry bot notifications |

## Active Workflows

### Terry - Laptop Deal Finder
**Schedule:** Every 6 hours  
**Purpose:** Automated eBay laptop deal detection and notification

**Workflow:**
1. **Schedule Trigger** - Runs every 6 hours (0 */6 * * *)
2. **SerpAPI eBay Search** - Searches for laptops under $300
   - Query: `laptop -parts -screen -battery -keyboard`
   - Max price: $300
   - Sort: Price highest first
   - Results per page: 50
3. **AI Agent (Claude Sonnet 4.6)** - Analyzes listings and filters:
   - Removes laptop accessories (backpacks, cases, chargers)
   - Removes parts-only/broken listings
   - Removes obvious scams and suspicious sellers
   - Applies deal evaluation criteria
4. **Telegram Notification** - Sends formatted results to personal Telegram via Terry bot
   - Includes: title, price, condition, link, assessment

**Monthly Cost Estimate:**
- SerpAPI: $0 (free tier, ~120 searches/month)
- Claude API: ~$3.60/month (~120 searches × $0.03 per search)
- Telegram: $0 (free)
- **Total: ~$3.60/month**

## Access
- **n8n Dashboard:** http://192.168.0.28:5678
- **Account:** leonshomelab.updates@gmail.com
- **License:** Free tier with activation key

## Installation Steps (for reference)

### 1. Docker Installation
```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
newgrp docker
```

### 2. Deploy Stack
```bash
mkdir ~/n8n-stack && cd ~/n8n-stack
nano docker-compose.yml  # paste configuration
docker compose up -d
```

### 3. Install Ollama Model
```bash
docker exec -it ollama ollama pull nemotron-mini
docker exec -it ollama ollama list  # verify
```

### 4. Configure n8n
1. Access http://192.168.0.28:5678
2. Create admin account
3. Add credentials (Anthropic, SerpAPI, Telegram, Ollama)
4. Import or build workflows

## Troubleshooting

### Secure Cookie Error (can't access n8n dashboard)
**Symptom:** "Your n8n server is configured to use a secure cookie, however you are either visiting this via an insecure URL, or using Safari."

**Fix:** Add to docker-compose.yml under n8n environment:
```yaml
- N8N_SECURE_COOKIE=false
```
Then restart: `docker compose restart n8n`

### Container Name Conflict
**Symptom:** "The container name '/ollama' is already in use"

**Fix:** Remove old containers before redeploying:
```bash
docker stop n8n n8n-postgres ollama
docker rm n8n n8n-postgres ollama
docker compose up -d
```

### Ollama Connection Failed in n8n
**Issue:** n8n can't reach Ollama at localhost

**Fix:** Use Docker service name instead:
- Base URL: `http://ollama:11434` (not localhost or 127.0.0.1)
- Docker Compose creates an internal network where containers resolve each other by service name

## Future Planned Agents
- **Listing Generator** - Auto-generate optimized eBay/Facebook Marketplace listings
- **Homelab Monitor** - Wazuh alert aggregation and notification
- **Log Analyzer** - Pattern detection in Proxmox/Docker logs
- **Resource Optimizer** - Automated VM resource adjustment based on usage

## Security Notes
- n8n runs over HTTP (not HTTPS) - acceptable for internal network only
- Never expose port 5678 to the internet without proper authentication
- API keys stored encrypted in PostgreSQL via N8N_ENCRYPTION_KEY
- Telegram bot token grants full access to send messages - keep secure
