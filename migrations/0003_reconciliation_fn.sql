-- Migration 0003: Reconciliation function
-- Compares summed live_events amounts vs daily_totals EOD reports

-- ============================================================
-- run_reconciliation
-- For each active location under the given tenant, sum live_events
-- amounts for the given sale_date (Manila timezone) and compare
-- against daily_totals.total. Upserts results into reconciliation_log.
--
-- status = 'ok'    when |diff_pct| <= 5%
-- status = 'alert' when |diff_pct| >  5%
-- status = 'missing_eod' when no daily_totals row exists for that date
--
-- Cron hint (run via pg_cron or n8n schedule):
--   SELECT cron.schedule(
--       'reconciliation-daily',
--       '30 15 * * *',   -- 15:30 UTC = 23:30 Asia/Manila
--       $$ SELECT run_reconciliation(
--              '00000000-0000-0000-0000-000000000001'::uuid,
--              (now() AT TIME ZONE 'Asia/Manila')::date - 1
--          ); $$
--   );
-- ============================================================
CREATE OR REPLACE FUNCTION run_reconciliation(
    p_tenant_id UUID,
    p_sale_date DATE
)
RETURNS TABLE (
    location_id  UUID,
    location_name TEXT,
    sum_events   NUMERIC,
    eod_reported NUMERIC,
    diff         NUMERIC,
    diff_pct     NUMERIC,
    status       TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_loc RECORD;
    v_sum_events   NUMERIC;
    v_eod_reported NUMERIC;
    v_diff         NUMERIC;
    v_diff_pct     NUMERIC;
    v_status       TEXT;
BEGIN
    FOR v_loc IN
        SELECT l.id, l.name
        FROM   locations l
        WHERE  l.tenant_id = p_tenant_id
          AND  l.active    = true
    LOOP
        -- Sum live_events for the date, excluding failed/cancelled outcomes
        SELECT COALESCE(SUM(le.amount), 0)
        INTO   v_sum_events
        FROM   live_events le
        WHERE  le.tenant_id   = p_tenant_id
          AND  le.location_id = v_loc.id
          AND  (le.outcome IS NULL OR le.outcome NOT IN ('failed', 'declined'))
          AND  (le.occurred_at AT TIME ZONE 'Asia/Manila')::date = p_sale_date;

        -- Fetch EOD reported total
        SELECT dt.total
        INTO   v_eod_reported
        FROM   daily_totals dt
        WHERE  dt.tenant_id   = p_tenant_id
          AND  dt.location_id = v_loc.id
          AND  dt.sale_date   = p_sale_date;

        IF v_eod_reported IS NULL THEN
            v_diff     := NULL;
            v_diff_pct := NULL;
            v_status   := 'missing_eod';
        ELSE
            v_diff := v_sum_events - v_eod_reported;

            IF v_eod_reported != 0 THEN
                v_diff_pct := ROUND((v_diff / v_eod_reported) * 100, 4);
            ELSE
                v_diff_pct := NULL;
            END IF;

            IF v_diff_pct IS NULL OR abs(v_diff_pct) <= 5 THEN
                v_status := 'ok';
            ELSE
                v_status := 'alert';
            END IF;
        END IF;

        -- Upsert into reconciliation_log
        INSERT INTO reconciliation_log (
            tenant_id, location_id, sale_date,
            sum_events, eod_reported, diff, diff_pct, status
        )
        VALUES (
            p_tenant_id, v_loc.id, p_sale_date,
            v_sum_events, v_eod_reported, v_diff, v_diff_pct, v_status
        )
        ON CONFLICT DO NOTHING;
        -- Note: no UNIQUE constraint on (tenant_id, location_id, sale_date) by default.
        -- Add one if idempotent re-runs are needed:
        -- ALTER TABLE reconciliation_log ADD CONSTRAINT reconciliation_log_uniq
        --     UNIQUE (tenant_id, location_id, sale_date);
        -- Then change ON CONFLICT DO NOTHING to:
        -- ON CONFLICT (tenant_id, location_id, sale_date) DO UPDATE SET
        --     sum_events   = EXCLUDED.sum_events,
        --     eod_reported = EXCLUDED.eod_reported,
        --     diff         = EXCLUDED.diff,
        --     diff_pct     = EXCLUDED.diff_pct,
        --     status       = EXCLUDED.status;

        -- Emit row for caller
        location_id   := v_loc.id;
        location_name := v_loc.name;
        sum_events    := v_sum_events;
        eod_reported  := v_eod_reported;
        diff          := v_diff;
        diff_pct      := v_diff_pct;
        status        := v_status;
        RETURN NEXT;
    END LOOP;

    RETURN;
END;
$$;
