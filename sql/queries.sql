-- ============================================================
-- queries.sql
-- Набор SQL-запросов, используемых в n8n воркфлоу (задание 1 и 2)
-- ============================================================
-- Примечания:
--  - Все запросы приведены в формате с query parameters ($1, $2, ...)
--  - Комментарии на русском для удобства ревью
-- ============================================================



-- ============================================================
-- ЗАДАНИЕ 1: Vision Analysis (render-analysis webhook)
-- ============================================================

-- 1) Дедупликация: проверяем, есть ли уже render для (image_url + property_id)
SELECT
  r.id   AS render_id,
  r.job_id,
  j.status,
  j.property_id
FROM goodini.renders r
JOIN goodini.jobs j ON j.id = r.job_id
WHERE
  r.source_image_url = $1
  AND j.property_id = $2
ORDER BY r.created_at DESC
LIMIT 1;

-- Query params:
--  $1 = image_url
--  $2 = property_id


-- 2) Создаем job в статусе QUEUED
INSERT INTO goodini.jobs (property_id, status)
VALUES ($1, 'QUEUED')
RETURNING id, property_id, status, created_at;

-- Query params:
--  $1 = property_id


-- 3) Создаем render, привязываем к job и сохраняем source_image_url
INSERT INTO goodini.renders (job_id, source_image_url)
VALUES ($1::uuid, $2)
RETURNING id;

-- Query params:
--  $1 = job_id
--  $2 = image_url


-- 4) Переводим job в статус PROCESSING перед запросом в Vision API
UPDATE goodini.jobs
SET
  status = 'PROCESSING',
  updated_at = NOW()
WHERE id = $1::uuid;

-- Query params:
--  $1 = job_id


-- 5) Успешный результат анализа: обновляем render (shot/confidence/prompt/tags/motion/full_analysis)
UPDATE goodini.renders
SET
  detected_shot_type = $1,
  confidence = $2,
  generated_prompt = $3,
  technical_tags = $4::jsonb,
  motion_recommendation = $5,
  full_analysis = $6::jsonb,
  processing_time_sec = $7,
  error_message = NULL
WHERE id = $8::uuid;

-- Query params:
--  $1 = detected_shot_type
--  $2 = confidence
--  $3 = generated_prompt
--  $4 = JSON.stringify(technical_tags)
--  $5 = motion_recommendation
--  $6 = JSON.stringify(full_analysis)
--  $7 = processing_time_sec
--  $8 = render_id


-- 6) Если Vision API упал: пишем ошибку в renders
UPDATE goodini.renders
SET
  error_message = $1,
  full_analysis = $2::jsonb
WHERE id = $3::uuid;

-- Query params:
--  $1 = error message (например: resp.error?.message || 'Request failed')
--  $2 = JSON.stringify(error object)
--  $3 = render_id


-- 7) Если парсинг ответа модели сломался: пишем full_analysis + processing_time + error_message
UPDATE goodini.renders
SET
  full_analysis = $1::jsonb,
  processing_time_sec = $2,
  error_message = $3
WHERE id = $4::uuid;

-- Query params:
--  $1 = JSON.stringify(full_analysis)
--  $2 = processing_time_sec
--  $3 = parse error message
--  $4 = render_id


-- 8) Успешное завершение обработки: job -> CLASSIFIED
UPDATE goodini.jobs
SET
  status = 'CLASSIFIED',
  updated_at = NOW()
WHERE id = $1::uuid;

-- Query params:
--  $1 = job_id


-- 9) Ошибка обработки: job -> FAILED
UPDATE goodini.jobs
SET
  status = 'FAILED',
  updated_at = NOW()
WHERE id = $1::uuid;

-- Query params:
--  $1 = job_id



-- ============================================================
-- ЗАДАНИЕ 2: QC Retry State Machine (qc-result webhook)
-- ============================================================

-- 1) Защита от повторной обработки: читаем текущий status job
SELECT status
FROM goodini.jobs
WHERE id = $1::uuid
LIMIT 1;

-- Query params:
--  $1 = job_id


-- 2) Получаем номер последней попытки генерации по render_id
SELECT
  COALESCE(MAX(attempt_number), 1) AS last_attempt
FROM goodini.generation_attempts
WHERE render_id = $1::uuid;

-- Query params:
--  $1 = render_id


-- 3) Апсерт QC результата в текущую попытку (обновляем verdict/reason)
INSERT INTO goodini.generation_attempts (
  render_id,
  attempt_number,
  qc_verdict,
  failure_reason
)
VALUES ($1::uuid, $2, $3, $4)
ON CONFLICT (render_id, attempt_number)
DO UPDATE SET
  qc_verdict = EXCLUDED.qc_verdict,
  failure_reason = EXCLUDED.failure_reason;

-- Query params:
--  $1 = render_id
--  $2 = current_attempt (last_attempt)
--  $3 = qc_verdict ('PASS' / 'FAIL')
--  $4 = failure_reason


-- 4) Создаем следующую попытку генерации (pending), с параметрами, но без результатов
INSERT INTO goodini.generation_attempts (
  render_id,
  attempt_number,
  parameters,
  qc_verdict,
  failure_reason,
  nano_banana_response
)
VALUES (
  $1::uuid,
  $2,
  $3::jsonb,
  NULL,
  NULL,
  NULL
)
ON CONFLICT (render_id, attempt_number) DO NOTHING;

-- Query params:
--  $1 = render_id
--  $2 = next_attempt
--  $3 = JSON.stringify(parameters)


-- 5) После вызова Nano Banana: записываем nano_banana_response в next_attempt
UPDATE goodini.generation_attempts
SET
  nano_banana_response = $1::jsonb
WHERE render_id = $2::uuid
  AND attempt_number = $3;

-- Query params:
--  $1 = JSON.stringify(nano_banana_response)
--  $2 = render_id
--  $3 = next_attempt


-- 6) Если Nano Banana вернул ошибку: мы тоже сохраняем ответ (ошибку) в next_attempt
-- (технически это тот же UPDATE, но логически — другая ветка)
UPDATE goodini.generation_attempts
SET
  nano_banana_response = $1::jsonb
WHERE render_id = $2::uuid
  AND attempt_number = $3;

-- Query params:
--  $1 = JSON.stringify(error output from HTTP node)
--  $2 = render_id
--  $3 = next_attempt


-- 7) При планировании ретрая: job -> PROCESSING
UPDATE goodini.jobs
SET
  status = $1,
  updated_at = NOW()
WHERE id = $2::uuid;

-- Query params:
--  $1 = 'PROCESSING'
--  $2 = job_id


-- 8) Если Nano Banana технически упал: job -> GENERATION_FAILED
UPDATE goodini.jobs
SET
  status = $1,
  updated_at = NOW()
WHERE id = $2::uuid;

-- Query params:
--  $1 = 'GENERATION_FAILED'
--  $2 = job_id


-- 9) Если исчерпали лимит попыток: job -> MANUAL_REVIEW
UPDATE goodini.jobs
SET
  status = $1,
  updated_at = NOW()
WHERE id = $2::uuid;

-- Query params:
--  $1 = 'MANUAL_REVIEW'
--  $2 = job_id
