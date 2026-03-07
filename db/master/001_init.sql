-- ================================================================
-- MASTER DATABASE — 000_master.sql
-- Purpose : Tenant registry, admin accounts, billing, feature flags.
--           Run ONCE at platform deployment. Safe to re-run.
-- ================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ────────────────────────────────────────────
-- MIGRATIONS TRACKER
-- ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS migrations (
  filename   TEXT        PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ────────────────────────────────────────────
-- ENUMS
-- ────────────────────────────────────────────
DO $$ BEGIN
  CREATE TYPE tenant_status   AS ENUM ('provisioning', 'active', 'suspended', 'expired', 'deprovisioned');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE plan_type       AS ENUM ('trial', 'starter', 'growth', 'enterprise');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE billing_cycle   AS ENUM ('monthly', 'annual');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE provision_status AS ENUM ('pending', 'success', 'failed', 'rolled_back');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ================================================================
-- TENANTS
-- Core routing table. Middleware reads this (via cache) on every
-- request to resolve which tenant DB to connect to.
-- ================================================================
CREATE TABLE IF NOT EXISTS tenants (
  id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT          NOT NULL,
  email      TEXT          NOT NULL,              -- primary contact email for this tenant
  phone      TEXT,                         -- primary contact phone number for this tenant
  slug        TEXT          NOT NULL UNIQUE,       -- used in subdomain: slug.yourerp.com
  db_name     TEXT          NOT NULL UNIQUE,       -- postgres DB name: tenant_<slug>
  status      tenant_status NOT NULL DEFAULT 'provisioning',
  plan        plan_type     NOT NULL DEFAULT 'trial',
  expires_at  TIMESTAMPTZ,                         -- NULL = no expiry (enterprise)
  country     CHAR(2)       NOT NULL DEFAULT 'IN',
  timezone    TEXT          NOT NULL DEFAULT 'Asia/Kolkata',
  feature_ids JSONB         NOT NULL DEFAULT '{}',
  plan_details JSONB        NOT NULL DEFAULT '{}',
  created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tenants_slug       ON tenants (slug);
CREATE INDEX IF NOT EXISTS idx_tenants_status     ON tenants (status) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_tenants_feature_ids ON tenants USING GIN (feature_ids);

-- ================================================================
-- SUBSCRIPTIONS
-- One active subscription per tenant at a time.
-- ================================================================
CREATE TABLE IF NOT EXISTS subscriptions (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  plan            plan_type     NOT NULL,
  billing_cycle   billing_cycle NOT NULL DEFAULT 'monthly',
  amount          NUMERIC(10,2) NOT NULL,
  currency        CHAR(3)       NOT NULL DEFAULT 'INR',
  started_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  ends_at         TIMESTAMPTZ,
  next_billing_at TIMESTAMPTZ,
  is_active       BOOLEAN       NOT NULL DEFAULT TRUE,
  payment_ref     TEXT,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_tenant ON subscriptions (tenant_id, is_active);

-- ================================================================
-- PLAN LIMITS
-- Defines what each plan allows. Checked during provisioning
-- and enforced by middleware.
-- ================================================================
CREATE TABLE IF NOT EXISTS plan_limits (
  plan            plan_type NOT NULL PRIMARY KEY,
  max_shops       INT       NOT NULL DEFAULT 1,
  max_users       INT       NOT NULL DEFAULT 5,
  max_products    INT       NOT NULL DEFAULT 500,
  max_invoices_pm INT       NOT NULL DEFAULT 1000,
  ai_features     BOOLEAN   NOT NULL DEFAULT FALSE,
  api_access      BOOLEAN   NOT NULL DEFAULT FALSE,
  support_level   TEXT      NOT NULL DEFAULT 'email'
);

-- ================================================================
-- ADMIN ACCOUNTS
-- Only tenant-level admins live here.
-- Operational users (cashiers, managers) live in each tenant DB.
-- ================================================================
CREATE TABLE IF NOT EXISTS admin_accounts (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  name          TEXT        NOT NULL,
  email         TEXT        NOT NULL,
  password_hash TEXT        NOT NULL,
  is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
  last_login_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, email)
);

CREATE INDEX IF NOT EXISTS idx_admin_accounts_email ON admin_accounts (email);

-- ================================================================
-- PROVISIONING LOG
-- Immutable audit trail of every tenant DB provisioning event.
-- ================================================================
CREATE TABLE IF NOT EXISTS provisioning_log (
  id           UUID             PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    UUID             REFERENCES tenants(id),
  event        TEXT             NOT NULL,   -- 'provision' | 'deprovision' | 'migrate' | 'suspend'
  status       provision_status NOT NULL DEFAULT 'pending',
  db_name      TEXT,
  triggered_by TEXT,
  error_detail TEXT,
  duration_ms  INT,
  created_at   TIMESTAMPTZ      NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_provisioning_log_tenant ON provisioning_log (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_provisioning_log_status ON provisioning_log (status) WHERE status != 'success';

-- ================================================================
-- INTERNAL API KEYS
-- For the developer portal / provisioning API.
-- ================================================================
CREATE TABLE IF NOT EXISTS internal_api_keys (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT        NOT NULL,
  key_hash     TEXT        NOT NULL UNIQUE,
  is_active    BOOLEAN     NOT NULL DEFAULT TRUE,
  last_used_at TIMESTAMPTZ,
  expires_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ================================================================
-- FEATURE REGISTRY
-- Master list of every feature that exists in the system.
-- Adding a new feature = one INSERT row. No schema change.
-- ================================================================
CREATE TABLE IF NOT EXISTS features (
  id          TEXT        PRIMARY KEY,
  name        TEXT        NOT NULL,
  description TEXT,
  category    TEXT        NOT NULL,   -- 'core' | 'growth' | 'enterprise' | 'ai'
  is_limit    BOOLEAN     NOT NULL DEFAULT FALSE,
  default_val TEXT,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO features (id, name, description, category) VALUES
  ('feat_pos',                'POS Terminal',          'Point of sale billing',                   'core'),
  ('feat_inventory',          'Inventory',             'Stock tracking and movements',            'core'),
  ('feat_purchases',          'Purchases',             'Supplier purchase orders',                'core'),
  ('feat_basic_reports',      'Basic Reports',         'Daily sales and stock summary',           'core'),
  ('feat_customers',          'Customers',             'Customer management',                     'core'),
  ('feat_suppliers',          'Suppliers',             'Supplier management',                     'core'),
  ('feat_multi_shop',         'Multi Shop',            'Manage multiple shop locations',          'growth'),
  ('feat_price_lists',        'Price Lists',           'Tiered pricing and price lists',          'growth'),
  ('feat_customer_groups',    'Customer Groups',       'Group-based pricing and segmentation',    'growth'),
  ('feat_loyalty',            'Loyalty Points',        'Global loyalty program across shops',     'growth'),
  ('feat_offline_pos',        'Offline POS',           'Billing without internet connectivity',   'growth'),
  ('feat_advanced_reports',   'Advanced Reports',      'P&L, trend analysis, custom date ranges', 'growth'),
  ('feat_purchase_variance',  'Purchase Variance',     'Track cost variance across purchases',    'growth'),
  ('feat_landed_cost',        'Landed Cost',           'Freight and additional cost allocation',  'growth'),
  ('feat_accounting',         'Accounting',            'Double-entry bookkeeping and journals',   'enterprise'),
  ('feat_gst_einvoice',       'GST E-Invoice',         'IRN, ACK and e-way bill generation',      'enterprise'),
  ('feat_tcs_tds',            'TCS / TDS',             'Tax collected/deducted at source',        'enterprise'),
  ('feat_audit_log',          'Audit Log',             'Full financial change history',           'enterprise'),
  ('feat_books_lock',         'Books Lock',            'Prevent backdated financial edits',       'enterprise'),
  ('feat_api_access',         'API Access',            'REST API for external integrations',      'enterprise'),
  ('feat_whatsapp_sms',       'WhatsApp / SMS',        'Marketing and transactional messaging',   'enterprise'),
  ('feat_ai_reorder',         'AI Reorder',            'Auto reorder suggestions',                'ai'),
  ('feat_ai_dead_stock',      'Dead Stock Detection',  'Identify slow and dead inventory',        'ai'),
  ('feat_ai_demand_forecast', 'Demand Forecast',       'Predict future stock requirements',       'ai'),
  ('feat_ai_price_suggestion','Price Suggestion',      'AI-based selling price recommendations',  'ai')
ON CONFLICT (id) DO NOTHING;

INSERT INTO features (id, name, description, category, is_limit, default_val) VALUES
  ('limit_shops',              'Shop Limit',            'Maximum number of shops',           'core', TRUE, '1'),
  ('limit_users',              'User Limit',            'Maximum number of users',           'core', TRUE, '3'),
  ('limit_products',           'Product Limit',         'Maximum number of products',        'core', TRUE, '500'),
  ('limit_invoices_per_month', 'Monthly Invoice Limit', 'Maximum invoices per month',        'core', TRUE, '1000')
ON CONFLICT (id) DO NOTHING;

-- ================================================================
-- PLAN FEATURE MAP
-- Maps which features are enabled per plan.
-- For limit features, value stores the numeric limit as text.
-- For boolean features, value is NULL (presence = enabled).
-- ================================================================
CREATE TABLE IF NOT EXISTS plan_features (
  plan       TEXT NOT NULL,
  feature_id TEXT NOT NULL REFERENCES features(id) ON DELETE CASCADE,
  value      TEXT,
  PRIMARY KEY (plan, feature_id)
);

-- trial
INSERT INTO plan_features (plan, feature_id, value) VALUES
  ('trial', 'feat_pos',                NULL),
  ('trial', 'feat_inventory',          NULL),
  ('trial', 'feat_purchases',          NULL),
  ('trial', 'feat_basic_reports',      NULL),
  ('trial', 'feat_customers',          NULL),
  ('trial', 'feat_suppliers',          NULL),
  ('trial', 'limit_shops',             '1'),
  ('trial', 'limit_users',             '3'),
  ('trial', 'limit_products',          '200'),
  ('trial', 'limit_invoices_per_month','500')
ON CONFLICT (plan, feature_id) DO NOTHING;

-- starter
INSERT INTO plan_features (plan, feature_id, value) VALUES
  ('starter', 'feat_pos',                NULL),
  ('starter', 'feat_inventory',          NULL),
  ('starter', 'feat_purchases',          NULL),
  ('starter', 'feat_basic_reports',      NULL),
  ('starter', 'feat_customers',          NULL),
  ('starter', 'feat_suppliers',          NULL),
  ('starter', 'feat_price_lists',        NULL),
  ('starter', 'feat_offline_pos',        NULL),
  ('starter', 'limit_shops',             '1'),
  ('starter', 'limit_users',             '5'),
  ('starter', 'limit_products',          '1000'),
  ('starter', 'limit_invoices_per_month','3000')
ON CONFLICT (plan, feature_id) DO NOTHING;

-- growth
INSERT INTO plan_features (plan, feature_id, value) VALUES
  ('growth', 'feat_pos',                NULL),
  ('growth', 'feat_inventory',          NULL),
  ('growth', 'feat_purchases',          NULL),
  ('growth', 'feat_basic_reports',      NULL),
  ('growth', 'feat_customers',          NULL),
  ('growth', 'feat_suppliers',          NULL),
  ('growth', 'feat_multi_shop',         NULL),
  ('growth', 'feat_price_lists',        NULL),
  ('growth', 'feat_customer_groups',    NULL),
  ('growth', 'feat_loyalty',            NULL),
  ('growth', 'feat_offline_pos',        NULL),
  ('growth', 'feat_advanced_reports',   NULL),
  ('growth', 'feat_purchase_variance',  NULL),
  ('growth', 'feat_landed_cost',        NULL),
  ('growth', 'feat_gst_einvoice',       NULL),
  ('growth', 'feat_audit_log',          NULL),
  ('growth', 'feat_api_access',         NULL),
  ('growth', 'feat_whatsapp_sms',       NULL),
  ('growth', 'feat_ai_reorder',         NULL),
  ('growth', 'feat_ai_dead_stock',      NULL),
  ('growth', 'limit_shops',             '5'),
  ('growth', 'limit_users',             '25'),
  ('growth', 'limit_products',          '10000'),
  ('growth', 'limit_invoices_per_month','20000')
ON CONFLICT (plan, feature_id) DO NOTHING;

-- enterprise
INSERT INTO plan_features (plan, feature_id, value) VALUES
  ('enterprise', 'feat_pos',                NULL),
  ('enterprise', 'feat_inventory',          NULL),
  ('enterprise', 'feat_purchases',          NULL),
  ('enterprise', 'feat_basic_reports',      NULL),
  ('enterprise', 'feat_customers',          NULL),
  ('enterprise', 'feat_suppliers',          NULL),
  ('enterprise', 'feat_multi_shop',         NULL),
  ('enterprise', 'feat_price_lists',        NULL),
  ('enterprise', 'feat_customer_groups',    NULL),
  ('enterprise', 'feat_loyalty',            NULL),
  ('enterprise', 'feat_offline_pos',        NULL),
  ('enterprise', 'feat_advanced_reports',   NULL),
  ('enterprise', 'feat_purchase_variance',  NULL),
  ('enterprise', 'feat_landed_cost',        NULL),
  ('enterprise', 'feat_accounting',         NULL),
  ('enterprise', 'feat_gst_einvoice',       NULL),
  ('enterprise', 'feat_tcs_tds',            NULL),
  ('enterprise', 'feat_audit_log',          NULL),
  ('enterprise', 'feat_books_lock',         NULL),
  ('enterprise', 'feat_api_access',         NULL),
  ('enterprise', 'feat_whatsapp_sms',       NULL),
  ('enterprise', 'feat_ai_reorder',         NULL),
  ('enterprise', 'feat_ai_dead_stock',      NULL),
  ('enterprise', 'feat_ai_demand_forecast', NULL),
  ('enterprise', 'feat_ai_price_suggestion',NULL),
  ('enterprise', 'limit_shops',             '999'),
  ('enterprise', 'limit_users',             '999'),
  ('enterprise', 'limit_products',          '999999'),
  ('enterprise', 'limit_invoices_per_month','999999')
ON CONFLICT (plan, feature_id) DO NOTHING;

-- ================================================================
-- HELPER FUNCTION — fn_apply_plan_to_tenant
-- Resolves all features for a plan and writes to tenants.feature_ids
-- Call at provisioning and on every plan change.
-- ================================================================
CREATE OR REPLACE FUNCTION fn_apply_plan_to_tenant(
  p_tenant_id UUID,
  p_plan      TEXT
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  resolved JSONB := '{}';
  rec      RECORD;
BEGIN
  FOR rec IN
    SELECT pf.feature_id, f.is_limit, pf.value
    FROM plan_features pf
    JOIN features f ON f.id = pf.feature_id
    WHERE pf.plan = p_plan
      AND f.is_active = TRUE
  LOOP
    IF rec.is_limit THEN
      resolved := jsonb_set(resolved, ARRAY[rec.feature_id], to_jsonb(rec.value::INT));
    ELSE
      resolved := jsonb_set(resolved, ARRAY[rec.feature_id], 'true'::jsonb);
    END IF;
  END LOOP;

  IF resolved = '{}' THEN
    RAISE EXCEPTION 'Plan "%" not found or has no features', p_plan;
  END IF;

  UPDATE tenants
  SET
    plan        = p_plan::plan_type,
    feature_ids = resolved,
    updated_at  = NOW()
  WHERE id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tenant "%" not found', p_tenant_id;
  END IF;
END;
$$;

-- ================================================================
-- FEATURE CHANGE LOG
-- Auto-populated by trigger. Never write to this manually.
-- ================================================================
CREATE TABLE IF NOT EXISTS tenant_feature_changelog (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  feature_key TEXT        NOT NULL,
  old_value   TEXT,
  new_value   TEXT,
  changed_by  TEXT,
  reason      TEXT,
  changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_feat_changelog_tenant ON tenant_feature_changelog (tenant_id, changed_at DESC);

-- Auto-log every change to tenants.feature_ids
CREATE OR REPLACE FUNCTION trg_log_feature_changes()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  key     TEXT;
  old_val TEXT;
  new_val TEXT;
BEGIN
  IF NEW.feature_ids IS DISTINCT FROM OLD.feature_ids THEN
    FOR key IN
      SELECT DISTINCT k FROM (
        SELECT jsonb_object_keys(OLD.feature_ids) AS k
        UNION
        SELECT jsonb_object_keys(NEW.feature_ids) AS k
      ) keys
    LOOP
      old_val := OLD.feature_ids ->> key;
      new_val := NEW.feature_ids ->> key;
      IF old_val IS DISTINCT FROM new_val THEN
        INSERT INTO tenant_feature_changelog
          (tenant_id, feature_key, old_value, new_value, changed_by, reason)
        VALUES (
          NEW.id, key, old_val, new_val,
          current_setting('app.changed_by',    TRUE),
          current_setting('app.change_reason', TRUE)
        );
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END;
$$;

DO $$ BEGIN
  CREATE TRIGGER trg_tenants_feature_changes
    AFTER UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION trg_log_feature_changes();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ================================================================
-- TRIGGERS — updated_at
-- ================================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DO $$ BEGIN
  CREATE TRIGGER trg_tenants_updated_at
    BEFORE UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TRIGGER trg_admin_accounts_updated_at
    BEFORE UPDATE ON admin_accounts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ================================================================
-- RECORD THIS MIGRATION
-- ================================================================
INSERT INTO migrations (filename) VALUES ('000_master.sql')
ON CONFLICT (filename) DO NOTHING;