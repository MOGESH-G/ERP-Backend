-- ================================================================
-- TENANT DATABASE — tenant.init.sql
-- Purpose : Full schema for a single tenant's operational DB.
--           Run automatically at provisioning time. Safe to re-run.
-- Note    : No tenant_id columns — isolation is at DB level.
-- ================================================================

-- ────────────────────────────────────────────
-- EXTENSIONS
-- ────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "btree_gist";

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
DO $$ BEGIN CREATE TYPE account_type    AS ENUM ('asset', 'liability', 'equity', 'revenue', 'expense');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE journal_status  AS ENUM ('draft', 'posted', 'reversed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE invoice_status  AS ENUM ('draft', 'confirmed', 'paid', 'cancelled', 'offline_pending');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE payment_mode    AS ENUM ('cash', 'upi', 'card', 'credit_note', 'split');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE return_status   AS ENUM ('pending', 'approved', 'refunded', 'post_gst_tagged');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE purchase_status AS ENUM ('draft', 'received', 'billed', 'partially_returned', 'returned');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE stock_movement  AS ENUM ('purchase', 'sale', 'return_in', 'return_out', 'adjustment', 'transfer', 'opening');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE price_tier      AS ENUM ('retail', 'wholesale', 'distributor', 'promotional');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE loyalty_tx_type AS ENUM ('earn', 'redeem', 'expire', 'adjust');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE reorder_status  AS ENUM ('suggested', 'approved', 'ordered', 'received', 'dismissed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE sync_status     AS ENUM ('pending', 'synced', 'failed', 'conflict');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE audit_action    AS ENUM ('insert', 'update', 'delete', 'post', 'reverse', 'lock');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ================================================================
-- SECTION 1 — TENANT PROFILE (single row)
-- ================================================================
CREATE TABLE IF NOT EXISTS tenant_profile (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name              TEXT        NOT NULL,
  gst_number        TEXT        UNIQUE,
  pan_number        TEXT,
  address           TEXT,
  phone             TEXT,
  email             TEXT,
  currency          CHAR(3)     NOT NULL DEFAULT 'INR',
  books_locked_till DATE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ================================================================
-- SECTION 2 — SHOPS
-- ================================================================
CREATE TABLE IF NOT EXISTS shops (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT        NOT NULL,
  address    TEXT,
  phone      TEXT,
  gst_number TEXT,
  is_active  BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ================================================================
-- SECTION 3 — USERS
-- Operational users only. Tenant admin lives in master DB.
-- ================================================================
CREATE TABLE users (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id     UUID REFERENCES shops(id) ON DELETE SET NULL,
  name        TEXT NOT NULL,
  email       TEXT NOT NULL UNIQUE,
  password    TEXT NOT NULL,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ================================================================
-- SECTION 3A — ROLES
-- ================================================================

CREATE TABLE roles (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL UNIQUE,
  description TEXT,

  permissions JSONB NOT NULL DEFAULT '{}'::jsonb,

  is_system   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ================================================================
-- SECTION 3C — USER ROLES
-- ================================================================

CREATE TABLE user_roles (
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  role_id UUID REFERENCES roles(id) ON DELETE CASCADE,
  PRIMARY KEY(user_id, role_id)
);

-- ================================================================
-- SECTION 4 — FINANCIAL ACCOUNTING
-- ================================================================
CREATE TABLE IF NOT EXISTS chart_of_accounts (
  id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  code       TEXT         NOT NULL UNIQUE,
  name       TEXT         NOT NULL,
  type       account_type NOT NULL,
  parent_id  UUID         REFERENCES chart_of_accounts(id),
  is_system  BOOLEAN      NOT NULL DEFAULT FALSE,
  is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS journal_entries (
  id          UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_type    TEXT           NOT NULL,
  ref_id      UUID           NOT NULL,
  entry_date  DATE           NOT NULL DEFAULT CURRENT_DATE,
  description TEXT,
  status      journal_status NOT NULL DEFAULT 'draft',
  posted_at   TIMESTAMPTZ,
  posted_by   UUID           REFERENCES users(id),
  reversed_by UUID           REFERENCES journal_entries(id),
  created_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS journal_entry_lines (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_entry_id UUID          NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  account_id       UUID          NOT NULL REFERENCES chart_of_accounts(id),
  debit            NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (debit  >= 0),
  credit           NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  description      TEXT,
  CHECK (debit > 0 OR credit > 0),
  CHECK (NOT (debit > 0 AND credit > 0))
);

-- ================================================================
-- SECTION 5 — TAX RATES
-- ================================================================
CREATE TABLE IF NOT EXISTS tax_rates (
  id         UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT          NOT NULL,
  rate       NUMERIC(5,2)  NOT NULL,
  tax_type   TEXT          NOT NULL DEFAULT 'GST',
  is_active  BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- ================================================================
-- SECTION 6 — SUPPLIERS
-- ================================================================
CREATE TABLE IF NOT EXISTS suppliers (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT        NOT NULL,
  gst_number TEXT,
  phone      TEXT,
  email      TEXT,
  address    TEXT,
  is_active  BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ================================================================
-- SECTION 7 — PRODUCTS & INVENTORY
-- ================================================================
CREATE TABLE IF NOT EXISTS categories (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name      TEXT NOT NULL UNIQUE,
  parent_id UUID REFERENCES categories(id)
);

CREATE TABLE IF NOT EXISTS products (
  id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  sku         TEXT          NOT NULL UNIQUE,
  name        TEXT          NOT NULL,
  description TEXT,
  category_id UUID          REFERENCES categories(id),
  tax_rate_id UUID          REFERENCES tax_rates(id),
  unit        TEXT          NOT NULL DEFAULT 'pcs',
  barcode     TEXT,
  hsn_code    TEXT,
  base_price  NUMERIC(12,2) NOT NULL DEFAULT 0,
  cost_price  NUMERIC(12,2) NOT NULL DEFAULT 0,
  is_active   BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_products_name_trgm ON products USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_products_barcode   ON products (barcode) WHERE barcode IS NOT NULL;

CREATE TABLE IF NOT EXISTS inventory (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       UUID          NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
  product_id    UUID          NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  quantity      NUMERIC(12,3) NOT NULL DEFAULT 0,
  reorder_point NUMERIC(12,3) NOT NULL DEFAULT 0,
  reorder_qty   NUMERIC(12,3) NOT NULL DEFAULT 0,
  landed_cost   NUMERIC(12,2) NOT NULL DEFAULT 0,
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, product_id)
);

CREATE TABLE IF NOT EXISTS stock_movements (
  id         UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id    UUID           NOT NULL REFERENCES shops(id),
  product_id UUID           NOT NULL REFERENCES products(id),
  movement   stock_movement NOT NULL,
  quantity   NUMERIC(12,3)  NOT NULL,
  ref_type   TEXT,
  ref_id     UUID,
  note       TEXT,
  created_by UUID           REFERENCES users(id),
  created_at TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stock_movements_product ON stock_movements (product_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stock_movements_shop    ON stock_movements (shop_id,    created_at DESC);

-- ================================================================
-- SECTION 8 — PRICING & PRICE LISTS
-- ================================================================
CREATE TABLE IF NOT EXISTS price_lists (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT        NOT NULL,
  tier       price_tier  NOT NULL DEFAULT 'retail',
  valid_from DATE,
  valid_to   DATE,
  is_active  BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT no_overlapping_promo EXCLUDE USING GIST (
    tier WITH =,
    daterange(valid_from, valid_to, '[]') WITH &&
  ) WHERE (valid_from IS NOT NULL AND valid_to IS NOT NULL AND is_active = TRUE)
);

CREATE TABLE IF NOT EXISTS price_list_items (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  price_list_id UUID          NOT NULL REFERENCES price_lists(id) ON DELETE CASCADE,
  product_id    UUID          NOT NULL REFERENCES products(id)    ON DELETE CASCADE,
  price         NUMERIC(12,2) NOT NULL,
  UNIQUE (price_list_id, product_id)
);

-- ================================================================
-- SECTION 9 — CUSTOMERS
-- ================================================================
CREATE TABLE IF NOT EXISTS customer_groups (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL UNIQUE,
  price_list_id UUID REFERENCES price_lists(id)
);

CREATE TABLE IF NOT EXISTS customers (
  id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name              TEXT          NOT NULL,
  phone             TEXT,
  email             TEXT,
  gst_number        TEXT,
  address           TEXT,
  customer_group_id UUID          REFERENCES customer_groups(id),
  loyalty_points    NUMERIC(10,2) NOT NULL DEFAULT 0,
  whatsapp_opt_in   BOOLEAN       NOT NULL DEFAULT FALSE,
  sms_opt_in        BOOLEAN       NOT NULL DEFAULT FALSE,
  is_active         BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_customers_phone     ON customers (phone) WHERE phone IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_customers_name_trgm ON customers USING GIN (name gin_trgm_ops);

CREATE TABLE IF NOT EXISTS customer_shop_stats (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     UUID          NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  shop_id         UUID          NOT NULL REFERENCES shops(id)     ON DELETE CASCADE,
  total_invoices  INT           NOT NULL DEFAULT 0,
  total_spent     NUMERIC(14,2) NOT NULL DEFAULT 0,
  last_visited_at TIMESTAMPTZ,
  UNIQUE (customer_id, shop_id)
);

CREATE TABLE IF NOT EXISTS loyalty_transactions (
  id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID            NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  shop_id     UUID            REFERENCES shops(id),
  type        loyalty_tx_type NOT NULL,
  points      NUMERIC(10,2)   NOT NULL,
  ref_type    TEXT,
  ref_id      UUID,
  note        TEXT,
  created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- ================================================================
-- SECTION 10 — INVOICES
-- ================================================================
CREATE TABLE IF NOT EXISTS invoices (
  id              UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id         UUID           NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
  invoice_number  TEXT           NOT NULL,
  offline_number  TEXT,
  status          invoice_status NOT NULL DEFAULT 'draft',
  customer_id     UUID           REFERENCES customers(id),
  user_id         UUID           REFERENCES users(id),
  price_list_id   UUID           REFERENCES price_lists(id),
  invoice_date    DATE           NOT NULL DEFAULT CURRENT_DATE,
  due_date        DATE,
  subtotal        NUMERIC(14,2)  NOT NULL DEFAULT 0,
  discount_amount NUMERIC(14,2)  NOT NULL DEFAULT 0,
  taxable_amount  NUMERIC(14,2)  NOT NULL DEFAULT 0,
  tax_amount      NUMERIC(14,2)  NOT NULL DEFAULT 0,
  total_amount    NUMERIC(14,2)  NOT NULL DEFAULT 0,
  paid_amount     NUMERIC(14,2)  NOT NULL DEFAULT 0,
  payment_mode    payment_mode,
  irn             TEXT,
  ack_no          TEXT,
  ack_date        TIMESTAMPTZ,
  eway_bill_no    TEXT,
  tcs_rate        NUMERIC(5,2),
  tcs_amount      NUMERIC(12,2),
  tds_rate        NUMERIC(5,2),
  tds_amount      NUMERIC(12,2),
  is_offline      BOOLEAN        NOT NULL DEFAULT FALSE,
  synced_at       TIMESTAMPTZ,
  idempotency_key TEXT           UNIQUE,
  notes           TEXT,
  created_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, invoice_number)
);

CREATE INDEX IF NOT EXISTS idx_invoices_customer  ON invoices (customer_id);
CREATE INDEX IF NOT EXISTS idx_invoices_date      ON invoices (invoice_date DESC);
CREATE INDEX IF NOT EXISTS idx_invoices_shop_date ON invoices (shop_id, invoice_date DESC);
CREATE INDEX IF NOT EXISTS idx_invoices_status    ON invoices (status) WHERE status != 'paid';

CREATE TABLE IF NOT EXISTS invoice_lines (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id      UUID          NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  product_id      UUID          NOT NULL REFERENCES products(id),
  quantity        NUMERIC(12,3) NOT NULL,
  unit_price      NUMERIC(12,2) NOT NULL,
  discount_pct    NUMERIC(5,2)  NOT NULL DEFAULT 0,
  discount_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  taxable_amount  NUMERIC(12,2) NOT NULL DEFAULT 0,
  tax_rate        NUMERIC(5,2)  NOT NULL DEFAULT 0,
  tax_amount      NUMERIC(12,2) NOT NULL DEFAULT 0,
  line_total      NUMERIC(12,2) NOT NULL DEFAULT 0,
  hsn_code        TEXT,
  batch_number    TEXT,
  serial_number   TEXT
);

CREATE TABLE IF NOT EXISTS invoice_payments (
  id         UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id UUID          NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  mode       payment_mode  NOT NULL,
  amount     NUMERIC(12,2) NOT NULL,
  reference  TEXT,
  paid_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- ================================================================
-- SECTION 11 — PURCHASES
-- ================================================================
CREATE TABLE IF NOT EXISTS purchases (
  id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id             UUID            NOT NULL REFERENCES shops(id),
  supplier_id         UUID            REFERENCES suppliers(id),
  purchase_number     TEXT            NOT NULL,
  status              purchase_status NOT NULL DEFAULT 'draft',
  purchase_date       DATE            NOT NULL DEFAULT CURRENT_DATE,
  subtotal            NUMERIC(14,2)   NOT NULL DEFAULT 0,
  tax_amount          NUMERIC(14,2)   NOT NULL DEFAULT 0,
  freight             NUMERIC(12,2)   NOT NULL DEFAULT 0,
  additional_charges  NUMERIC(12,2)   NOT NULL DEFAULT 0,
  other_costs         NUMERIC(12,2)   NOT NULL DEFAULT 0,
  total_landed_cost   NUMERIC(14,2)   NOT NULL DEFAULT 0,
  total_amount        NUMERIC(14,2)   NOT NULL DEFAULT 0,
  supplier_invoice_no TEXT,
  notes               TEXT,
  created_by          UUID            REFERENCES users(id),
  created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, purchase_number)
);

CREATE TABLE IF NOT EXISTS purchase_lines (
  id                   UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_id          UUID          NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
  product_id           UUID          NOT NULL REFERENCES products(id),
  quantity             NUMERIC(12,3) NOT NULL,
  unit_cost            NUMERIC(12,2) NOT NULL,
  tax_rate             NUMERIC(5,2)  NOT NULL DEFAULT 0,
  tax_amount           NUMERIC(12,2) NOT NULL DEFAULT 0,
  line_total           NUMERIC(12,2) NOT NULL DEFAULT 0,
  landed_cost_per_unit NUMERIC(12,4) NOT NULL DEFAULT 0,
  prev_cost_price      NUMERIC(12,2),
  purchase_variance    NUMERIC(12,2),
  suggested_sell_price NUMERIC(12,2),
  batch_number         TEXT,
  expiry_date          DATE
);

-- ================================================================
-- SECTION 12 — SALES RETURNS
-- ================================================================
CREATE TABLE IF NOT EXISTS sales_returns (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       UUID          NOT NULL REFERENCES shops(id),
  return_number TEXT          NOT NULL,
  invoice_id    UUID          NOT NULL REFERENCES invoices(id),
  customer_id   UUID          REFERENCES customers(id),
  status        return_status NOT NULL DEFAULT 'pending',
  return_date   DATE          NOT NULL DEFAULT CURRENT_DATE,
  subtotal      NUMERIC(14,2) NOT NULL DEFAULT 0,
  tax_amount    NUMERIC(14,2) NOT NULL DEFAULT 0,
  total_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
  refund_mode   payment_mode,
  refund_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  is_post_gst   BOOLEAN       NOT NULL DEFAULT FALSE,
  reason        TEXT,
  processed_by  UUID          REFERENCES users(id),
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, return_number)
);

CREATE TABLE IF NOT EXISTS sales_return_lines (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_return_id UUID          NOT NULL REFERENCES sales_returns(id)  ON DELETE CASCADE,
  invoice_line_id UUID          NOT NULL REFERENCES invoice_lines(id),
  product_id      UUID          NOT NULL REFERENCES products(id),
  quantity        NUMERIC(12,3) NOT NULL,
  unit_price      NUMERIC(12,2) NOT NULL,
  tax_rate        NUMERIC(5,2)  NOT NULL DEFAULT 0,
  tax_amount      NUMERIC(12,2) NOT NULL DEFAULT 0,
  line_total      NUMERIC(12,2) NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS sales_return_refunds (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_return_id UUID          NOT NULL REFERENCES sales_returns(id) ON DELETE CASCADE,
  mode            payment_mode  NOT NULL,
  amount          NUMERIC(12,2) NOT NULL,
  reference       TEXT,
  refunded_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- ================================================================
-- SECTION 13 — PURCHASE RETURNS
-- ================================================================
CREATE TABLE IF NOT EXISTS purchase_returns (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       UUID          NOT NULL REFERENCES shops(id),
  return_number TEXT          NOT NULL,
  purchase_id   UUID          NOT NULL REFERENCES purchases(id),
  supplier_id   UUID          REFERENCES suppliers(id),
  status        return_status NOT NULL DEFAULT 'pending',
  return_date   DATE          NOT NULL DEFAULT CURRENT_DATE,
  total_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
  reason        TEXT,
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, return_number)
);

CREATE TABLE IF NOT EXISTS purchase_return_lines (
  id                 UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_return_id UUID          NOT NULL REFERENCES purchase_returns(id) ON DELETE CASCADE,
  purchase_line_id   UUID          NOT NULL REFERENCES purchase_lines(id),
  product_id         UUID          NOT NULL REFERENCES products(id),
  quantity           NUMERIC(12,3) NOT NULL,
  unit_cost          NUMERIC(12,2) NOT NULL,
  line_total         NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- ================================================================
-- SECTION 14 — OFFLINE POS SYNC
-- ================================================================
CREATE TABLE IF NOT EXISTS offline_sync_log (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id         UUID        NOT NULL REFERENCES shops(id),
  offline_number  TEXT        NOT NULL,
  final_number    TEXT,
  payload         JSONB       NOT NULL,
  status          sync_status NOT NULL DEFAULT 'pending',
  conflict_reason TEXT,
  synced_at       TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_offline_sync_status ON offline_sync_log (status)  WHERE status != 'synced';
CREATE INDEX IF NOT EXISTS idx_offline_sync_shop   ON offline_sync_log (shop_id, created_at DESC);

-- ================================================================
-- SECTION 15 — IDEMPOTENCY KEYS
-- ================================================================
CREATE TABLE IF NOT EXISTS idempotency_keys (
  key        TEXT        PRIMARY KEY,
  endpoint   TEXT        NOT NULL,
  response   JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '24 hours'
);

CREATE INDEX IF NOT EXISTS idx_idempotency_expires ON idempotency_keys (expires_at);

-- ================================================================
-- SECTION 16 — AI / SMART INVENTORY
-- ================================================================
CREATE TABLE IF NOT EXISTS product_inventory_metrics (
  id                     UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id                UUID          NOT NULL REFERENCES shops(id),
  product_id             UUID          NOT NULL REFERENCES products(id),
  demand_velocity        NUMERIC(10,3) NOT NULL DEFAULT 0,
  days_of_inventory_left NUMERIC(10,1),
  is_dead_stock          BOOLEAN       NOT NULL DEFAULT FALSE,
  dead_stock_since       DATE,
  last_sold_at           DATE,
  calculated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, product_id)
);

CREATE TABLE IF NOT EXISTS reorder_suggestions (
  id            UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       UUID           NOT NULL REFERENCES shops(id),
  product_id    UUID           NOT NULL REFERENCES products(id),
  suggested_qty NUMERIC(12,3)  NOT NULL,
  reason        TEXT,
  status        reorder_status NOT NULL DEFAULT 'suggested',
  reviewed_by   UUID           REFERENCES users(id),
  reviewed_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- ================================================================
-- SECTION 17 — REPORTING
-- ================================================================
CREATE TABLE IF NOT EXISTS daily_product_sales_summary (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       UUID          NOT NULL REFERENCES shops(id),
  product_id    UUID          NOT NULL REFERENCES products(id),
  summary_date  DATE          NOT NULL,
  qty_sold      NUMERIC(12,3) NOT NULL DEFAULT 0,
  gross_revenue NUMERIC(14,2) NOT NULL DEFAULT 0,
  tax_collected NUMERIC(14,2) NOT NULL DEFAULT 0,
  net_revenue   NUMERIC(14,2) NOT NULL DEFAULT 0,
  invoice_count INT           NOT NULL DEFAULT 0,
  UNIQUE (shop_id, product_id, summary_date)
);

CREATE INDEX IF NOT EXISTS idx_daily_summary_date    ON daily_product_sales_summary (summary_date DESC);
CREATE INDEX IF NOT EXISTS idx_daily_summary_product ON daily_product_sales_summary (product_id, summary_date DESC);

-- ================================================================
-- SECTION 18 — AUDIT LOG
-- ================================================================
CREATE TABLE IF NOT EXISTS audit_logs (
  id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name TEXT         NOT NULL,
  record_id  UUID         NOT NULL,
  action     audit_action NOT NULL,
  old_values JSONB,
  new_values JSONB,
  changed_by UUID         REFERENCES users(id),
  changed_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  ip_address INET,
  note       TEXT
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_record ON audit_logs (table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_user   ON audit_logs (changed_by, changed_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_date   ON audit_logs (changed_at DESC);

-- ================================================================
-- SECTION 19 — TRIGGERS
-- ================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

DO $$ BEGIN CREATE TRIGGER trg_tenant_profile_updated_at BEFORE UPDATE ON tenant_profile FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TRIGGER trg_shops_updated_at     BEFORE UPDATE ON shops     FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TRIGGER trg_users_updated_at     BEFORE UPDATE ON users     FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_updated_at  BEFORE UPDATE ON products  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TRIGGER trg_customers_updated_at BEFORE UPDATE ON customers FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TRIGGER trg_invoices_updated_at  BEFORE UPDATE ON invoices  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TRIGGER trg_purchases_updated_at BEFORE UPDATE ON purchases FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TRIGGER trg_suppliers_updated_at BEFORE UPDATE ON suppliers FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE OR REPLACE FUNCTION enforce_books_lock()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE lock_date DATE;
BEGIN
  SELECT books_locked_till INTO lock_date FROM tenant_profile LIMIT 1;
  IF lock_date IS NOT NULL AND NEW.entry_date <= lock_date THEN
    RAISE EXCEPTION 'Books are locked until %. Cannot post entry dated %.', lock_date, NEW.entry_date;
  END IF;
  RETURN NEW;
END;
$$;

DO $$ BEGIN CREATE TRIGGER trg_journal_books_lock BEFORE INSERT ON journal_entries FOR EACH ROW EXECUTE FUNCTION enforce_books_lock();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE OR REPLACE FUNCTION validate_journal_balance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  total_debit  NUMERIC;
  total_credit NUMERIC;
BEGIN
  IF NEW.status = 'posted' AND OLD.status = 'draft' THEN
    SELECT COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
    INTO total_debit, total_credit
    FROM journal_entry_lines WHERE journal_entry_id = NEW.id;

    IF total_debit <> total_credit THEN
      RAISE EXCEPTION 'Journal % unbalanced: debit=% credit=%', NEW.id, total_debit, total_credit;
    END IF;
    NEW.posted_at = NOW();
  END IF;
  RETURN NEW;
END;
$$;

DO $$ BEGIN CREATE TRIGGER trg_journal_balance BEFORE UPDATE ON journal_entries FOR EACH ROW EXECUTE FUNCTION validate_journal_balance();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE OR REPLACE FUNCTION validate_return_quantity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  original_qty     NUMERIC;
  already_returned NUMERIC;
BEGIN
  SELECT quantity INTO original_qty FROM invoice_lines WHERE id = NEW.invoice_line_id;

  SELECT COALESCE(SUM(srl.quantity), 0) INTO already_returned
  FROM sales_return_lines srl
  JOIN sales_returns sr ON sr.id = srl.sales_return_id
  WHERE srl.invoice_line_id = NEW.invoice_line_id
    AND sr.status != 'pending';

  IF (already_returned + NEW.quantity) > original_qty THEN
    RAISE EXCEPTION 'Return qty % exceeds original qty % (already returned: %)',
      NEW.quantity, original_qty, already_returned;
  END IF;
  RETURN NEW;
END;
$$;

DO $$ BEGIN CREATE TRIGGER trg_validate_return_qty BEFORE INSERT ON sales_return_lines FOR EACH ROW EXECUTE FUNCTION validate_return_quantity();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ================================================================
-- SECTION 20 — SEED DATA
-- ================================================================
INSERT INTO chart_of_accounts (code, name, type, is_system) VALUES
  ('1001', 'Cash in Hand',        'asset',     TRUE),
  ('1002', 'Bank Account',        'asset',     TRUE),
  ('1100', 'Accounts Receivable', 'asset',     TRUE),
  ('1200', 'Inventory Asset',     'asset',     TRUE),
  ('2001', 'Accounts Payable',    'liability', TRUE),
  ('2100', 'GST Payable',         'liability', TRUE),
  ('2101', 'TCS Payable',         'liability', TRUE),
  ('3001', 'Owner Equity',        'equity',    TRUE),
  ('4001', 'Sales Revenue',       'revenue',   TRUE),
  ('4002', 'Other Income',        'revenue',   TRUE),
  ('5001', 'Cost of Goods Sold',  'expense',   TRUE),
  ('5002', 'Freight & Logistics', 'expense',   TRUE),
  ('5003', 'Operating Expenses',  'expense',   TRUE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO tax_rates (name, rate, tax_type) VALUES
  ('GST 0%',    0.00, 'GST'),
  ('GST 5%',    5.00, 'GST'),
  ('GST 12%',  12.00, 'GST'),
  ('GST 18%',  18.00, 'GST'),
  ('GST 28%',  28.00, 'GST'),
  ('TCS 0.1%',  0.10, 'TCS')
ON CONFLICT DO NOTHING;

INSERT INTO customer_groups (name) VALUES
  ('Retail'), ('Wholesale'), ('Distributor'), ('VIP')
ON CONFLICT (name) DO NOTHING;

INSERT INTO price_lists (name, tier) VALUES
  ('Standard Retail', 'retail'),
  ('Wholesale',       'wholesale'),
  ('Distributor',     'distributor')
ON CONFLICT DO NOTHING;

-- ================================================================
-- RECORD MIGRATION
-- ================================================================
INSERT INTO migrations (filename) VALUES ('tenant.init.sql')
ON CONFLICT (filename) DO NOTHING;