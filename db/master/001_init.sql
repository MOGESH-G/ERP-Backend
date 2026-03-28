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
    filename TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ────────────────────────────────────────────
-- ENUMS
-- ────────────────────────────────────────────

-- Provisioning flow: provisioning -> active -> (suspended/expired) -> deprovisioned
-- Provisioning = in progress. Active = fully provisioned and operational.
-- Suspended = temporary hold (violation warning) with intent to recover. Expired = subscription ended without renewal. Deprovisioned = DB deleted, tenant closed.
DO $$ BEGIN
  CREATE TYPE plan_type   AS ENUM ('starter', 'growth', 'enterprise', 'custom');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE tenant_status   AS ENUM ('provisioning', 'active', 'suspended', 'expired', 'deprovisioned');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE billing_cycle   AS ENUM ('monthly', 'annual');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE payment_status   AS ENUM ('pending', 'completed', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ================================================================
-- TENANTS
-- Core routing table. Middleware reads this (via cache) on every
-- request to resolve which tenant DB to connect to.
-- ================================================================
CREATE TABLE IF NOT EXISTS tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid (),
    name TEXT NOT NULL,
    email TEXT, -- primary contact email for this tenant
    phone TEXT NOT NULL UNIQUE, -- primary contact phone number for this tenant
    logo TEXT, -- URL to tenant logo, can be used in UI and invoice templates
    industry TEXT, -- Retail, Restaurant, etc. Can be used for analytics and customized features in the future
    gst_number TEXT UNIQUE,
    pan_number TEXT,
    slug TEXT NOT NULL UNIQUE, -- used in subdomain: slug.yourerp.com. The same can be used for db name
    company_name TEXT NOT NULL UNIQUE, -- postgres DB name: tenant_<slug>
    address TEXT,
    status tenant_status NOT NULL DEFAULT 'provisioning',
    country CHAR(2) NOT NULL DEFAULT 'IN',
    currency CHAR(3) NOT NULL DEFAULT 'INR',
    timezone TEXT NOT NULL DEFAULT 'Asia/Kolkata',
    create_info JSONB NOT NULL DEFAULT '{}'::JSONB, -- Store additional information about the created time and person who created the subscription, e.g. { "created_by": "user_id", "created_at": "time" }
    update_info JSONB NOT NULL DEFAULT '{}'::JSONB, -- Store additional information about the updated time and person who updated the subscription, e.g. { "updated_by": "user_id", "updated_at": "time" }
);

CREATE INDEX IF NOT EXISTS idx_tenants_slug ON tenants (slug);

CREATE INDEX IF NOT EXISTS idx_tenants_status ON tenants (status)
WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_tenants_feature_ids ON tenants USING GIN (feature_ids);

-- ================================================================
-- SUBSCRIPTIONS
-- One active subscription per tenant at a time.
-- ================================================================
CREATE TABLE IF NOT EXISTS subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid (),
    tenant_id UUID NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_trial BOOLEAN NOT NULL DEFAULT FALSE, -- Whether this subscription is currently in trial period. Can be used for special trial features or messaging.
    payment_id UUID NOT NULL REFERENCES payment_details (id) ON DELETE RESTRICT, -- Reference to payment details for this subscription. Can be used to track payment history and link to invoices/receipts.
    plan_id UUID NOT NULL REFERENCES plan_details (id) ON DELETE RESTRICT, -- ID of the plan this tenant is subscribed to. Used for quick reference but the real source of truth is in feature_ids.
    billing_cycle billing_cycle NOT NULL DEFAULT 'monthly',
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ, -- can be used to store the end date by default and changed if the tenant renews or changes plan before expiry or provided grace period.
    create_info JSONB NOT NULL DEFAULT '{}'::JSONB, -- Store additional information about the created time and person who created the subscription, e.g. { "created_by": "user_id", "created_at": "time" }
);

-- ================================================================
-- PAyMENT DETAILS
-- Store payment information for subscriptions. Can be expanded to include
-- ================================================================
CREATE TABLE IF NOT EXISTS payment_details (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid (),
    amount NUMERIC(10, 2) NOT NULL,
    currency CHAR(3) NOT NULL DEFAULT 'INR',
    payment_method TEXT NOT NULL,
    payment_status payment_status NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_tenant ON subscriptions (tenant_id, is_active);

-- ================================================================
-- PLAN DETAILS
-- Defines what each plan allows. Checked during provisioning
-- and enforced by middleware.
-- ================================================================
CREATE TABLE IF NOT EXISTS plan_details (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid (),
    type plan_type NOT NULL UNIQUE, --type of the plan, e.g. 'starter', 'growth', 'enterprise', 'custom'
    max_shops INT NOT NULL DEFAULT 1,
    max_users INT NOT NULL DEFAULT 5,
    max_products INT NOT NULL DEFAULT 500,
    feature_ids TEXT[] NOT NULL DEFAULT '{}'::TEXT[], -- Array of strings referencing features enabled for this tenant. Populated by fn_apply_plan_to_tenant and used by middleware for feature gating without joins.
    create_info JSONB NOT NULL DEFAULT '{}'::JSONB, -- Store additional information about the created time and person who created the subscription, e.g. { "created_by": "user_id", "created_at": "time" }
    update_info JSONB NOT NULL DEFAULT '{}'::JSONB, -- Store additional information about the updated time and person who updated the subscription, e.g. { "updated_by": "user_id", "updated_at": "time" }
);

-- ================================================================
-- ADMIN ACCOUNTS
-- Only tenant-level admins live here.
-- Operational users (cashiers, managers) live in each tenant DB.
-- ================================================================
CREATE TABLE IF NOT EXISTS admin_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid (),
    name TEXT NOT NULL,
    email TEXT NOT NULL,
    password TEXT NOT NULL,
    create_info JSONB NOT NULL DEFAULT '{}'::JSONB,
    update_info JSONB NOT NULL DEFAULT '{}'::JSONB,
    UNIQUE (tenant_id, email)
);

CREATE INDEX IF NOT EXISTS idx_admin_accounts_email ON admin_accounts (email);

-- ================================================================
-- FEATURE REGISTRY
-- Master list of every feature that exists in the system.
-- Adding a new feature = one INSERT row. No schema change.
-- ================================================================

CREATE TABLE IF NOT EXISTS features (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid (),
    key TEXT NOT NULL UNIQUE, -- unique key for the feature, e.g. 'feat_dashboard', 'feat_pos', 'limit_shops'
    name TEXT NOT NULL,
    description TEXT,
    parent_id UUID REFERENCES features (id),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_premium BOOLEAN NOT NULL DEFAULT FALSE, -- Whether this feature is a proivided by default when the parent feature is selected.
    create_info JSONB NOT NULL DEFAULT '{}'::JSONB,
    update_info JSONB NOT NULL DEFAULT '{}'::JSONB
);

INSERT INTO
    features (
        key,
        name,
        description,
    )
VALUES (
        'feat_dashboard',
        'Dashboard',
        'Main overview and analytics',
    ),
    (
        'feat_pos',
        'POS Terminal',
        'Point of sale billing',
    ),
    (
        'feat_inventory',
        'Inventory',
        'Stock tracking and movements',
    ),
    (
        'feat_purchases',
        'Purchases',
        'Supplier purchase orders',
    ),
    (
        'feat_basic_reports',
        'Basic Reports',
        'Daily sales and stock summary',
    ),
    (
        'feat_customers',
        'Customers',
        'Customer management',
    ),
    (
        'feat_suppliers',
        'Suppliers',
        'Supplier management',
    ),
    (
        'feat_multi_shop',
        'Multi Shop',
        'Manage multiple shop locations',
    ),
    (
        'feat_price_lists',
        'Price Lists',
        'Tiered pricing and price lists',
    ),
    (
        'feat_customer_groups',
        'Customer Groups',
        'Group-based pricing and segmentation',
    ),
    (
        'feat_loyalty',
        'Loyalty Points',
        'Global loyalty program across shops',
    ),
    (
        'feat_offline_pos',
        'Offline POS',
        'Billing without internet connectivity',
    ),
    (
        'feat_advanced_reports',
        'Advanced Reports',
        'P&L, trend analysis, custom date ranges',
    ),
    (
        'feat_purchase_variance',
        'Purchase Variance',
        'Track cost variance across purchases',
    ),
    (
        'feat_landed_cost',
        'Landed Cost',
        'Freight and additional cost allocation',
    ),
    (
        'feat_accounting',
        'Accounting',
        'Double-entry bookkeeping and journals',
    ),
    (
        'feat_gst_einvoice',
        'GST E-Invoice',
        'IRN, ACK and e-way bill generation',
    ),
    (
        'feat_tcs_tds',
        'TCS / TDS',
        'Tax collected/deducted at source',
    ),
    (
        'feat_audit_log',
        'Audit Log',
        'Full financial change history',
    ),
    (
        'feat_books_lock',
        'Books Lock',
        'Prevent backdated financial edits',
    ),
    (
        'feat_api_access',
        'API Access',
        'REST API for external integrations',
    ),
    (
        'feat_whatsapp_sms',
        'WhatsApp / SMS',
        'Marketing and transactional messaging',
    ),
    (
        'feat_ai_reorder',
        'AI Reorder',
        'Auto reorder suggestions',
    ),
    (
        'feat_ai_dead_stock',
        'Dead Stock Detection',
        'Identify slow and dead inventory',
    ),
    (
        'feat_ai_demand_forecast',
        'Demand Forecast',
        'Predict future stock requirements',
    ),
    (
        'feat_ai_price_suggestion',
        'Price Suggestion',
        'AI-based selling price recommendations',
    ) ON CONFLICT (key) DO NOTHING;

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
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT f.key, f.is_limit, pf.value
    FROM features pf
    JOIN features f ON f.id = pf.feature_id
    WHERE pf.plan = p_plan
      AND f.is_active = TRUE
  LOOP
    IF rec.is_limit THEN
      resolved := jsonb_set(
        resolved,
        ARRAY[rec.key],
        to_jsonb(rec.value::INT)
      );
    ELSE
      resolved := jsonb_set(
        resolved,
        ARRAY[rec.key],
        'true'::jsonb
      );
    END IF;
  END LOOP;

  UPDATE tenants
  SET
    plan        = p_plan::plan_type,
    feature_ids = resolved,
    updated_at  = NOW()
  WHERE id = p_tenant_id;
END;
$$;

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

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- ================================================================
-- TRIGGERS — updated_at
-- ================================================================
DO $$ BEGIN
  CREATE TRIGGER trg_tenants_feature_changes
    AFTER UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION trg_log_feature_changes();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

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
INSERT INTO
    migrations (filename)
VALUES ('001_master.sql') ON CONFLICT (filename) DO NOTHING;