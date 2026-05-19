-- Migration 0002: Snir-specific schema
-- Locations, employees, live events, daily totals, and supporting tables

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================
-- locations
-- ============================================================
CREATE TABLE IF NOT EXISTS locations (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID        NOT NULL REFERENCES tenants(id),
    name             TEXT        NOT NULL,
    wa_group_jid     TEXT        UNIQUE,
    source_group     TEXT        CHECK (source_group IN ('jpl_management', 'jpl_totals')),
    timezone         TEXT        NOT NULL DEFAULT 'Asia/Manila',
    manager_wa       TEXT,
    kiosk_shop_rollup TEXT,
    active           BOOL        NOT NULL DEFAULT true
);

ALTER TABLE locations ENABLE ROW LEVEL SECURITY;

CREATE POLICY locations_tenant_isolation
    ON locations
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS locations_tenant_idx      ON locations (tenant_id);
CREATE INDEX IF NOT EXISTS locations_wa_group_jid_idx ON locations (wa_group_jid);

-- ============================================================
-- employees
-- ============================================================
CREATE TABLE IF NOT EXISTS employees (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID          NOT NULL REFERENCES tenants(id),
    location_id      UUID          REFERENCES locations(id),
    display_name     TEXT          NOT NULL,
    aliases          TEXT[]        NOT NULL DEFAULT '{}',
    wa_phone         TEXT,
    class            CHAR(1)       CHECK (class IN ('A', 'B', 'C')),
    active           BOOL          NOT NULL DEFAULT true,
    personal_avg_30d NUMERIC,
    target_daily     NUMERIC,
    opted_out        BOOL          NOT NULL DEFAULT false
);

ALTER TABLE employees ENABLE ROW LEVEL SECURITY;

CREATE POLICY employees_tenant_isolation
    ON employees
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS employees_tenant_idx    ON employees (tenant_id);
CREATE INDEX IF NOT EXISTS employees_location_idx  ON employees (location_id);
-- GIN index for trigram search on aliases array cast to text
CREATE INDEX IF NOT EXISTS employees_aliases_trgm_idx
    ON employees USING GIN (array_to_string(aliases, ' ') gin_trgm_ops);

-- ============================================================
-- Extend raw_messages (added by this migration)
-- ============================================================
ALTER TABLE raw_messages
    ADD COLUMN IF NOT EXISTS location_id           UUID REFERENCES locations(id),
    ADD COLUMN IF NOT EXISTS wa_group_jid          TEXT,
    ADD COLUMN IF NOT EXISTS source_group          TEXT CHECK (source_group IN ('jpl_management', 'jpl_totals')),
    ADD COLUMN IF NOT EXISTS parser_version        TEXT,
    ADD COLUMN IF NOT EXISTS quoted_wa_message_id  TEXT;

CREATE INDEX IF NOT EXISTS raw_messages_location_idx   ON raw_messages (location_id);
CREATE INDEX IF NOT EXISTS raw_messages_quoted_idx     ON raw_messages (quoted_wa_message_id);

-- ============================================================
-- live_events
-- ============================================================
CREATE TABLE IF NOT EXISTS live_events (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID          NOT NULL REFERENCES tenants(id),
    location_id      UUID          REFERENCES locations(id),
    lead_employee_id UUID          REFERENCES employees(id),
    amount           NUMERIC(12,2),
    product_hint     TEXT,
    outcome          TEXT          CHECK (outcome IN ('success', 'failed', 'declined')),
    occurred_at      TIMESTAMPTZ,
    raw_message_id   UUID          REFERENCES raw_messages(id),
    confidence       NUMERIC,
    sale_state       TEXT          CHECK (sale_state IN ('open', 'mid', 'closed')),
    sale_thread_id   UUID,
    source_group     TEXT
);

ALTER TABLE live_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY live_events_tenant_isolation
    ON live_events
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS live_events_tenant_idx          ON live_events (tenant_id);
CREATE INDEX IF NOT EXISTS live_events_location_idx        ON live_events (location_id);
CREATE INDEX IF NOT EXISTS live_events_occurred_at_idx     ON live_events (occurred_at DESC);
CREATE INDEX IF NOT EXISTS live_events_sale_thread_id_idx  ON live_events (sale_thread_id);
CREATE INDEX IF NOT EXISTS live_events_lead_employee_idx   ON live_events (lead_employee_id);

-- ============================================================
-- live_event_employees
-- ============================================================
CREATE TABLE IF NOT EXISTS live_event_employees (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID          NOT NULL REFERENCES tenants(id),
    live_event_id    UUID          NOT NULL REFERENCES live_events(id) ON DELETE CASCADE,
    employee_id      UUID          NOT NULL REFERENCES employees(id),
    role             TEXT          NOT NULL CHECK (role IN ('lead', 'helper')),
    pct_share        NUMERIC(5,2),
    amount_credited  NUMERIC(12,2),
    UNIQUE (live_event_id, employee_id)
);

ALTER TABLE live_event_employees ENABLE ROW LEVEL SECURITY;

CREATE POLICY live_event_employees_tenant_isolation
    ON live_event_employees
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS lee_tenant_idx       ON live_event_employees (tenant_id);
CREATE INDEX IF NOT EXISTS lee_live_event_idx   ON live_event_employees (live_event_id);
CREATE INDEX IF NOT EXISTS lee_employee_idx     ON live_event_employees (employee_id);

-- ============================================================
-- daily_totals
-- ============================================================
CREATE TABLE IF NOT EXISTS daily_totals (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID          NOT NULL REFERENCES tenants(id),
    location_id      UUID          REFERENCES locations(id),
    sale_date        DATE          NOT NULL,
    cash             NUMERIC(12,2),
    card             NUMERIC(12,2),
    total            NUMERIC(12,2),
    lead_source      TEXT,
    raw_message_id   UUID          REFERENCES raw_messages(id),
    UNIQUE (location_id, sale_date)
);

ALTER TABLE daily_totals ENABLE ROW LEVEL SECURITY;

CREATE POLICY daily_totals_tenant_isolation
    ON daily_totals
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS daily_totals_tenant_idx    ON daily_totals (tenant_id);
CREATE INDEX IF NOT EXISTS daily_totals_location_idx  ON daily_totals (location_id);
CREATE INDEX IF NOT EXISTS daily_totals_sale_date_idx ON daily_totals (sale_date DESC);

-- ============================================================
-- payment_breakdown
-- ============================================================
CREATE TABLE IF NOT EXISTS payment_breakdown (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID          NOT NULL REFERENCES tenants(id),
    daily_totals_id  UUID          NOT NULL REFERENCES daily_totals(id) ON DELETE CASCADE,
    method           TEXT          NOT NULL,
    amount           NUMERIC(12,2) NOT NULL
);

ALTER TABLE payment_breakdown ENABLE ROW LEVEL SECURITY;

CREATE POLICY payment_breakdown_tenant_isolation
    ON payment_breakdown
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS payment_breakdown_tenant_idx  ON payment_breakdown (tenant_id);
CREATE INDEX IF NOT EXISTS payment_breakdown_dt_idx      ON payment_breakdown (daily_totals_id);

-- ============================================================
-- employee_sales
-- ============================================================
CREATE TABLE IF NOT EXISTS employee_sales (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID          NOT NULL REFERENCES tenants(id),
    daily_totals_id  UUID          NOT NULL REFERENCES daily_totals(id) ON DELETE CASCADE,
    employee_id      UUID          NOT NULL REFERENCES employees(id),
    amount           NUMERIC(12,2) NOT NULL
);

ALTER TABLE employee_sales ENABLE ROW LEVEL SECURITY;

CREATE POLICY employee_sales_tenant_isolation
    ON employee_sales
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS employee_sales_tenant_idx  ON employee_sales (tenant_id);
CREATE INDEX IF NOT EXISTS employee_sales_dt_idx      ON employee_sales (daily_totals_id);
CREATE INDEX IF NOT EXISTS employee_sales_emp_idx     ON employee_sales (employee_id);

-- ============================================================
-- contests
-- ============================================================
CREATE TABLE IF NOT EXISTS contests (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID          NOT NULL REFERENCES tenants(id),
    location_id      UUID          REFERENCES locations(id),
    starts_at        TIMESTAMPTZ,
    ends_at          TIMESTAMPTZ,
    prize            TEXT,
    criteria_text    TEXT,
    raw_message_id   UUID          REFERENCES raw_messages(id)
);

ALTER TABLE contests ENABLE ROW LEVEL SECURITY;

CREATE POLICY contests_tenant_isolation
    ON contests
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS contests_tenant_idx    ON contests (tenant_id);
CREATE INDEX IF NOT EXISTS contests_location_idx  ON contests (location_id);

-- ============================================================
-- announcements
-- ============================================================
CREATE TABLE IF NOT EXISTS announcements (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID          NOT NULL REFERENCES tenants(id),
    location_id      UUID          REFERENCES locations(id),
    title            TEXT,
    body             TEXT,
    raw_message_id   UUID          REFERENCES raw_messages(id)
);

ALTER TABLE announcements ENABLE ROW LEVEL SECURITY;

CREATE POLICY announcements_tenant_isolation
    ON announcements
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS announcements_tenant_idx   ON announcements (tenant_id);
CREATE INDEX IF NOT EXISTS announcements_location_idx ON announcements (location_id);

-- ============================================================
-- reconciliation_log
-- ============================================================
CREATE TABLE IF NOT EXISTS reconciliation_log (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID          NOT NULL REFERENCES tenants(id),
    location_id      UUID          REFERENCES locations(id),
    sale_date        DATE          NOT NULL,
    sum_events       NUMERIC(12,2),
    eod_reported     NUMERIC(12,2),
    diff             NUMERIC(12,2),
    diff_pct         NUMERIC(7,4),
    status           TEXT
);

ALTER TABLE reconciliation_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY reconciliation_log_tenant_isolation
    ON reconciliation_log
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS reconciliation_log_tenant_idx    ON reconciliation_log (tenant_id);
CREATE INDEX IF NOT EXISTS reconciliation_log_location_idx  ON reconciliation_log (location_id);
CREATE INDEX IF NOT EXISTS reconciliation_log_date_idx      ON reconciliation_log (sale_date DESC);

-- ============================================================
-- resolve_employee
-- Trigram similarity match against aliases, scoped to location.
-- Returns the employee id with highest similarity >= 0.75, or NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION resolve_employee(
    p_name        TEXT,
    p_location_id UUID,
    p_tenant_id   UUID
)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_employee_id UUID;
BEGIN
    SELECT id INTO v_employee_id
    FROM (
        SELECT
            e.id,
            MAX(similarity(lower(a.alias), lower(p_name))) AS best_sim
        FROM employees e
        CROSS JOIN LATERAL unnest(e.aliases) AS a(alias)
        WHERE e.location_id = p_location_id
          AND e.tenant_id   = p_tenant_id
          AND e.active       = true
        GROUP BY e.id
    ) ranked
    WHERE best_sim >= 0.75
    ORDER BY best_sim DESC
    LIMIT 1;

    RETURN v_employee_id;
END;
$$;
