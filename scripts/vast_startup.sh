#!/bin/bash
# =============================================================================
# Vast.ai Startup Script — Website Generation System
# Образ: pytorch/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
# GPU: 2x (tensor-parallel-size 2)
# =============================================================================

set -e
WORKSPACE=/workspace
LOG_DIR=$WORKSPACE/logs
mkdir -p $LOG_DIR $WORKSPACE/zoo
STARTUP_LOG=$LOG_DIR/startup.log
exec > >(tee -a "$STARTUP_LOG") 2>&1

# =============================================================================
# ПОДХВАТИТЬ ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ ИЗ VAST.AI TEMPLATE
# =============================================================================
# Сначала пробуем вытянуть из PID 1 (Vast часто кладет env туда)
> /etc/webgen.env
if [ -r /proc/1/environ ]; then
    tr '\0' '\n' </proc/1/environ | grep -E 'STITCH_API_KEY|HF_TOKEN' > /etc/webgen.env || true
fi
# Фоллбек: берем из текущего окружения
env | grep -E 'STITCH_API_KEY|HF_TOKEN' >> /etc/webgen.env || true

set -a
source /etc/webgen.env 2>/dev/null || true
set +a

# Проверка обязательных переменных
if [ -z "$STITCH_API_KEY" ]; then
    echo "ERROR: STITCH_API_KEY is not set. Add it to Vast.ai environment variables."
    exit 1
fi

echo "========================================="
echo "  STARTING WEBGEN SETUP"
echo "========================================="

# =============================================================================
# 1. СИСТЕМНЫЕ ЗАВИСИМОСТИ
# =============================================================================
echo "[1/7] Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq curl git build-essential adduser

# =============================================================================
# 2. PYTHON ЗАВИСИМОСТИ
# =============================================================================
echo "[2/7] Installing Python dependencies..."
export PIP_BREAK_SYSTEM_PACKAGES=1
python3 -m pip install -q -U --ignore-installed setuptools numpy
python3 -m pip install -q -U \
    fastapi \
    uvicorn[standard] \
    aiofiles \
    requests \
    pydantic \
    openai

# =============================================================================
# 3. УСТАНОВКА VLLM
# =============================================================================
echo "[3/7] Installing vLLM..."
pip install -q -U vllm

# =============================================================================
# 4. УСТАНОВКА TRANSFORMERS (последняя из git)
# =============================================================================
echo "[4/7] Installing latest transformers..."
pip install -q -U git+https://github.com/huggingface/transformers.git
pip install -q -U tokenizers accelerate

# =============================================================================
# 5. СОЗДАНИЕ DEV ПОЛЬЗОВАТЕЛЯ И УСТАНОВКА NODE / CLAUDE CODE
# =============================================================================
echo "[5/7] Creating dev user and installing Node.js + Claude Code..."

# Создаём пользователя dev если не существует
if ! id "dev" &>/dev/null; then
    adduser --disabled-password --gecos "" dev
fi
chown -R dev:dev $WORKSPACE

# Устанавливаем Node.js 24 и npm-пакеты от имени dev
su - dev -c '
    export NVM_DIR="$HOME/.nvm"
    unset NVM_DIR
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm install 24
    nvm use 24
    npm install -g @anthropic-ai/claude-code
    npm install -g @musistudio/claude-code-router
    echo "Node $(node -v), npm $(npm -v)"
'

# =============================================================================
# 6. КОНФИГУРАЦИЯ CLAUDE CODE ROUTER
# =============================================================================
echo "[6/7] Configuring claude-code-router..."

mkdir -p /home/dev/.claude-code-router/

cat > /home/dev/.claude-code-router/config.json << EOF
{
  "LOG": true,
  "API_TIMEOUT_MS": 600000,
  "NON_INTERACTIVE_MODE": false,
  "PROXY_URL": "",
  "APIKEY": "",

  "transformers": [],

  "Providers": [
    {
      "name": "local_vllm",
      "api_base_url": "http://localhost:8000/v1/chat/completions",
      "api_key": "dummy",
      "models": ["glm-4.7-flash"]
    }
  ],
  "Router": {
    "default": "local_vllm,glm-4.7-flash",
    "background": "local_vllm,glm-4.7-flash",
    "think": "local_vllm,glm-4.7-flash",
    "longContext": "local_vllm,glm-4.7-flash",
    "longContextThreshold": 60000,
    "webSearch": "local_vllm,glm-4.7-flash"
  }
}
EOF

chown -R dev:dev /home/dev/.claude-code-router/

# =============================================================================
# 7. УСТАНОВКА STITCH MCP (запускается от dev)
# =============================================================================
echo "[7/7] Installing Stitch MCP server..."

su - dev -c "
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
    claude mcp add stitch \
        --transport http \
        https://stitch.googleapis.com/mcp \
        --header \"X-Goog-Api-Key: ${STITCH_API_KEY}\" \
        -s user
"

# =============================================================================
# КЛОНИРОВАНИЕ webgen_template И webgen.py ИЗ GITHUB
# =============================================================================
echo "[setup] Cloning webgen_template from GitHub..."

cd $WORKSPACE
rm -rf webgen_template
for i in 1 2 3; do
    git clone https://github.com/greenbutton75/SiteTemplate.git webgen_template && break
    echo "Git clone failed (attempt $i). Retrying in 5s..."
    sleep 5
done
if [ ! -d "$WORKSPACE/webgen_template" ]; then
    echo "ERROR: Failed to clone webgen_template."
    exit 1
fi
chown -R dev:dev $WORKSPACE/webgen_template
cp $WORKSPACE/webgen_template/webgen.py $WORKSPACE/webgen.py
chown dev:dev $WORKSPACE/webgen.py

echo "[setup] webgen_template ready."

# =============================================================================
# ЗАПУСК vLLM В ФОНЕ
# =============================================================================
echo "[run] Starting vLLM server (GLM-4.7-Flash, 2 GPUs)..."

HF_HOME="$WORKSPACE/models/" nohup vllm serve zai-org/GLM-4.7-Flash \
    --max-model-len 8192 \
    --gpu-memory-utilization 0.95 \
    --tensor-parallel-size 2 \
    --disable-custom-all-reduce \
    --enforce-eager \
    --tool-call-parser glm47 \
    --reasoning-parser glm45 \
    --enable-auto-tool-choice \
    --served-model-name glm-4.7-flash \
    --port 8000 \
    > $LOG_DIR/vllm.log 2>&1 &

VLLM_PID=$!
echo "vLLM started with PID $VLLM_PID"

# =============================================================================
# ЖДЁМ ПОКА vLLM ПОДНИМЕТСЯ
# =============================================================================
echo "[wait] Waiting for vLLM to be ready..."
for i in $(seq 1 120); do
    if curl -s http://localhost:8000/health > /dev/null 2>&1; then
        echo "vLLM is ready!"
        break
    fi
    echo "  ... waiting ($i/120)"
    sleep 5
done

# =============================================================================
# ЗАПУСК FASTAPI СЕРВЕРА
# =============================================================================
echo "[run] Starting webgen FastAPI server on port 6000..."

nohup uvicorn webgen:app \
    --host 0.0.0.0 \
    --port 6000 \
    --workers 4 \
    > $LOG_DIR/webgen.log 2>&1 &

WEBGEN_PID=$!
echo "WebGen API started with PID $WEBGEN_PID"

# =============================================================================
# ФИНАЛЬНЫЙ СТАТУС
# =============================================================================
echo ""
echo "========================================="
echo "  SETUP COMPLETE"
echo "========================================="
echo "  vLLM API:    http://localhost:8000/v1"
echo "  WebGen API:  http://localhost:6000"
echo ""
echo "  Endpoints:"
echo "    POST   /start          — запустить генерацию"
echo "    GET    /status/{id}    — проверить статус"
echo "    GET    /download/{id}  — скачать zip"
echo "    DELETE /delete/{id}    — удалить сайт с диска"
echo ""
echo "  Logs:"
echo "    vLLM:   $LOG_DIR/vllm.log"
echo "    WebGen: $LOG_DIR/webgen.log"
echo ""
echo "  Env vars (задать в Vast.ai перед запуском):"
echo "    STITCH_API_KEY — ключ для Google Stitch MCP"
echo "    HF_TOKEN       — если модель приватная (опционально)"
echo "========================================="
