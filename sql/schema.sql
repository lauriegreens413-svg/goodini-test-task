-- ============================================================
-- schema.sql
-- Схема базы данных для AI Pipeline (Jobs → Renders → Attempts)
-- ============================================================
-- Назначение:
--  - jobs                — состояние обработки задачи
--  - renders             — рендеры и результаты AI-анализа
--  - generation_attempts — попытки генерации и QC-вердикты
--
-- ВАЖНО:
--  - файл содержит только DDL (CREATE / ALTER / INDEX)
--  - никаких INSERT / UPDATE / SELECT
-- ============================================================

-- =========================
-- Таблица jobs
-- =========================
CREATE TABLE goodini.jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id character varying NOT NULL,
  status character varying DEFAULT 'QUEUED',
  batch_id character varying,
  created_at timestamp without time zone DEFAULT now(),
  updated_at timestamp without time zone DEFAULT now()
);

-- =========================
-- Таблица renders
-- =========================
CREATE TABLE goodini.renders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid REFERENCES goodini.jobs(id),
  source_image_url text NOT NULL,

  -- Результаты Vision / AI анализа
  detected_shot_type character varying,
  confidence double precision,
  generated_prompt text,
  technical_tags jsonb,
  motion_recommendation character varying,
  full_analysis jsonb,

  -- Метаданные обработки
  processing_time_sec integer,
  error_message text,

  created_at timestamp without time zone DEFAULT now()
);

-- =========================
-- Таблица generation_attempts
-- =========================
CREATE TABLE goodini.generation_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  render_id uuid REFERENCES goodini.renders(id),

  -- Номер попытки генерации
  attempt_number integer DEFAULT 1,

  -- Параметры генерации (structure_scale, cfg_scale и т.д.)
  parameters jsonb,

  -- Вердикт QC (PASS / FAIL)
  qc_verdict character varying,
  failure_reason text,

  -- Ответ от Nano Banana API
  nano_banana_response jsonb,

  created_at timestamp without time zone DEFAULT now()
);

-- ============================================================
-- Индексы и ограничения
-- ============================================================

-- Уникальность попытки генерации в рамках одного render
ALTER TABLE goodini.generation_attempts
ADD CONSTRAINT uniq_generation_attempt_per_render
UNIQUE (render_id, attempt_number);

-- Индекс для быстрого получения последней попытки генерации
-- (используется при расчёте next_attempt)
CREATE INDEX idx_generation_attempts_render_attempt_desc
ON goodini.generation_attempts (render_id, attempt_number DESC);

-- Индекс для быстрого поиска рендеров по job_id
CREATE INDEX idx_renders_job_id
ON goodini.renders (job_id);

-- GIN-индекс для поиска по JSONB тегам (technical_tags)
-- Пример использования:
-- WHERE technical_tags @> '["interior"]'
CREATE INDEX idx_renders_technical_tags_gin
ON goodini.renders
USING GIN (technical_tags);
