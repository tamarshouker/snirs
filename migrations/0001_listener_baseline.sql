-- Migration 0001: Listener baseline tables
-- Foundation tables for the WhatsApp listener pipeline

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- tenants
-- ============================================================
CREATE TABLE IF NOT EXISTS tenants (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT now()
);

-- Seed Snir's tenant row (fixed UUID used as FK in n8n workflow)
INSERT INTO tenants (id, name)
VALUES ('00000000-0000-0000-0000-000000000001', 'Snir Franco')
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- raw_messages
-- ============================================================
CREATE TABLE IF NOT EXISTS raw_messages (
    id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID        NOT NULL REFERENCES tenants(id),
    wa_message_id        TEXT        UNIQUE NOT NULL,
    group_jid            TEXT,
    sender_jid           TEXT,
    body                 TEXT,
    timestamp_unix       BIGINT,
    event_type           TEXT,
    source_group         TEXT,
    session              TEXT,
    classified_type      TEXT,
    classify_confidence  NUMERIC,
    created_at           TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE raw_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY raw_messages_tenant_isolation
    ON raw_messages
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS raw_messages_tenant_idx        ON raw_messages (tenant_id);
CREATE INDEX IF NOT EXISTS raw_messages_wa_message_id_idx ON raw_messages (wa_message_id);
CREATE INDEX IF NOT EXISTS raw_messages_group_jid_idx     ON raw_messages (group_jid);
CREATE INDEX IF NOT EXISTS raw_messages_sender_jid_idx    ON raw_messages (sender_jid);
CREATE INDEX IF NOT EXISTS raw_messages_created_at_idx    ON raw_messages (created_at DESC);

-- ============================================================
-- parse_review_queue
-- ============================================================
CREATE TABLE IF NOT EXISTS parse_review_queue (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID        NOT NULL REFERENCES tenants(id),
    raw_message_id      UUID        REFERENCES raw_messages(id),
    classifier_output   JSONB,
    confidence          NUMERIC,
    reason              TEXT,
    reviewed            BOOL        DEFAULT false,
    created_at          TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE parse_review_queue ENABLE ROW LEVEL SECURITY;

CREATE POLICY parse_review_queue_tenant_isolation
    ON parse_review_queue
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE INDEX IF NOT EXISTS parse_review_queue_tenant_idx     ON parse_review_queue (tenant_id);
CREATE INDEX IF NOT EXISTS parse_review_queue_reviewed_idx   ON parse_review_queue (reviewed) WHERE reviewed = false;
CREATE INDEX IF NOT EXISTS parse_review_queue_created_at_idx ON parse_review_queue (created_at DESC);

-- ============================================================
-- alerts_log
-- ============================================================
CREATE TABLE IF NOT EXISTS alerts_log (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    severity    TEXT,
    channel     TEXT,
    kind        TEXT,
    body        TEXT,
    meta        JSONB,
    created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS alerts_log_kind_created_idx ON alerts_log (kind, created_at DESC);
CREATE INDEX IF NOT EXISTS alerts_log_severity_idx     ON alerts_log (severity);

-- ============================================================
-- try_alert_dedup
-- Returns TRUE  => caller should fire the alert (no recent duplicate)
-- Returns FALSE => duplicate within cooldown window, suppress
-- ============================================================
CREATE OR REPLACE FUNCTION try_alert_dedup(
    p_session          TEXT,
    p_event            TEXT,
    p_cooldown_minutes INT DEFAULT 60
)
RETURNS BOOL
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_last_fired TIMESTAMPTZ;
BEGIN
    SELECT created_at INTO v_last_fired
    FROM   alerts_log
    WHERE  kind    = p_event
      AND  meta->>'session' = p_session
    ORDER  BY created_at DESC
    LIMIT  1;

    IF v_last_fired IS NULL THEN
        RETURN TRUE;
    END IF;

    IF v_last_fired < now() - (p_cooldown_minutes || ' minutes')::INTERVAL THEN
        RETURN TRUE;
    END IF;

    RETURN FALSE;
END;
$$;
