# Snir Franco — WhatsApp Kiosk Intelligence System

Automated pipeline that ingests WhatsApp group messages from cosmetics kiosk employees in the Philippines, classifies them with Claude Haiku, persists structured data to Supabase Postgres, and surfaces insights via Metabase dashboards and a daily WhatsApp digest.

---

## 1. System Overview

### What the system does

Staff at each kiosk location send sale updates, end-of-day summaries, contest announcements, and general chatter to two WhatsApp groups. This system intercepts every message via a WAHA webhook, classifies it with an LLM, and writes structured rows to Supabase so that Metabase can serve live and historical dashboards without any manual data entry.

### Data flow (ASCII)

```
WhatsApp Groups
  jpl_management  (live sale events, real-time)
  jpl_totals      (end-of-day summaries, source of truth)
       |
       | WAHA Plus (NOWEB) webhook POST
       v
  n8n Workflow: snir-ph-full
       |
       +--[Event Router]--+
       |                  |
  [session.status]    [message.*]
  FAILED chain        |
                       +--[Load Locations]--> Supabase locations table
                       |
                       +--[Normalize Filter Classify]
                       |    Extracts sender_jid, group_jid,
                       |    body, timestamp, quoted_msg_id
                       |
                       +--[Dedupe Check]
                       |    SELECT raw_messages WHERE wa_message_id = ?
                       |
                       +--[Insert raw_message]
                       |    Immutable audit log row
                       |
                       +--[Handle Edit/Delete?]
                       |    PATCH body/event_type for edits
                       |
                       +--[Classify with Haiku]
                       |    POST https://api.anthropic.com/v1/messages
                       |    Returns JSON: {class, confidence, fields{}}
                       |
                       +--[Confidence Router]
                       |    >= 0.85 AND single_sale  --> [Extract Single Sale]
                       |    >= 0.85 AND eod_summary  --> [Extract EOD]
                       |    >= 0.85 AND other        --> [Chatter/Skip]
                       |    < 0.85  OR unknown       --> [parse_review_queue]
                       |
                 [single_sale branch]
                       |
                       +--[Resolve Lead Employee]  (Supabase RPC trigram)
                       +--[Insert live_event]
                       +--[Insert live_event_employees]
                       |
                 [eod_summary branch]
                       |
                       +--[Extract EOD]
                       +--[Insert daily_totals]  (UPSERT)
                       +--[Insert payment_breakdown]
                       |
                 [low confidence]
                       |
                       +--[parse_review_queue INSERT]
                            Human review in Metabase or Supabase Studio

  n8n Workflow: snir-reconciliation-cron  (runs 23:30 Asia/Manila = 15:30 UTC)
       Supabase RPC run_reconciliation()
       --> IF any location status='alert' --> WAHA alert to owner
       --> INSERT alerts_log

  n8n Workflow: snir-daily-digest  (runs 21:30 Asia/Manila = 13:30 UTC)
       Fetch daily_totals + live_events + reconciliation_log
       --> Format WhatsApp message (top locations, top performers, mismatches)
       --> WAHA sendText to owner group
```

---

## 2. Workflow Structure

### 2a. snir-ph-full (Main Message Pipeline)

| Node | Type | Purpose |
|---|---|---|
| WhatsApp Listener | Webhook POST /whatsapp-listening | Entry point for all WAHA NOWEB events |
| Event Router | Switch (3.4) | Forks on body.event: session.status, message.*, fallback |
| Is FAILED? | IF | Checks body.payload.status == FAILED |
| Check Alert Cooldown | HTTP Request | Calls Supabase RPC try_alert_dedup to suppress repeat alerts |
| Should Fire? | IF | Routes to Log Alert or Alert Suppressed |
| Log Alert | HTTP Request | POST to alerts_log with severity=critical |
| Send WhatsApp Alert | HTTP Request | POST to WAHA /api/sendText — notifies owner of FAILED session |
| Alert Suppressed | NoOp | Sink for suppressed duplicate alerts |
| Session OK | NoOp | Sink for non-FAILED session.status events |
| Unknown Event | NoOp | Sink for unrecognized event types |
| Load Locations | HTTP Request | GET from Supabase locations table to build group JID map |
| Normalize Filter Classify | Code (2) | Extracts sender_jid, group_jid, body, timestamp, quoted_msg_id; filters non-Snir groups |
| Dedupe Check | HTTP Request | GET raw_messages WHERE wa_message_id = ? |
| Already Seen? | IF | Skips if wa_message_id exists; continues if new |
| Duplicate — skip | NoOp | Sink for duplicate messages |
| Insert raw_message | HTTP Request | POST to raw_messages; returns row with id |
| Handle Edit/Delete? | IF | Branches on _normalized.is_revoked or is_edited |
| Update raw_message | HTTP Request | PATCH body + event_type for edited messages |
| Classify with Haiku | HTTP Request | POST to Anthropic API claude-haiku-4-5-20251001 |
| Parse Classifier Output | Code (2) | Parses Anthropic response JSON, handles malformed output |
| Confidence Router | Switch (3.4) | 4 outputs: high_single_sale, high_eod, high_other, low_confidence |
| Extract Single Sale | Code (2) | Parses amount (k/M suffixes), sale_state, lead/helpers, thread info |
| Resolve Lead Employee | HTTP Request | POST to Supabase RPC resolve_employee (trigram match) |
| Insert live_event | HTTP Request | POST to live_events |
| Build Employee Junction Rows | Code (2) | Constructs live_event_employees rows for lead + helpers |
| Insert live_event_employees | HTTP Request | POST to live_event_employees |
| Extract EOD | Code (2) | Parses date, cash, card, total, payment_methods, employee_totals |
| Insert daily_totals | HTTP Request | POST with Prefer: resolution=merge-duplicates (upsert) |
| Build Payment Breakdown Rows | Code (2) | Splits payment_methods array into individual rows |
| Insert payment_breakdown | HTTP Request | POST to payment_breakdown |
| Low Confidence — Queue | HTTP Request | POST to parse_review_queue with classifier_output JSON |
| Chatter/Other — Skip | NoOp | Sink for chatter and contest/announcement (no storage yet) |

### 2b. snir-reconciliation-cron

Runs daily at 23:30 Asia/Manila (cron: `30 15 * * *` UTC).

| Node | Purpose |
|---|---|
| Schedule Trigger | Fires at 15:30 UTC every day |
| Run Reconciliation | POST to Supabase RPC run_reconciliation with tenant_id and yesterday's date (Asia/Manila) |
| Parse Reconciliation Results | Code node — filters alert/missing_eod rows, builds summary text |
| Has Alerts? | IF — checks allOk flag |
| Send Reconciliation Alert | WAHA POST to owner — sends summary text if any location is off |
| Log Reconciliation Run | INSERT to alerts_log with severity=info |

### 2c. snir-daily-digest

Runs daily at 21:30 Asia/Manila (cron: `30 13 * * *` UTC).

| Node | Purpose |
|---|---|
| Schedule Trigger | Fires at 13:30 UTC every day |
| Fetch Daily Totals | GET daily_totals for today joined with locations |
| Fetch Live Events | GET live_events for today's date range (Manila TZ) |
| Fetch Reconciliation Status | GET reconciliation_log for today |
| Format Digest Message | Code node — ranks locations by total, top 5 employees, lists mismatches and missing EODs |
| Send Daily Digest | WAHA POST with formatted message to owner group |

---

## 3. Supabase Table Map

### Foundation tables (migration 0001)

| Table | Purpose | Key Columns |
|---|---|---|
| `tenants` | Multi-tenant root. Snir's tenant id is fixed: `00000000-0000-0000-0000-000000000001` | id, name, created_at |
| `raw_messages` | Immutable audit log of every received WhatsApp message. Dedupe key = wa_message_id. | id, tenant_id, wa_message_id (UNIQUE), group_jid, sender_jid, body, timestamp_unix, event_type, source_group, session, classified_type, classify_confidence |
| `parse_review_queue` | Messages where classifier confidence < 0.85 or class = unknown. Human reviews in Metabase. | id, tenant_id, raw_message_id FK, classifier_output (JSONB), confidence, reason, reviewed |
| `alerts_log` | Log of all fired alerts (session FAILED, reconciliation alerts, cron runs). | id, severity, channel, kind, body, meta (JSONB), created_at |

### Extended raw_messages columns (migration 0002)

Added via ALTER TABLE: `location_id`, `wa_group_jid`, `source_group` (CHECK IN jpl_management/jpl_totals), `parser_version`, `quoted_wa_message_id`. Index on `quoted_wa_message_id` for thread linking.

### Snir-specific tables (migration 0002)

| Table | Purpose | Key Relationships |
|---|---|---|
| `locations` | One row per physical kiosk. Maps wa_group_jid to a location name and metadata. | tenant_id FK → tenants |
| `employees` | Kiosk staff. aliases TEXT[] is used by resolve_employee trigram search. | tenant_id FK, location_id FK |
| `live_events` | One row per sale event captured from jpl_management. Thread linking via sale_thread_id. | tenant_id, location_id, lead_employee_id FK → employees, raw_message_id FK |
| `live_event_employees` | Junction: which employees participated in a sale (lead or helper). | live_event_id FK, employee_id FK, role (lead/helper), pct_share, amount_credited |
| `daily_totals` | One row per location per day, sourced from jpl_totals EOD messages. UNIQUE(location_id, sale_date). | tenant_id, location_id FK, raw_message_id FK |
| `payment_breakdown` | Child rows of daily_totals. One row per payment method (Cash, GCash, BPI, etc). | daily_totals_id FK, method, amount |
| `employee_sales` | Per-employee sales amounts from EOD breakdown lines. | daily_totals_id FK, employee_id FK, amount |
| `contests` | Parsed contest announcements with prize and criteria text. | tenant_id, location_id, raw_message_id FK |
| `announcements` | Parsed general announcements. | tenant_id, location_id, raw_message_id FK |
| `reconciliation_log` | Result of run_reconciliation per location per day. status = ok / alert / missing_eod. | tenant_id, location_id, sale_date, sum_events, eod_reported, diff, diff_pct, status |

### Row Level Security

All tables have RLS enabled. Policy pattern: `tenant_id = current_setting('app.tenant_id', true)::uuid`. Set `app.tenant_id` on the connection before querying (Supabase service role bypasses RLS).

### Key Functions

| Function | Signature | Returns | Purpose |
|---|---|---|---|
| `try_alert_dedup` | (p_session TEXT, p_event TEXT, p_cooldown_minutes INT) | BOOL | Returns true if no alert of same kind+session within cooldown window |
| `resolve_employee` | (p_name TEXT, p_location_id UUID, p_tenant_id UUID) | UUID | Trigram similarity >= 0.75 against aliases array, returns best match or NULL |
| `run_reconciliation` | (p_tenant_id UUID, p_sale_date DATE) | TABLE | Compares sum(live_events.amount) vs daily_totals.total per location, upserts reconciliation_log |

---

## 4. Classifier Prompt Design

### The 6 message classes

| Class | Trigger patterns | Key extracted fields |
|---|---|---|
| `single_sale` | Amount + name(s), Swiped/Tipul/facial keywords, Done/Total/Failed | lead_name, helper_names, amount, currency_raw, product_hint, sale_state (open/mid/closed/cancelled), is_reply_continuation |
| `eod_summary` | Location name + EOD/total + list of payment methods | location_hint, date, cash, card, total, payment_methods[], employee_totals[] |
| `contest` | Prize, competition, contest keywords | title, prize, criteria |
| `announcement` | Good morning, opening/closing times, general info | title, body |
| `chatter` | Social conversation, reactions, questions not related to sales | (empty fields object) |
| `unknown` | Cannot be reliably classified | reason |

### Confidence threshold

The system uses **0.85** as the high/low boundary. Messages with confidence >= 0.85 are written to business tables immediately. Messages below 0.85 are written to `parse_review_queue` for human review. This threshold was chosen to balance precision (avoid noisy data) against recall (do not miss too many real sales). It can be calibrated — see section 5.

### Few-shot example strategy

The system prompt includes 8 labeled examples that cover:
- Simple amount + name patterns (Taglish phrasing)
- Amount-first patterns
- k/M suffix amounts (200k, 1.2M)
- State keywords (Swiped, Done, Failed)
- Full EOD summary format with multiple payment methods
- General announcement
- Pure chatter

Examples are inline in the system prompt so they apply to every request without requiring a separate retrieval step.

### Taglish and Hebrew handling

Staff in the Philippines mix English, Tagalog, and sometimes Hebrew-transliterated terms (e.g. "tipul" = treatment/facial from Hebrew). The system prompt explicitly acknowledges this: "Staff mix English, Tagalog (Taglish), and Hebrew-English." This primes Claude Haiku to not penalize confidence when it encounters these patterns.

### Currency normalization

The Extract Single Sale and Extract EOD code nodes apply a `parseAmount` function that handles:
- Comma thousands separator: `521,285` → 521285
- Peso prefix: `₱4,200` → 4200
- k suffix: `12k` → 12000
- M suffix: `1.2M` → 1200000
- Plain integer strings

---

## 5. Operation and Debugging Runbook

### How to add a new location

1. Insert a row into the `locations` table in Supabase:
   ```sql
   INSERT INTO locations (tenant_id, name, wa_group_jid, source_group, manager_wa, active)
   VALUES (
     '00000000-0000-0000-0000-000000000001',
     'New Location Name',
     '120363XXXXXXXXXX@g.us',   -- get from WAHA logs
     'jpl_management',          -- or jpl_totals
     '63917XXXXXXX@c.us',
     true
   );
   ```
2. Also add a `jpl_totals` row for the same physical location if it has a separate totals group.
3. The n8n workflow loads locations dynamically at runtime — no workflow changes needed.
4. Add employees for the new location (see "How to add a new employee" below).

### How to handle a WAHA session disconnect

1. Watch for the WAHA alert in your WhatsApp (the "Send WhatsApp Alert" node fires on `session.FAILED` events). The cooldown is 60 minutes so you will not be spammed.
2. Log in to `http://waha.toolip.tech` (or the Hetzner VPS directly) and check the WAHA dashboard.
3. Reconnect or restart the session: `POST /api/sessions/snir-session/start` or use the WAHA UI.
4. If the session needs re-linking (QR code scan), go to `/api/sessions/snir-session/auth/qr` to get a new QR.
5. Messages received while the session was down are lost — WhatsApp does not buffer group messages. Check the jpl_totals group manually for any EOD summaries missed during the outage.
6. The `alerts_log` table records every FAILED event — query it to determine the exact downtime window:
   ```sql
   SELECT created_at, meta FROM alerts_log WHERE kind = 'session.FAILED' ORDER BY created_at DESC LIMIT 20;
   ```

### How to review the parse_review_queue

1. In Metabase (or Supabase Studio), open the `parse_review_queue` table filtered to `reviewed = false`.
2. For each row, read the original message (`raw_messages.body` via the `raw_message_id` FK) and the `classifier_output` JSONB.
3. If the classification is correct but confidence was just below threshold, manually insert the parsed record into the appropriate table (`live_events` or `daily_totals`) and mark `reviewed = true`:
   ```sql
   UPDATE parse_review_queue SET reviewed = true WHERE id = '<row-id>';
   ```
4. If the classification is wrong (e.g., a sale was classified as chatter), note the message pattern. Add it to the few-shot examples in the Classify with Haiku node's system prompt in n8n and re-save the workflow.
5. Track the ratio of low-confidence messages over time. If it exceeds 10% of daily volume, review the confidence threshold (see calibration below).

### How to run manual reconciliation

Trigger for any specific date directly in Supabase:
```sql
SELECT * FROM run_reconciliation(
  '00000000-0000-0000-0000-000000000001'::uuid,
  '2026-05-19'::date
);
```

To re-run and overwrite existing results, first delete the existing rows:
```sql
DELETE FROM reconciliation_log
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
  AND sale_date = '2026-05-19';

SELECT * FROM run_reconciliation(
  '00000000-0000-0000-0000-000000000001'::uuid,
  '2026-05-19'::date
);
```

Or add the UNIQUE constraint and UPDATE-on-conflict (see comment in migration 0003).

### How to add a new employee or alias

Insert or update the employee row:
```sql
-- New employee
INSERT INTO employees (tenant_id, location_id, display_name, aliases, class, active)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  '<location-uuid>',
  'Maria Santos',
  ARRAY['maria', 'marie', 'santos'],   -- all lowercase aliases for trigram match
  'B',
  true
);

-- Add alias to existing employee
UPDATE employees
SET aliases = aliases || ARRAY['mari']
WHERE display_name = 'Maria Santos'
  AND tenant_id = '00000000-0000-0000-0000-000000000001';
```

Aliases should be lowercase first names, common nicknames, and any abbreviations staff use in messages. The `resolve_employee` function uses trigram similarity >= 0.75 against the full aliases array.

Test the match before deploying:
```sql
SELECT resolve_employee('mari', '<location-uuid>', '00000000-0000-0000-0000-000000000001');
```

### How to calibrate confidence threshold

The threshold is hardcoded as `0.85` in the Confidence Router Switch node in n8n.

To change it:
1. Open n8n at `http://n8n.toolip.tech`.
2. Open the `snir-ph-full` workflow.
3. Click the **Confidence Router** Switch node.
4. Edit each condition that references `0.85` — change to your desired value (e.g., `0.80` to be more permissive or `0.90` to be stricter).
5. Save and activate.

To empirically choose the threshold:
```sql
-- Distribution of confidence scores for successfully-parsed messages
SELECT
  ROUND(classify_confidence * 20) / 20 AS bucket,
  COUNT(*) AS n,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM raw_messages
WHERE classify_confidence IS NOT NULL
  AND classified_type != 'unknown'
GROUP BY 1
ORDER BY 1;

-- False negative rate at different thresholds (using reviewed queue as ground truth)
SELECT
  confidence >= 0.85 AS above_threshold,
  COUNT(*) AS n
FROM parse_review_queue
GROUP BY 1;
```

### Common errors and how to fix them

**n8n execution fails at "Classify with Haiku" with 401 Unauthorized**
- The ANTHROPIC_API_KEY environment variable is not set or expired.
- Go to n8n Settings > Variables or the `.env` file on the VPS and update `ANTHROPIC_API_KEY`.

**n8n execution fails at Supabase nodes with 401 or 403**
- Check SUPABASE_URL and SUPABASE_ANON_KEY environment variables.
- Verify the Supabase credential `sMR7Uw1nci4thiVy` (named "Snir-DB") in n8n credentials.
- If using RLS, ensure the service role key is used (anon key cannot bypass RLS policies).

**Parse Classifier Output returns class=unknown for all messages**
- The Anthropic API may have changed its response format.
- Check `anthropicResponse.content[0].text` in the Code node. Log it via `$console.log()` in n8n.
- The model name `claude-haiku-4-5-20251001` may have been retired. Update to the current Haiku model in the Classify with Haiku node.

**Reconciliation shows large mismatches for all locations**
- Check that `occurred_at` timestamps in `live_events` are being stored in UTC (they should be — all timestamps are UTC in Postgres; the function converts to Asia/Manila for date grouping).
- Check that `daily_totals.sale_date` is correct. The EOD extraction uses Manila timezone for date parsing.
- Check for duplicate live_events rows from the same sale thread (sale_thread_id grouping).

**resolve_employee returns NULL for a name that exists**
- The similarity threshold of 0.75 may be too strict for that particular name/alias pair.
- Test with: `SELECT similarity(lower('given_alias'), lower('stored_alias'));`
- Add a shorter or exact alias to the employee's aliases array.
- Verify the `pg_trgm` extension is installed: `SELECT * FROM pg_extension WHERE extname = 'pg_trgm';`

**WAHA webhook receives messages but n8n does not process them**
- Verify the webhook URL is `https://n8n.toolip.tech/webhook/whatsapp-listening` (or the appropriate n8n host).
- Check WAHA webhook configuration: the session should have the webhook pointing to this URL.
- Check n8n execution history for the WhatsApp Listener node to see if requests are arriving.
- Confirm the n8n workflow is in "Active" state (not just saved).

**duplicate_skip is firing for legitimate messages**
- This means the same `wa_message_id` is being received twice from WAHA.
- This can happen if WAHA sends the webhook more than once for the same event (retry logic).
- This is expected and harmless — the dedup check prevents double-writing.
- If you need to reprocess a message (e.g., the first attempt failed mid-pipeline), delete the raw_messages row and re-trigger the webhook manually.

---

## 6. Environment Variables Reference

| Variable | Where set | Purpose |
|---|---|---|
| `SUPABASE_URL` | n8n env | Base URL for Supabase REST API |
| `SUPABASE_ANON_KEY` | n8n env | Supabase anon/public API key |
| `ANTHROPIC_API_KEY` | n8n env | Anthropic API key for Claude Haiku |
| `OWNER_WA_JID` | Hardcoded in workflow nodes | WhatsApp JID of owner for alert delivery — change `OWNER_WA_JID@c.us` to real JID |

---

## 7. File Structure

```
snirs/
  migrations/
    0001_listener_baseline.sql    Foundation tables + try_alert_dedup function
    0002_snir_schema.sql          Snir-specific tables + resolve_employee function
    0003_reconciliation_fn.sql    run_reconciliation function
  workflows/
    snir-ph-full.workflow.json        Main WhatsApp message pipeline
    reconciliation-cron.workflow.json Daily reconciliation at 23:30 Manila
    daily-digest-cron.workflow.json   Daily digest at 21:30 Manila
  dashboard.html                  Metabase-style preview dashboard (Chart.js)
  README.md                       This file
```

---

## 8. Infrastructure

| Component | Host / URL | Notes |
|---|---|---|
| n8n | n8n.toolip.tech | Self-hosted on Hetzner VPS |
| WAHA Plus (NOWEB) | waha.toolip.tech | WhatsApp Web API, session name: snir-session |
| Supabase | kpgopmuzqpkxvsuzmepv.supabase.co | Postgres 15, n8n credential id: sMR7Uw1nci4thiVy (Snir-DB) |
| Anthropic API | api.anthropic.com | Model: claude-haiku-4-5-20251001, max_tokens: 256 |
| Metabase | (separate deployment) | Connects to Supabase via read-only Postgres connection |
