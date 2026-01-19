```md
````
# AI Pipeline — n8n + PostgreSQL  
**Test Assignment: Backend Engineer / n8n Architect**

---

## Описание проекта

Данный репозиторий содержит реализацию тестового задания по построению **Zero-Touch AI Pipeline** для обработки архитектурных 3D-рендеров.  
Система выступает в роли оркестратора и построена на базе:

- **n8n** — orchestration / state machine  
- **PostgreSQL** — хранение состояния и результатов  
- **Vision AI API** (Perplexity / OpenRouter Vision)  
- **Nano Banana API** (mock) — генерация изображений  

Реализованы **два независимых workflow**, соответствующие заданиям ТЗ.

---

## Структура репозитория

.
├── workflows/
│   ├── task1-render-analysis.json
│   └── task2-qc-retry.json
├── sql/
│   ├── schema.sql
│   └── queries.sql
└── README.md


- `workflows/*.json` — экспортированные n8n-воркфлоу  
- `sql/schema.sql` — схема БД и индексы  
- `sql/queries.sql` — SQL-запросы, используемые в воркфлоу  
- `README.md` — описание проекта и инструкции  

---

## Требуемые доступы

Для запуска необходимо настроить в n8n:

- **PostgreSQL credentials**
- **Vision API key** (Perplexity / OpenRouter)
- **WEBHOOK_BASE_URL**
- *(опционально)* Slack credentials для MANUAL_REVIEW

---

## База данных (PostgreSQL)

Используются три таблицы:

### `jobs`
Хранит состояние пайплайна.

Статусы:
- `QUEUED`
- `PROCESSING`
- `CLASSIFIED`
- `FAILED`
- `GENERATION_FAILED`
- `MANUAL_REVIEW`

---

### `renders`
Хранит входные изображения и результаты Vision-анализа.

Ключевые поля:
- `technical_tags JSONB`
- `full_analysis JSONB`
- `processing_time_sec`

---

### `generation_attempts`
Хранит историю автоповторов генерации.

Ключевые поля:
- `attempt_number`
- `parameters JSONB`
- `qc_verdict`
- `nano_banana_response JSONB`

Ограничения и индексы:
- `UNIQUE (render_id, attempt_number)`
- индекс `(render_id, attempt_number DESC)`
- GIN-индекс по `technical_tags`

Подробности — в `schema.sql`.

---

## Задание №1 — Vision Analysis (GSS-01)

### Вебхук
`POST /render-analysis`

### Входные данные
```json
{
  "event": "new_render_uploaded",
  "property_id": "magnolia_dubai_001",
  "image_url": "https://...",
  "context": {
    "location": "Dubai Downtown",
    "time_of_day": "golden_hour"
  }
}
````

### Логика workflow

1. Прием вебхука
2. Дедупликация по `(image_url + property_id)`
3. Создание `job` (`QUEUED`)
4. Создание `render`
5. Перевод `job → PROCESSING`
6. HTTP-запрос к Vision API (реальный)
7. Парсинг JSON-ответа модели
8. Обновление `renders`
9. Перевод `job → CLASSIFIED`

### Обработка ошибок

* Таймаут Vision API
* HTTP / API error
* Некорректный JSON от модели

При ошибке:

* ошибка сохраняется в `renders`
* `job.status → FAILED`
* workflow корректно завершается

---

## Задание №2 — Автоповтор (State Machine)

### Вебхук

`POST /qc-result`

### Входные данные

```json
{
  "job_id": "...",
  "render_id": "...",
  "qc_result": {
    "verdict": "FAIL",
    "reason": "...",
    "suggested_fix": "increase_structure_strength"
  }
}
```

---

## Логика State Machine

### 1. Проверка терминальных состояний

При входе проверяется `jobs.status`:

* `GENERATION_FAILED`, `MANUAL_REVIEW` → запрос игнорируется
* `PASS` (из job или qc_result) → немедленный ответ `job_passed`

Это предотвращает повторную обработку и зацикливание.

---

### 2. Подсчет попыток

```sql
SELECT COALESCE(MAX(attempt_number), 1) AS last_attempt
FROM generation_attempts
WHERE render_id = ...
```

Используются значения:

* `current_attempt = last_attempt`
* `next_attempt = last_attempt + 1`

QC-результат **апсертится в текущую попытку**, даже если записи ранее не существовало.

---

### 3. Ветвление логики

#### IF `qc_verdict = FAIL` AND `current_attempt < 3`

* вычисляются новые параметры
* создается `next_attempt` (pending)
* вызывается Nano Banana API (mock)
* сохраняется `nano_banana_response`
* `job.status → PROCESSING`
* ответ: `retry_scheduled`

#### IF `qc_verdict = FAIL` AND `current_attempt >= 3`

* `job.status → MANUAL_REVIEW`
* (опционально) Slack-алерт
* ответ: `manual_review_required`

---

### 4. Модификация параметров

Базовые параметры:

```json
{
  "structure_scale": 0.50,
  "cfg_scale": 7.5,
  "steps": 50,
  "sampler": "DPM++"
}
```

Правила:

* `increase_structure_strength` → `structure_scale += 0.10 * (next_attempt - 1)`
* `reduce_artifacts` → `cfg_scale -= 0.5 * (next_attempt - 1)`

Пример:

* Attempt 1 → 0.50
* Attempt 2 → 0.60
* Attempt 3 → 0.70
* Далее → `MANUAL_REVIEW`

generation_attemps:

| id                                   | render_id                            | attempt_number | parameters                                                           | qc_verdict | failure_reason                      | nano_banana_response | created_at                 |
|--------------------------------------|--------------------------------------|----------------|----------------------------------------------------------------------|------------|-------------------------------------|----------------------|---------------------------|
| 9823bdb7-4930-4483-81b2-9be13f6d2bee | 59177b49-b664-4cb1-8dc4-52712cadee2a | 3              | {"steps":50,"sampler":"DPM++","cfg_scale":7.5,"structure_scale":0.7} | FAIL       | Geometry distortion on window frame | {"body":{"image_id":"59177b49-b664-4cb1-8dc4-52712cadee2a","parameters":{"steps":50,"sampler":"DPM++","cfg_scale":7.5,"structure_scale":0.7}},"query":{},"params":{},"headers":{"host":"lauriegreens.app.n8n.cloud","accept":"application/json,text/html,application/xhtml+xml,application/xml,text/*;q=0.9, image/*;q=0.8, */*;q=0.7","cf-ray":"9c078a90a35fdc6e-FRA","cdn-loop":"cloudflare; loops=1; subreqs=1","cf-ew-via":"15","cf-worker":"n8n.cloud","x-real-ip":"20.218.174.11","cf-visitor":"{\"scheme\":\"https\"}","user-agent":"axios/1.12.0","cf-ipcountry":"DE","content-type":"application/json","x-is-trusted":"yes","content-length":"133","accept-encoding":"gzip, br","x-forwarded-for":"20.218.174.11, 172.71.144.47","cf-connecting-ip":"20.218.174.11","x-forwarded-host":"lauriegreens.app.n8n.cloud","x-forwarded-port":"443","x-forwarded-proto":"https","x-forwarded-server":"traefik-prod-users-gwc-76-b4b8c88f-zkxqz"},"webhookUrl":"https://lauriegreens.app.n8n.cloud/webhook/nano-banana-mock","executionMode":"production"} | 2026-01-19 15:59:47.235031 |
| 464d453f-d0a2-4ac1-91ea-ae4723192dc0 | 59177b49-b664-4cb1-8dc4-52712cadee2a | 2              | {"steps":50,"sampler":"DPM++","cfg_scale":7.5,"structure_scale":0.6} | FAIL       | Geometry distortion on window frame | {"body":{"image_id":"59177b49-b664-4cb1-8dc4-52712cadee2a","parameters":{"steps":50,"sampler":"DPM++","cfg_scale":7.5,"structure_scale":0.6}},"query":{},"params":{},"headers":{"host":"lauriegreens.app.n8n.cloud","accept":"application/json,text/html,application/xhtml+xml,application/xml,text/*;q=0.9, image/*;q=0.8, */*;q=0.7","cf-ray":"9c078a6b73e2db12-FRA","cdn-loop":"cloudflare; loops=1; subreqs=1","cf-ew-via":"15","cf-worker":"n8n.cloud","x-real-ip":"20.218.174.11","cf-visitor":"{\"scheme\":\"https\"}","user-agent":"axios/1.12.0","cf-ipcountry":"DE","content-type":"application/json","x-is-trusted":"yes","content-length":"133","accept-encoding":"gzip, br","x-forwarded-for":"20.218.174.11, 172.71.148.159","cf-connecting-ip":"20.218.174.11","x-forwarded-host":"lauriegreens.app.n8n.cloud","x-forwarded-port":"443","x-forwarded-proto":"https","x-forwarded-server":"traefik-prod-users-gwc-76-b4b8c88f-zkxqz"},"webhookUrl":"https://lauriegreens.app.n8n.cloud/webhook/nano-banana-mock","executionMode":"production"} | 2026-01-19 15:59:41.277417 |
| 1f2964fe-5e1a-48a5-8381-32930dcc4a7a | 59177b49-b664-4cb1-8dc4-52712cadee2a | 1              | null                                                                 | FAIL       | Geometry distortion on window frame | null                 | 2026-01-19 15:59:41.21922  |


jobs:
| id                                   | property_id          | status        | batch_id | created_at                 | updated_at                 |
| ------------------------------------ | -------------------- | ------------- | -------- | -------------------------- | -------------------------- |
| 9ad61b7e-f47d-4238-8031-00230dc28bd3 | magnolia_dubai_03001 | MANUAL_REVIEW | null     | 2026-01-19 15:13:32.212252 | 2026-01-19 15:59:50.284416 |

---

## Предотвращение бесконечных циклов

* HTTP-node Nano Banana с timeout и ограничением ретраев
* `onError: continueErrorOutput`
* при технической ошибке:

  * запись ошибки в БД
  * `job.status → GENERATION_FAILED`
* входящие QC-вызовы для таких job-ов игнорируются

---

## Противоречия в ТЗ и принятые решения

### 1. Когда ставить MANUAL_REVIEW

В ТЗ указано одновременно:

* третья попытка может быть `PASS` или `MANUAL_REVIEW`
* `attempt_number >= 3 → MANUAL_REVIEW`

**Решение:**
Третья попытка выполняется.
`MANUAL_REVIEW` устанавливается **только после FAIL на attempt ≥ 3**.

---

### 2. Где создается первая попытка

ТЗ не определяет, где создается `attempt_number = 1`.

**Решение:**
QC-результат апсертится в `current_attempt`.
Это позволяет корректно работать даже если первая генерация выполнена вне данного workflow.

---

### 3. Обработка PASS

ТЗ не требует сохранять PASS-попытки.

**Решение:**
PASS обрабатывается на уровне роутера и завершает workflow без создания новой попытки.

---

## Запуск проекта

1. Импортировать workflow из папки `workflows/` в n8n
2. Настроить credentials
3. Создать таблицы из `sql/schema.sql`
4. Ознакомиться с `sql/queries.sql`
5. Вызвать:

   * `/render-analysis`
   * `/qc-result`

---

## Итог

Проект демонстрирует:

* реальную интеграцию Vision AI
* state machine автоповторов
* использование JSONB и индексов
* обработку ошибок и дедупликацию
* осознанное разрешение противоречий ТЗ

Готово для проверки и расширения.

