# WebGen (Vast.ai)

Сервис генерации лендингов на базе vLLM + GLM-4.7-Flash и FastAPI API. Предназначен для запуска на Vast.ai инстансе и получения готового `index.html` по данным со скрейпа (snapshot).

**Репозиторий** содержит:
- `webgen.py` — FastAPI сервис (эндпоинты `/start`, `/status`, `/download`, `/delete`).
- `scripts/vast_startup.sh` — полный startup-скрипт для Vast.ai.
- `index.html`, `task.txt` — шаблон стартовой страницы и промпт/инструкция.

## Архитектура

Компоненты:
- **vLLM**: локальный сервер модели `zai-org/GLM-4.7-Flash` (порт `8000`).
- **WebGen API**: FastAPI сервис (порт `6000`), который:
  - создаёт рабочую директорию сайта;
  - сохраняет snapshot в `.md` файлы;
  - запускает `ccr code` (Claude Code Router) под пользователем `dev`;
  - отдаёт результат как ZIP с **только** `index.html`.
- **Claude Code Router (ccr)**: интеграция с локальным vLLM и Stitch MCP.
- **Stitch MCP**: провайдер данных (используется токен `STITCH_API_KEY`).

Поток:
1. Клиент отправляет `snapshot` на `/start`.
2. WebGen создаёт `website_N` и запускает `ccr` в фоне.
3. Клиент опрашивает `/status/{id}` до `done`.
4. Клиент скачивает `/download/{id}` (ZIP с `index.html`).

Если snapshot слишком большой, он будет автоматически обрезан, а предупреждение вернётся в `status` (поле `warning`) и будет записано в `snapshot_truncated.txt`.

## Развёртывание на Vast.ai

В Vast.ai **onstart** должен быть коротким (лимит 2048). Используйте такой:

```bash
#!/bin/bash
set -e

command -v curl >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq curl)

URL="https://raw.githubusercontent.com/greenbutton75/SiteTemplate/main/scripts/vast_startup.sh?ts=$(date +%s)"
curl -fsSL -H "Cache-Control: no-cache" -H "Pragma: no-cache" "$URL" -o /tmp/vast_startup.sh
chmod +x /tmp/vast_startup.sh
exec /tmp/vast_startup.sh
```

### Переменные окружения (Vast Template)

Обязательно:
- `STITCH_API_KEY`

Опционально:
- `HF_TOKEN` (ускоряет скачивание моделей из HuggingFace)
- `VLLM_MAX_MODEL_LEN` (по умолчанию `8192`)
- `VLLM_GPU_MEMORY_UTILIZATION` (по умолчанию `0.95`)
- `SNAPSHOT_MAX_CHARS` (жёсткий лимит длины snapshot в символах)
- `SNAPSHOT_CHARS_PER_TOKEN` (оценка char/token, по умолчанию `2.0`; используется для авто-лимита)

**Важно:** Vast кладёт env в процесс PID 1, поэтому в `vast_startup.sh` идёт чтение из `/proc/1/environ`.

## Локальные порты

- `8000` — vLLM (`/health`)
- `6000` — WebGen (`/docs`, `/start`, `/status/{id}`, `/download/{id}`, `/delete/{id}`)

## Использование API

Запуск генерации:

```bash
curl -X POST http://<host>:6000/start \
  -H "Content-Type: application/json" \
  -d '{"snapshot": "Source: https://example.com\n..."}'
```

Проверка статуса:

```bash
curl http://<host>:6000/status/website_1
```

Скачать результат (ZIP с `index.html`):

```bash
curl -o website_1.zip http://<host>:6000/download/website_1
```

## Пример клиента (Python)

Пример `use_service.py`:

```python
import time
from pathlib import Path

import requests

BASE_URL = "http://<host>:6000"

def read_snapshot_text(snapshot_path: str) -> str:
    return Path(snapshot_path).read_text(encoding="utf-8")

snapshot_text = read_snapshot_text(r"D:\Work\ML\Rix_sites\SiteSnpashot\out-text\www.flexibleplan.com\snapshot.md")

job = requests.post(f"{BASE_URL}/start", json={"snapshot": snapshot_text})
job.raise_for_status()

website_id = job.json()["website_id"]
print(f"Job started: {website_id}")

while True:
    status = requests.get(f"{BASE_URL}/status/{website_id}").json()
    print(f"Status: {status['status']}")
    if status.get("warning"):
        print(f"Warning: {status['warning']}")
    if status["status"] == "done":
        break
    time.sleep(10)

response = requests.get(f"{BASE_URL}/download/{website_id}")
response.raise_for_status()

with open(f"{website_id}.zip", "wb") as f:
    f.write(response.content)

print(f"Downloaded: {website_id}.zip")
```

## Логи

- `vLLM`: `/workspace/logs/vllm.log`
- `WebGen`: `/workspace/logs/webgen.log`
- `Startup`: `/workspace/logs/startup.log`

## Известные нюансы

- `max-model-len` по умолчанию 8192. Попытка выставить 131072 приводит к ошибке KV cache. Если хотите увеличить, подбирайте значения постепенно.
- Если `/download` возвращает лишние файлы, убедитесь, что в `webgen.py` функция `zip_directory_to_bytes` оставляет только `index.html`.
- Если `STITCH_API_KEY` не виден в интерактивной сессии — это нормально. Скрипт берёт его из `/proc/1/environ`.

## Быстрая проверка после старта

```bash
curl -i http://localhost:8000/health
curl -i http://localhost:6000/docs
```
