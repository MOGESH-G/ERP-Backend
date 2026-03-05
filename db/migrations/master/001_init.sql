CREATE EXTENSION IF NOT EXISTS "pgcrypto";


-- ────────────────────────────────────────────
-- MIGRATIONS TRACKER (master DB itself)
-- ────────────────────────────────────────────
CREATE TABLE migrations (
  filename    TEXT        PRIMARY KEY,
  applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ────────────────────────────────────────────
-- ENUMS
-- ────────────────────────────────────────────
CREATE TYPE tenant_status   AS ENUM ('provisioning', 'active', 'suspended', 'expired', 'deprovisioned');
CREATE TYPE plan_type        AS ENUM ('trial', 'starter', 'growth', 'enterprise');
CREATE TYPE billing_cycle    AS ENUM ('monthly', 'annual');
CREATE TYPE provision_status AS ENUM ('pending', 'success', 'failed', 'rolled_back');


-- ================================================================
-- TENANTS
-- Core routing table. Middleware reads this (via cache) on every
-- request to resolve which tenant DB to connect to.
-- ================================================================
CREATE TABLE tenants (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT          NOT NULL,
  slug          TEXT          NOT NULL UNIQUE,       -- used in subdomain: slug.yourerp.com
  db_name       TEXT          NOT NULL UNIQUE,       -- postgres DB name: tenant_<slug>
  status        tenant_status NOT NULL DEFAULT 'provisioning',
  plan          plan_type     NOT NULL DEFAULT 'trial',
  expires_at    TIMESTAMPTZ,                         -- NULL = no expiry (enterprise)
  country       CHAR(2)       NOT NULL DEFAULT 'IN',
  timezone      TEXT          NOT NULL DEFAULT 'Asia/Kolkata',
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_tenants_slug   ON tenants (slug);
CREATE INDEX idx_tenants_status ON tenants (status) WHERE status = 'active';


-- ================================================================
-- SUBSCRIPTIONS
-- One active subscription per tenant at a time.
-- ================================================================
CREATE TABLE subscriptions (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  plan             plan_type     NOT NULL,
  billing_cycle    billing_cycle NOT NULL DEFAULT 'monthly',
  amount           NUMERIC(10,2) NOT NULL,
  currency         CHAR(3)       NOT NULL DEFAULT 'INR',
  started_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  ends_at          TIMESTAMPTZ,
  next_billing_at  TIMESTAMPTZ,
  is_active        BOOLEAN       NOT NULL DEFAULT TRUE,
  payment_ref      TEXT,                             -- external payment gateway ref
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_subscriptions_tenant ON subscriptions (tenant_id, is_active);


-- ================================================================
-- PLAN LIMITS
-- Defines what each plan allows. Checked during provisioning
-- and enforced by middleware (e.g. max shops, max users).
-- ================================================================
CREATE TABLE plan_limits (
  plan            plan_type NOT NULL PRIMARY KEY,
  max_shops       INT       NOT NULL DEFAULT 1,
  max_users       INT       NOT NULL DEFAULT 5,
  max_products    INT       NOT NULL DEFAULT 500,
  max_invoices_pm INT       NOT NULL DEFAULT 1000,   -- per month
  ai_features     BOOLEAN   NOT NULL DEFAULT FALSE,
  api_access      BOOLEAN   NOT NULL DEFAULT FALSE,
  support_level   TEXT      NOT NULL DEFAULT 'email' -- email | priority | dedicated
);

-- ================================================================
-- ADMIN ACCOUNTS
-- Only tenant-level admins live here.
-- Operational users (cashiers, managers) live in each tenant DB.
-- ================================================================
CREATE TABLE admin_accounts (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      UUID        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  name           TEXT        NOT NULL,
  email          TEXT        NOT NULL,
  password_hash  TEXT        NOT NULL,
  is_active      BOOLEAN     NOT NULL DEFAULT TRUE,
  last_login_at  TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, email)
);

CREATE INDEX idx_admin_accounts_email ON admin_accounts (email);


-- ================================================================
-- PROVISIONING LOG
-- Immutable audit trail of every tenant DB provisioning event.
-- Critical for debugging failed provisions and rollbacks.
-- ================================================================
CREATE TABLE provisioning_log (
  id            UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID            REFERENCES tenants(id),
  event         TEXT            NOT NULL,            -- 'provision' | 'deprovision' | 'migrate' | 'suspend'
  status        provision_status NOT NULL DEFAULT 'pending',
  db_name       TEXT,
  triggered_by  TEXT,                                -- internal API key / developer ID
  error_detail  TEXT,                                -- full error if failed
  duration_ms   INT,
  created_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_provisioning_log_tenant ON provisioning_log (tenant_id, created_at DESC);
CREATE INDEX idx_provisioning_log_status ON provisioning_log (status) WHERE status != 'success';


-- ================================================================
-- INTERNAL API KEYS
-- For the developer portal / provisioning API.
-- Never exposed to tenant users.
-- ================================================================
CREATE TABLE internal_api_keys (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL,                  -- 'dev-local' | 'ci-pipeline' | 'portal-prod'
  key_hash    TEXT        NOT NULL UNIQUE,           -- SHA256 of actual key — never store raw
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  last_used_at TIMESTAMPTZ,
  expires_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ================================================================
-- FEATURE REGISTRY
-- Master list of every feature that exists in the system.
-- Adding a new feature = one INSERT row. No schema change.
-- ================================================================
CREATE TABLE features (
  id           TEXT        PRIMARY KEY,   -- e.g. 'feat_accounting', 'feat_ai_reorder'
  name         TEXT        NOT NULL,      -- e.g. 'Accounting Module'
  description  TEXT,                     -- shown in developer portal / upgrade prompts
  category     TEXT        NOT NULL,      -- 'core' | 'growth' | 'enterprise' | 'ai'
  is_limit     BOOLEAN     NOT NULL DEFAULT FALSE,  -- TRUE for limit_* keys
  default_val  TEXT,                      -- default value for limits e.g. '5', for booleans NULL
  is_active    BOOLEAN     NOT NULL DEFAULT TRUE,   -- soft disable a feature globally
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ================================================================
-- PLAN FEATURE MAP
-- Maps which features are enabled per plan.
-- For limit features, value stores the numeric limit as text.
-- For boolean features, value is NULL (presence = enabled).
-- ================================================================
CREATE TABLE plan_features (
  plan        TEXT    NOT NULL,           -- matches plan_type enum
  feature_id  TEXT    NOT NULL REFERENCES features(id) ON DELETE CASCADE,
  value       TEXT,                       -- NULL for boolean flags, '5' for limits
  PRIMARY KEY (plan, feature_id)
);

-- ================================================================
-- ADD feature_ids COLUMN TO TENANTS
--
-- Stores the resolved feature map for this tenant as JSONB.
-- Format: { "feat_accounting": true, "limit_shops": 5, ... }
--
-- Seeded from plan_features at provisioning.
-- Any key can be directly overridden for custom deals.
-- This is what gets embedded in the JWT at login — zero extra calls.
-- ================================================================
ALTER TABLE tenants
  ADD COLUMN feature_ids  JSONB NOT NULL DEFAULT '{}',
  ADD COLUMN plan_details JSONB NOT NULL DEFAULT '{}';

CREATE INDEX idx_tenants_feature_ids ON tenants USING GIN (feature_ids);


-- ================================================================
-- HELPER FUNCTION — fn_apply_plan_to_tenant
-- Resolves all features for a plan and writes to tenants.feature_ids
-- Call at provisioning and on every plan change.
-- ================================================================
CREATE OR REPLACE FUNCTION fn_apply_plan_to_tenant(
  p_tenant_id  UUID,
  p_plan       TEXT
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  resolved JSONB := '{}';
  rec      RECORD;
BEGIN
  -- Build the resolved feature map from plan_features + features registry
  FOR rec IN
    SELECT
      pf.feature_id,
      f.is_limit,
      pf.value
    FROM plan_features pf
    JOIN features f ON f.id = pf.feature_id
    WHERE pf.plan = p_plan
      AND f.is_active = TRUE
  LOOP
    IF rec.is_limit THEN
      -- Store limit as integer
      resolved := jsonb_set(resolved, ARRAY[rec.feature_id], to_jsonb(rec.value::INT));
    ELSE
      -- Store boolean feature as true (presence = enabled)
      resolved := jsonb_set(resolved, ARRAY[rec.feature_id], 'true'::jsonb);
    END IF;
  END LOOP;

  IF resolved = '{}' THEN
    RAISE EXCEPTION 'Plan "%" not found or has no features', p_plan;
  END IF;

  UPDATE tenants
  SET
    plan       = p_plan::plan_type,
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
CREATE TABLE tenant_feature_changelog (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    UUID        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  feature_key  TEXT        NOT NULL,
  old_value    TEXT,
  new_value    TEXT,
  changed_by   TEXT,
  reason       TEXT,
  changed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_feat_changelog_tenant ON tenant_feature_changelog (tenant_id, changed_at DESC);


-- Auto-log every change to tenants.feature_ids
CREATE OR REPLACE FUNCTION trg_log_feature_changes()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  key      TEXT;
  old_val  TEXT;
  new_val  TEXT;
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

CREATE TRIGGER trg_tenants_feature_changes
  AFTER UPDATE ON tenants
  FOR EACH ROW EXECUTE FUNCTION trg_log_feature_changes();

-- ================================================================
-- TRIGGERS
-- ================================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tenants_updated_at
  BEFORE UPDATE ON tenants
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_admin_accounts_updated_at
  BEFORE UPDATE ON admin_accounts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ================================================================
-- RECORD THIS MIGRATION
-- ================================================================
INSERT INTO migrations (filename) VALUES ('001_init.sql');