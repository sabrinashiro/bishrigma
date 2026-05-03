-- ============================================================
-- META ADS → SUPABASE
-- Todas as tabelas, views, funções e triggers
-- ============================================================


-- ─────────────────────────────────────────────────────────────
-- 0. UTILITÁRIOS
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION safe_divide(numerator NUMERIC, denominator NUMERIC)
RETURNS NUMERIC AS $$
  SELECT CASE
    WHEN denominator IS NULL OR denominator = 0 THEN NULL
    ELSE numerator / denominator
  END;
$$ LANGUAGE SQL IMMUTABLE;


-- ─────────────────────────────────────────────────────────────
-- 1. TABELA PRINCIPAL — insights por anúncio (nível ad, diário)
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS meta_ads_insights (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,

    -- Identificadores
    ad_id           TEXT NOT NULL,
    ad_name         TEXT,
    adset_id        TEXT,
    adset_name      TEXT,
    campaign_id     TEXT,
    campaign_name   TEXT,
    account_id      TEXT,

    -- Período
    date_start      DATE NOT NULL,
    date_stop       DATE NOT NULL,
    month_year      TEXT,   -- populado via trigger (set_month_year)

    -- Métricas brutas
    impressions                       BIGINT          DEFAULT 0,
    spend                             NUMERIC(12, 2)  DEFAULT 0,
    clicks                            BIGINT          DEFAULT 0,
    purchases                         INTEGER         DEFAULT 0,
    purchase_value                    NUMERIC(12, 2)  DEFAULT 0,
    video_thruplay_watched_actions    BIGINT          DEFAULT 0,
    video_watched_actions             BIGINT          DEFAULT 0,

    -- Métricas calculadas
    cvr             NUMERIC(8, 4),   -- clicks / impressions * 100
    cpa             NUMERIC(12, 2),  -- spend / purchases
    roas            NUMERIC(8, 4),   -- purchase_value / spend
    hook_rate       NUMERIC(8, 4),   -- thruplay / impressions * 100
    hold_rate       NUMERIC(8, 4),   -- video_views_30s / impressions * 100
    cost_per_hook   NUMERIC(12, 2),  -- spend / thruplays

    -- Métricas diretas da API (já calculadas pelo Meta)
    outbound_ctr    NUMERIC(8, 4),   -- outbound_clicks_ctr (Meta entrega pronto)

    -- Controle
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(ad_id, date_start, date_stop)
);

-- Índices de performance
CREATE INDEX IF NOT EXISTS idx_meta_ads_month      ON meta_ads_insights (month_year);
CREATE INDEX IF NOT EXISTS idx_meta_ads_ad_id      ON meta_ads_insights (ad_id);
CREATE INDEX IF NOT EXISTS idx_meta_ads_campaign   ON meta_ads_insights (campaign_id);
CREATE INDEX IF NOT EXISTS idx_meta_ads_date_start ON meta_ads_insights (date_start);

-- Trigger para atualizar updated_at automaticamente
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_meta_ads_updated_at ON meta_ads_insights;
CREATE TRIGGER trg_meta_ads_updated_at
  BEFORE UPDATE ON meta_ads_insights
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Trigger para popular month_year automaticamente
CREATE OR REPLACE FUNCTION set_month_year()
RETURNS TRIGGER AS $$
BEGIN
  NEW.month_year = TO_CHAR(NEW.date_start, 'YYYY-MM');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_meta_ads_month_year ON meta_ads_insights;
CREATE TRIGGER trg_meta_ads_month_year
  BEFORE INSERT OR UPDATE OF date_start ON meta_ads_insights
  FOR EACH ROW EXECUTE FUNCTION set_month_year();


-- ─────────────────────────────────────────────────────────────
-- 2. TABELA — frequência da conta (nível account, diário)
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS meta_account_frequency (
    id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    account_id  TEXT NOT NULL,
    date_start  DATE NOT NULL,
    date_stop   DATE NOT NULL,
    month_year  TEXT,   -- populado via trigger (set_month_year)
    frequency   NUMERIC(8, 4),
    impressions BIGINT,
    reach       BIGINT,
    updated_at  TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(account_id, date_start)
);

CREATE INDEX IF NOT EXISTS idx_meta_freq_month ON meta_account_frequency (month_year);

DROP TRIGGER IF EXISTS trg_meta_freq_updated_at ON meta_account_frequency;
CREATE TRIGGER trg_meta_freq_updated_at
  BEFORE UPDATE ON meta_account_frequency
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_meta_freq_month_year ON meta_account_frequency;
CREATE TRIGGER trg_meta_freq_month_year
  BEFORE INSERT OR UPDATE OF date_start ON meta_account_frequency
  FOR EACH ROW EXECUTE FUNCTION set_month_year();


-- ─────────────────────────────────────────────────────────────
-- 3. VIEW — anúncios campeões do mês
--    Critério: ROAS > 5.5 E spend > R$ 1.000 (agregado no mês)
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW meta_champion_ads AS
WITH monthly_by_ad AS (
    SELECT
        month_year,
        ad_id,
        ad_name,
        adset_id,
        adset_name,
        campaign_id,
        campaign_name,
        account_id,

        SUM(impressions)                    AS impressions,
        SUM(spend)                          AS spend,
        SUM(clicks)                         AS clicks,
        SUM(purchases)                      AS purchases,
        SUM(purchase_value)                 AS purchase_value,
        SUM(video_thruplay_watched_actions) AS video_thruplay_watched_actions,
        SUM(video_watched_actions)          AS video_watched_actions,

        -- Métricas recalculadas sobre o mês agregado
        safe_divide(SUM(clicks)::NUMERIC, NULLIF(SUM(impressions), 0)) * 100
            AS cvr,
        safe_divide(SUM(spend), NULLIF(SUM(purchases), 0))
            AS cpa,
        safe_divide(SUM(purchase_value), NULLIF(SUM(spend), 0))
            AS roas,
        safe_divide(SUM(video_thruplay_watched_actions)::NUMERIC, NULLIF(SUM(impressions), 0)) * 100
            AS hook_rate,
        safe_divide(SUM(video_watched_actions)::NUMERIC, NULLIF(SUM(impressions), 0)) * 100
            AS hold_rate,
        safe_divide(SUM(spend), NULLIF(SUM(video_thruplay_watched_actions), 0))
            AS cost_per_hook,

        -- outbound_ctr: média ponderada por impressões
        safe_divide(
            SUM(outbound_ctr * impressions),
            NULLIF(SUM(impressions), 0)
        ) AS outbound_ctr

    FROM meta_ads_insights
    GROUP BY month_year, ad_id, ad_name, adset_id, adset_name,
             campaign_id, campaign_name, account_id
)
SELECT *
FROM monthly_by_ad
WHERE roas > 5.5
  AND spend > 1000
ORDER BY month_year DESC, roas DESC;


-- ─────────────────────────────────────────────────────────────
-- 4. TABELA — resumo mensal consolidado (para dashboard)
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS meta_monthly_summary (
    id                   UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    month_year           TEXT NOT NULL UNIQUE,

    -- Volume
    total_spend          NUMERIC(12, 2),
    total_impressions    BIGINT,
    total_purchases      INTEGER,
    total_purchase_value NUMERIC(12, 2),
    total_clicks         BIGINT,
    avg_reach            BIGINT,

    -- Métricas agregadas
    avg_roas             NUMERIC(8, 4),
    avg_cpa              NUMERIC(12, 2),
    avg_cvr              NUMERIC(8, 4),
    avg_hook_rate        NUMERIC(8, 4),
    avg_hold_rate        NUMERIC(8, 4),
    avg_cost_per_hook    NUMERIC(12, 2),
    avg_outbound_ctr     NUMERIC(8, 4),

    -- Frequência da conta (da tabela meta_account_frequency)
    avg_frequency        NUMERIC(8, 4),

    -- Métrica especial: anúncios campeões
    champion_ads_count   INTEGER,

    updated_at           TIMESTAMPTZ DEFAULT NOW()
);


-- ─────────────────────────────────────────────────────────────
-- 5. STORED PROCEDURE — atualiza o resumo mensal
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION refresh_meta_monthly_summary()
RETURNS void AS $$
BEGIN

  -- Calcula campeões por mês numa CTE auxiliar
  WITH champions_per_month AS (
    SELECT
        month_year,
        COUNT(*) AS champion_count
    FROM (
        SELECT
            month_year,
            ad_id,
            safe_divide(SUM(purchase_value), NULLIF(SUM(spend), 0)) AS roas,
            SUM(spend) AS total_spend
        FROM meta_ads_insights
        GROUP BY month_year, ad_id
    ) sub
    WHERE roas > 5.5
      AND total_spend > 1000
    GROUP BY month_year
  ),

  -- Frequência média da conta por mês
  freq_per_month AS (
    SELECT
        month_year,
        AVG(frequency) AS avg_frequency,
        SUM(reach)     AS avg_reach
    FROM meta_account_frequency
    GROUP BY month_year
  ),

  -- Métricas agregadas dos anúncios por mês
  ads_per_month AS (
    SELECT
        month_year,
        SUM(spend)                          AS total_spend,
        SUM(impressions)                    AS total_impressions,
        SUM(purchases)                      AS total_purchases,
        SUM(purchase_value)                 AS total_purchase_value,
        SUM(clicks)                         AS total_clicks,
        safe_divide(SUM(purchase_value), NULLIF(SUM(spend), 0))
            AS avg_roas,
        safe_divide(SUM(spend), NULLIF(SUM(purchases), 0))
            AS avg_cpa,
        safe_divide(SUM(clicks)::NUMERIC, NULLIF(SUM(impressions), 0)) * 100
            AS avg_cvr,
        safe_divide(SUM(video_thruplay_watched_actions)::NUMERIC, NULLIF(SUM(impressions), 0)) * 100
            AS avg_hook_rate,
        safe_divide(SUM(video_watched_actions)::NUMERIC, NULLIF(SUM(impressions), 0)) * 100
            AS avg_hold_rate,
        safe_divide(SUM(spend), NULLIF(SUM(video_thruplay_watched_actions), 0))
            AS avg_cost_per_hook,
        safe_divide(SUM(outbound_ctr * impressions), NULLIF(SUM(impressions), 0))
            AS avg_outbound_ctr
    FROM meta_ads_insights
    GROUP BY month_year
  )

  INSERT INTO meta_monthly_summary (
      month_year,
      total_spend, total_impressions, total_purchases,
      total_purchase_value, total_clicks, avg_reach,
      avg_roas, avg_cpa, avg_cvr,
      avg_hook_rate, avg_hold_rate, avg_cost_per_hook, avg_outbound_ctr,
      avg_frequency,
      champion_ads_count,
      updated_at
  )
  SELECT
      a.month_year,
      a.total_spend,
      a.total_impressions,
      a.total_purchases,
      a.total_purchase_value,
      a.total_clicks,
      COALESCE(f.avg_reach, 0),
      a.avg_roas,
      a.avg_cpa,
      a.avg_cvr,
      a.avg_hook_rate,
      a.avg_hold_rate,
      a.avg_cost_per_hook,
      a.avg_outbound_ctr,
      COALESCE(f.avg_frequency, 0),
      COALESCE(c.champion_count, 0),
      NOW()
  FROM ads_per_month a
  LEFT JOIN freq_per_month     f ON f.month_year = a.month_year
  LEFT JOIN champions_per_month c ON c.month_year = a.month_year

  ON CONFLICT (month_year) DO UPDATE SET
      total_spend          = EXCLUDED.total_spend,
      total_impressions    = EXCLUDED.total_impressions,
      total_purchases      = EXCLUDED.total_purchases,
      total_purchase_value = EXCLUDED.total_purchase_value,
      total_clicks         = EXCLUDED.total_clicks,
      avg_reach            = EXCLUDED.avg_reach,
      avg_roas             = EXCLUDED.avg_roas,
      avg_cpa              = EXCLUDED.avg_cpa,
      avg_cvr              = EXCLUDED.avg_cvr,
      avg_hook_rate        = EXCLUDED.avg_hook_rate,
      avg_hold_rate        = EXCLUDED.avg_hold_rate,
      avg_cost_per_hook    = EXCLUDED.avg_cost_per_hook,
      avg_outbound_ctr     = EXCLUDED.avg_outbound_ctr,
      avg_frequency        = EXCLUDED.avg_frequency,
      champion_ads_count   = EXCLUDED.champion_ads_count,
      updated_at           = NOW();

END;
$$ LANGUAGE plpgsql;


-- ─────────────────────────────────────────────────────────────
-- 6. QUERIES ÚTEIS
-- ─────────────────────────────────────────────────────────────

-- Campeões do mês atual
-- SELECT * FROM meta_champion_ads
-- WHERE month_year = TO_CHAR(NOW(), 'YYYY-MM');

-- Resumo do mês atual
-- SELECT * FROM meta_monthly_summary
-- WHERE month_year = TO_CHAR(NOW(), 'YYYY-MM');

-- Top 10 anúncios por ROAS no mês
-- SELECT ad_name, campaign_name, roas, spend, cpa, hook_rate, hold_rate, cost_per_hook, outbound_ctr
-- FROM meta_champion_ads
-- WHERE month_year = TO_CHAR(NOW(), 'YYYY-MM')
-- ORDER BY roas DESC
-- LIMIT 10;
