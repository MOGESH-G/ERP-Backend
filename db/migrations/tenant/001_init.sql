-- ────────────────────────────────────────────
-- EXTENSIONS
-- ────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- fuzzy product / customer search
CREATE EXTENSION IF NOT EXISTS "btree_gist"; -- exclusion constraints for date ranges


-- ────────────────────────────────────────────
-- ENUMS
-- ────────────────────────────────────────────
CREATE TYPE account_type    AS ENUM ('asset', 'liability', 'equity', 'revenue', 'expense');
CREATE TYPE journal_status  AS ENUM ('draft', 'posted', 'reversed');
CREATE TYPE invoice_status  AS ENUM ('draft', 'confirmed', 'paid', 'cancelled', 'offline_pending');
CREATE TYPE payment_mode    AS ENUM ('cash', 'upi', 'card', 'credit_note', 'split');
CREATE TYPE return_status   AS ENUM ('pending', 'approved', 'refunded', 'post_gst_tagged');
CREATE TYPE purchase_status AS ENUM ('draft', 'received', 'billed', 'partially_returned', 'returned');
CREATE TYPE stock_movement  AS ENUM ('purchase', 'sale', 'return_in', 'return_out', 'adjustment', 'transfer', 'opening');
CREATE TYPE price_tier      AS ENUM ('retail', 'wholesale', 'distributor', 'promotional');
CREATE TYPE user_role       AS ENUM ('shop_manager', 'cashier', 'accountant', 'viewer');
CREATE TYPE loyalty_tx_type AS ENUM ('earn', 'redeem', 'expire', 'adjust');
CREATE TYPE reorder_status  AS ENUM ('suggested', 'approved', 'ordered', 'received', 'dismissed');
CREATE TYPE sync_status     AS ENUM ('pending', 'synced', 'failed', 'conflict');
CREATE TYPE audit_action    AS ENUM ('insert', 'update', 'delete', 'post', 'reverse', 'lock');


-- ================================================================
-- SECTION 1 — TENANT PROFILE (single row)
-- ================================================================
-- Stores this tenant's own identity & global settings.

CREATE TABLE tenant_profile (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name                 TEXT        NOT NULL,
  gst_number           TEXT        UNIQUE,
  pan_number           TEXT,
  address              TEXT,
  phone                TEXT,
  email                TEXT,
  currency             CHAR(3)     NOT NULL DEFAULT 'INR',
  books_locked_till    DATE,                         -- §8 prevent backdated edits
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 2 — SHOPS
-- ================================================================
-- A tenant can operate multiple physical shops.

CREATE TABLE shops (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT        NOT NULL,
  address      TEXT,
  phone        TEXT,
  gst_number   TEXT,                                 -- shop-level GSTIN if different
  is_active    BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 3 — USERS
-- ================================================================

CREATE TABLE users (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       UUID        REFERENCES shops(id) ON DELETE SET NULL, -- NULL = all shops
  name          TEXT        NOT NULL,
  email         TEXT        NOT NULL UNIQUE,
  password_hash TEXT        NOT NULL,
  role          user_role   NOT NULL DEFAULT 'cashier',
  is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 4 — FINANCIAL ACCOUNTING LAYER  §1
-- ================================================================

-- 4.1 Chart of Accounts (double-entry bookkeeping)
CREATE TABLE chart_of_accounts (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  code        TEXT         NOT NULL UNIQUE,           -- e.g. '1001'
  name        TEXT         NOT NULL,                  -- e.g. 'Cash in Hand'
  type        account_type NOT NULL,
  parent_id   UUID         REFERENCES chart_of_accounts(id),
  is_system   BOOLEAN      NOT NULL DEFAULT FALSE,    -- system accounts cannot be deleted
  is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- 4.2 Journal Entry Header
CREATE TABLE journal_entries (
  id           UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_type     TEXT           NOT NULL,               -- 'invoice'|'purchase'|'return'|'payment'|'expense'
  ref_id       UUID           NOT NULL,               -- points to source document
  entry_date   DATE           NOT NULL DEFAULT CURRENT_DATE,
  description  TEXT,
  status       journal_status NOT NULL DEFAULT 'draft',
  posted_at    TIMESTAMPTZ,
  posted_by    UUID           REFERENCES users(id),
  reversed_by  UUID           REFERENCES journal_entries(id), -- §5 reversal link
  created_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- 4.3 Journal Entry Lines (debit / credit rows)
CREATE TABLE journal_entry_lines (
  id                UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_entry_id  UUID    NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  account_id        UUID    NOT NULL REFERENCES chart_of_accounts(id),
  debit             NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (debit  >= 0),
  credit            NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  description       TEXT,
  CHECK (debit > 0 OR credit > 0),                   -- at least one side must be non-zero
  CHECK (NOT (debit > 0 AND credit > 0))             -- cannot be both in same line
);


-- ================================================================
-- SECTION 5 — TAX RATES
-- ================================================================

CREATE TABLE tax_rates (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL,                   -- e.g. 'GST 18%'
  rate        NUMERIC(5,2) NOT NULL,                  -- e.g. 18.00
  tax_type    TEXT        NOT NULL DEFAULT 'GST',     -- GST | TCS | TDS
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 6 — SUPPLIERS
-- ================================================================

CREATE TABLE suppliers (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT        NOT NULL,
  gst_number   TEXT,
  phone        TEXT,
  email        TEXT,
  address      TEXT,
  is_active    BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 7 — PRODUCTS & INVENTORY
-- ================================================================

-- 7.1 Categories
CREATE TABLE categories (
  id         UUID  PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT  NOT NULL UNIQUE,
  parent_id  UUID  REFERENCES categories(id)
);

-- 7.2 Products (master catalogue)
CREATE TABLE products (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  sku                  TEXT        NOT NULL UNIQUE,
  name                 TEXT        NOT NULL,
  description          TEXT,
  category_id          UUID        REFERENCES categories(id),
  tax_rate_id          UUID        REFERENCES tax_rates(id),
  unit                 TEXT        NOT NULL DEFAULT 'pcs',  -- pcs | kg | ltr | box
  barcode              TEXT,
  hsn_code             TEXT,                               -- §8 GST compliance
  base_price           NUMERIC(12,2) NOT NULL DEFAULT 0,
  cost_price           NUMERIC(12,2) NOT NULL DEFAULT 0,   -- updated on each purchase
  is_active            BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_products_name_trgm ON products USING GIN (name gin_trgm_ops);
CREATE INDEX idx_products_barcode   ON products (barcode) WHERE barcode IS NOT NULL;

-- 7.3 Inventory per shop
CREATE TABLE inventory (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id         UUID        NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
  product_id      UUID        NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  quantity        NUMERIC(12,3) NOT NULL DEFAULT 0,
  reorder_point   NUMERIC(12,3) NOT NULL DEFAULT 0,
  reorder_qty     NUMERIC(12,3) NOT NULL DEFAULT 0,
  landed_cost     NUMERIC(12,2) NOT NULL DEFAULT 0,        -- §4 landed cost per unit
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, product_id)
);

-- 7.4 Stock Movement Ledger (immutable log)
CREATE TABLE stock_movements (
  id           UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id      UUID           NOT NULL REFERENCES shops(id),
  product_id   UUID           NOT NULL REFERENCES products(id),
  movement     stock_movement NOT NULL,
  quantity     NUMERIC(12,3)  NOT NULL,                    -- positive = in, negative = out
  ref_type     TEXT,                                       -- 'invoice'|'purchase'|'return'|'adjustment'
  ref_id       UUID,
  note         TEXT,
  created_by   UUID           REFERENCES users(id),
  created_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_stock_movements_product ON stock_movements (product_id, created_at DESC);
CREATE INDEX idx_stock_movements_shop    ON stock_movements (shop_id, created_at DESC);


-- ================================================================
-- SECTION 8 — PRICING & PRICE LISTS  §3
-- ================================================================

-- 8.1 Price List Headers
CREATE TABLE price_lists (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT        NOT NULL,
  tier         price_tier  NOT NULL DEFAULT 'retail',
  valid_from   DATE,                                       -- §3 time-bound promotions
  valid_to     DATE,
  is_active    BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- prevent overlapping active promotions for same tier
  CONSTRAINT no_overlapping_promo EXCLUDE USING GIST (
    tier WITH =,
    daterange(valid_from, valid_to, '[]') WITH &&
  ) WHERE (valid_from IS NOT NULL AND valid_to IS NOT NULL AND is_active = TRUE)
);

-- 8.2 Price List Items
CREATE TABLE price_list_items (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  price_list_id UUID          NOT NULL REFERENCES price_lists(id) ON DELETE CASCADE,
  product_id    UUID          NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  price         NUMERIC(12,2) NOT NULL,
  UNIQUE (price_list_id, product_id)
);


-- ================================================================
-- SECTION 9 — CUSTOMERS  §6
-- ================================================================

-- 9.1 Customer Groups (for pricing & segmentation)
CREATE TABLE customer_groups (
  id            UUID  PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT  NOT NULL UNIQUE,                    -- 'Retail' | 'Wholesale' | 'VIP'
  price_list_id UUID  REFERENCES price_lists(id)          -- §3 group-based pricing
);

-- 9.2 Customer Master (tenant-level)
CREATE TABLE customers (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name                  TEXT        NOT NULL,
  phone                 TEXT,
  email                 TEXT,
  gst_number            TEXT,                             -- for B2B invoicing
  address               TEXT,
  customer_group_id     UUID        REFERENCES customer_groups(id),
  loyalty_points        NUMERIC(10,2) NOT NULL DEFAULT 0, -- §6 global loyalty balance
  whatsapp_opt_in       BOOLEAN     NOT NULL DEFAULT FALSE, -- §6 marketing compliance
  sms_opt_in            BOOLEAN     NOT NULL DEFAULT FALSE,
  is_active             BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_customers_phone ON customers (phone) WHERE phone IS NOT NULL;
CREATE INDEX idx_customers_name_trgm ON customers USING GIN (name gin_trgm_ops);

-- 9.3 Per-Shop Customer Stats  §6
CREATE TABLE customer_shop_stats (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id      UUID          NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  shop_id          UUID          NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  total_invoices   INT           NOT NULL DEFAULT 0,
  total_spent      NUMERIC(14,2) NOT NULL DEFAULT 0,
  last_visited_at  TIMESTAMPTZ,
  UNIQUE (customer_id, shop_id)
);

-- 9.4 Loyalty Transaction Log
CREATE TABLE loyalty_transactions (
  id            UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id   UUID            NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  shop_id       UUID            REFERENCES shops(id),
  type          loyalty_tx_type NOT NULL,
  points        NUMERIC(10,2)   NOT NULL,
  ref_type      TEXT,                                     -- 'invoice' | 'manual'
  ref_id        UUID,
  note          TEXT,
  created_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 10 — INVOICES (Sales)
-- ================================================================

-- 10.1 Invoice Header
CREATE TABLE invoices (
  id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id           UUID          NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
  invoice_number    TEXT          NOT NULL,               -- final: INV-YYYY-NNNNN
  offline_number    TEXT,                                 -- §2 OFF- prefix temp number
  status            invoice_status NOT NULL DEFAULT 'draft',
  customer_id       UUID          REFERENCES customers(id),
  user_id           UUID          REFERENCES users(id),
  price_list_id     UUID          REFERENCES price_lists(id),
  invoice_date      DATE          NOT NULL DEFAULT CURRENT_DATE,
  due_date          DATE,
  subtotal          NUMERIC(14,2) NOT NULL DEFAULT 0,
  discount_amount   NUMERIC(14,2) NOT NULL DEFAULT 0,
  taxable_amount    NUMERIC(14,2) NOT NULL DEFAULT 0,
  tax_amount        NUMERIC(14,2) NOT NULL DEFAULT 0,
  total_amount      NUMERIC(14,2) NOT NULL DEFAULT 0,
  paid_amount       NUMERIC(14,2) NOT NULL DEFAULT 0,
  payment_mode      payment_mode,
  -- §8 GST e-invoicing fields
  irn               TEXT,                                 -- Invoice Reference Number
  ack_no            TEXT,
  ack_date          TIMESTAMPTZ,
  eway_bill_no      TEXT,
  -- §8 TCS/TDS for B2B
  tcs_rate          NUMERIC(5,2),
  tcs_amount        NUMERIC(12,2),
  tds_rate          NUMERIC(5,2),
  tds_amount        NUMERIC(12,2),
  -- §2 offline sync
  is_offline        BOOLEAN       NOT NULL DEFAULT FALSE,
  synced_at         TIMESTAMPTZ,
  idempotency_key   TEXT          UNIQUE,                 -- §10 prevent duplicates
  notes             TEXT,
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, invoice_number)
);

CREATE INDEX idx_invoices_customer    ON invoices (customer_id);
CREATE INDEX idx_invoices_date        ON invoices (invoice_date DESC);
CREATE INDEX idx_invoices_shop_date   ON invoices (shop_id, invoice_date DESC);
CREATE INDEX idx_invoices_status      ON invoices (status) WHERE status != 'paid';

-- 10.2 Invoice Line Items
CREATE TABLE invoice_lines (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id      UUID          NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  product_id      UUID          NOT NULL REFERENCES products(id),
  quantity        NUMERIC(12,3) NOT NULL,
  unit_price      NUMERIC(12,2) NOT NULL,                 -- price at time of sale
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

-- 10.3 Invoice Payments (supports split payments §5)
CREATE TABLE invoice_payments (
  id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id   UUID          NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  mode         payment_mode  NOT NULL,
  amount       NUMERIC(12,2) NOT NULL,
  reference    TEXT,                                      -- UPI txn ID / card last4
  paid_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 11 — PURCHASES  §4
-- ================================================================

-- 11.1 Purchase Header
CREATE TABLE purchases (
  id                    UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id               UUID            NOT NULL REFERENCES shops(id),
  supplier_id           UUID            REFERENCES suppliers(id),
  purchase_number       TEXT            NOT NULL,
  status                purchase_status NOT NULL DEFAULT 'draft',
  purchase_date         DATE            NOT NULL DEFAULT CURRENT_DATE,
  subtotal              NUMERIC(14,2)   NOT NULL DEFAULT 0,
  tax_amount            NUMERIC(14,2)   NOT NULL DEFAULT 0,
  -- §4 Landed cost fields
  freight               NUMERIC(12,2)   NOT NULL DEFAULT 0,
  additional_charges    NUMERIC(12,2)   NOT NULL DEFAULT 0,
  other_costs           NUMERIC(12,2)   NOT NULL DEFAULT 0,
  total_landed_cost     NUMERIC(14,2)   NOT NULL DEFAULT 0, -- computed
  total_amount          NUMERIC(14,2)   NOT NULL DEFAULT 0,
  supplier_invoice_no   TEXT,
  notes                 TEXT,
  created_by            UUID            REFERENCES users(id),
  created_at            TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, purchase_number)
);

-- 11.2 Purchase Line Items
CREATE TABLE purchase_lines (
  id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_id           UUID          NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
  product_id            UUID          NOT NULL REFERENCES products(id),
  quantity              NUMERIC(12,3) NOT NULL,
  unit_cost             NUMERIC(12,2) NOT NULL,
  tax_rate              NUMERIC(5,2)  NOT NULL DEFAULT 0,
  tax_amount            NUMERIC(12,2) NOT NULL DEFAULT 0,
  line_total            NUMERIC(12,2) NOT NULL DEFAULT 0,
  -- §4 Landed cost allocation (proportional)
  landed_cost_per_unit  NUMERIC(12,4) NOT NULL DEFAULT 0,
  -- §4 Purchase price variance
  prev_cost_price       NUMERIC(12,2),                   -- cost before this purchase
  purchase_variance     NUMERIC(12,2),                   -- unit_cost - prev_cost_price
  suggested_sell_price  NUMERIC(12,2),                   -- §4 based on margin rules
  batch_number          TEXT,
  expiry_date           DATE
);


-- ================================================================
-- SECTION 12 — SALES RETURNS  §5
-- ================================================================

CREATE TABLE sales_returns (
  id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id           UUID          NOT NULL REFERENCES shops(id),
  return_number     TEXT          NOT NULL,
  invoice_id        UUID          NOT NULL REFERENCES invoices(id),
  customer_id       UUID          REFERENCES customers(id),
  status            return_status NOT NULL DEFAULT 'pending',
  return_date       DATE          NOT NULL DEFAULT CURRENT_DATE,
  subtotal          NUMERIC(14,2) NOT NULL DEFAULT 0,
  tax_amount        NUMERIC(14,2) NOT NULL DEFAULT 0,    -- §5 reversed on return
  total_amount      NUMERIC(14,2) NOT NULL DEFAULT 0,
  refund_mode       payment_mode,
  refund_amount     NUMERIC(14,2) NOT NULL DEFAULT 0,
  -- §8 post GST filing tag
  is_post_gst       BOOLEAN       NOT NULL DEFAULT FALSE,
  reason            TEXT,
  processed_by      UUID          REFERENCES users(id),
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, return_number)
);

CREATE TABLE sales_return_lines (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_return_id  UUID          NOT NULL REFERENCES sales_returns(id) ON DELETE CASCADE,
  invoice_line_id  UUID          NOT NULL REFERENCES invoice_lines(id),
  product_id       UUID          NOT NULL REFERENCES products(id),
  quantity         NUMERIC(12,3) NOT NULL,               -- §5 validated against original qty
  unit_price       NUMERIC(12,2) NOT NULL,
  tax_rate         NUMERIC(5,2)  NOT NULL DEFAULT 0,
  tax_amount       NUMERIC(12,2) NOT NULL DEFAULT 0,
  line_total       NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Split refunds §5
CREATE TABLE sales_return_refunds (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_return_id UUID          NOT NULL REFERENCES sales_returns(id) ON DELETE CASCADE,
  mode            payment_mode  NOT NULL,
  amount          NUMERIC(12,2) NOT NULL,
  reference       TEXT,
  refunded_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 13 — PURCHASE RETURNS  §5
-- ================================================================

CREATE TABLE purchase_returns (
  id               UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id          UUID            NOT NULL REFERENCES shops(id),
  return_number    TEXT            NOT NULL,
  purchase_id      UUID            NOT NULL REFERENCES purchases(id),
  supplier_id      UUID            REFERENCES suppliers(id),
  status           return_status   NOT NULL DEFAULT 'pending',
  return_date      DATE            NOT NULL DEFAULT CURRENT_DATE,
  total_amount     NUMERIC(14,2)   NOT NULL DEFAULT 0,
  reason           TEXT,
  created_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, return_number)
);

CREATE TABLE purchase_return_lines (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_return_id  UUID          NOT NULL REFERENCES purchase_returns(id) ON DELETE CASCADE,
  purchase_line_id    UUID          NOT NULL REFERENCES purchase_lines(id),
  product_id          UUID          NOT NULL REFERENCES products(id),
  quantity            NUMERIC(12,3) NOT NULL,
  unit_cost           NUMERIC(12,2) NOT NULL,
  line_total          NUMERIC(12,2) NOT NULL DEFAULT 0
);


-- ================================================================
-- SECTION 14 — OFFLINE POS SYNC  §2
-- ================================================================

CREATE TABLE offline_sync_log (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id          UUID        NOT NULL REFERENCES shops(id),
  offline_number   TEXT        NOT NULL,                 -- OFF- prefix
  final_number     TEXT,                                 -- assigned after sync
  payload          JSONB       NOT NULL,                 -- full invoice payload
  status           sync_status NOT NULL DEFAULT 'pending',
  conflict_reason  TEXT,                                 -- §2 stock conflict detail
  synced_at        TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_offline_sync_status ON offline_sync_log (status) WHERE status != 'synced';
CREATE INDEX idx_offline_sync_shop   ON offline_sync_log (shop_id, created_at DESC);


-- ================================================================
-- SECTION 15 — IDEMPOTENCY KEYS  §10
-- ================================================================

CREATE TABLE idempotency_keys (
  key          TEXT        PRIMARY KEY,
  endpoint     TEXT        NOT NULL,
  response     JSONB,                                    -- cached response
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at   TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '24 hours'
);

CREATE INDEX idx_idempotency_expires ON idempotency_keys (expires_at);


-- ================================================================
-- SECTION 16 — AI / SMART INVENTORY  §9
-- ================================================================

-- 16.1 Per-product velocity & health metrics (updated by background job)
CREATE TABLE product_inventory_metrics (
  id                     UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id                UUID          NOT NULL REFERENCES shops(id),
  product_id             UUID          NOT NULL REFERENCES products(id),
  demand_velocity        NUMERIC(10,3) NOT NULL DEFAULT 0, -- units sold per day (rolling 30d)
  days_of_inventory_left NUMERIC(10,1),                   -- current_stock / velocity
  is_dead_stock          BOOLEAN       NOT NULL DEFAULT FALSE, -- no movement threshold
  dead_stock_since       DATE,
  last_sold_at           DATE,
  calculated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, product_id)
);

-- 16.2 Reorder Suggestions (auto-generated by AI engine)
CREATE TABLE reorder_suggestions (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id          UUID          NOT NULL REFERENCES shops(id),
  product_id       UUID          NOT NULL REFERENCES products(id),
  suggested_qty    NUMERIC(12,3) NOT NULL,
  reason           TEXT,                                  -- 'low_stock' | 'predicted_demand'
  status           reorder_status NOT NULL DEFAULT 'suggested',
  reviewed_by      UUID          REFERENCES users(id),
  reviewed_at      TIMESTAMPTZ,
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 17 — REPORTING OPTIMISATION  §7
-- ================================================================

-- Daily aggregated sales summary (pre-aggregated for large tenants)
CREATE TABLE daily_product_sales_summary (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id         UUID          NOT NULL REFERENCES shops(id),
  product_id      UUID          NOT NULL REFERENCES products(id),
  summary_date    DATE          NOT NULL,
  qty_sold        NUMERIC(12,3) NOT NULL DEFAULT 0,
  gross_revenue   NUMERIC(14,2) NOT NULL DEFAULT 0,
  tax_collected   NUMERIC(14,2) NOT NULL DEFAULT 0,
  net_revenue     NUMERIC(14,2) NOT NULL DEFAULT 0,
  invoice_count   INT           NOT NULL DEFAULT 0,
  UNIQUE (shop_id, product_id, summary_date)
);

CREATE INDEX idx_daily_summary_date    ON daily_product_sales_summary (summary_date DESC);
CREATE INDEX idx_daily_summary_product ON daily_product_sales_summary (product_id, summary_date DESC);


-- ================================================================
-- SECTION 18 — AUDIT LOG  §8
-- ================================================================

CREATE TABLE audit_logs (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name   TEXT         NOT NULL,
  record_id    UUID         NOT NULL,
  action       audit_action NOT NULL,
  old_values   JSONB,
  new_values   JSONB,
  changed_by   UUID         REFERENCES users(id),
  changed_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  ip_address   INET,
  note         TEXT
);

CREATE INDEX idx_audit_logs_record  ON audit_logs (table_name, record_id);
CREATE INDEX idx_audit_logs_user    ON audit_logs (changed_by, changed_at DESC);
CREATE INDEX idx_audit_logs_date    ON audit_logs (changed_at DESC);


-- ================================================================
-- SECTION 19 — SYSTEM SEED DATA
-- ================================================================

-- Default Chart of Accounts
INSERT INTO chart_of_accounts (code, name, type, is_system) VALUES
  ('1001', 'Cash in Hand',          'asset',     TRUE),
  ('1002', 'Bank Account',          'asset',     TRUE),
  ('1100', 'Accounts Receivable',   'asset',     TRUE),
  ('1200', 'Inventory Asset',       'asset',     TRUE),
  ('2001', 'Accounts Payable',      'liability', TRUE),
  ('2100', 'GST Payable',           'liability', TRUE),
  ('2101', 'TCS Payable',           'liability', TRUE),
  ('3001', 'Owner Equity',          'equity',    TRUE),
  ('4001', 'Sales Revenue',         'revenue',   TRUE),
  ('4002', 'Other Income',          'revenue',   TRUE),
  ('5001', 'Cost of Goods Sold',    'expense',   TRUE),
  ('5002', 'Freight & Logistics',   'expense',   TRUE),
  ('5003', 'Operating Expenses',    'expense',   TRUE);

-- Default Tax Rates
INSERT INTO tax_rates (name, rate, tax_type) VALUES
  ('GST 0%',   0.00, 'GST'),
  ('GST 5%',   5.00, 'GST'),
  ('GST 12%', 12.00, 'GST'),
  ('GST 18%', 18.00, 'GST'),
  ('GST 28%', 28.00, 'GST'),
  ('TCS 0.1%', 0.10, 'TCS');

-- Default Customer Groups
INSERT INTO customer_groups (name) VALUES
  ('Retail'),
  ('Wholesale'),
  ('Distributor'),
  ('VIP');


-- ================================================================
-- SECTION 20 — HELPER FUNCTIONS & TRIGGERS
-- ================================================================

-- 20.1 Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tenantprofile_updated_at  BEFORE UPDATE ON tenant_profile   FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_shops_updated_at          BEFORE UPDATE ON shops            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_users_updated_at          BEFORE UPDATE ON users            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_products_updated_at       BEFORE UPDATE ON products         FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_customers_updated_at      BEFORE UPDATE ON customers        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_invoices_updated_at       BEFORE UPDATE ON invoices         FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_purchases_updated_at      BEFORE UPDATE ON purchases        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_suppliers_updated_at      BEFORE UPDATE ON suppliers        FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 20.2 Enforce books lock — block backdated financial inserts
CREATE OR REPLACE FUNCTION enforce_books_lock()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  lock_date DATE;
BEGIN
  SELECT books_locked_till INTO lock_date FROM tenant_profile LIMIT 1;
  IF lock_date IS NOT NULL AND NEW.entry_date <= lock_date THEN
    RAISE EXCEPTION 'Books are locked until %. Cannot post entry dated %.', lock_date, NEW.entry_date;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_journal_books_lock
  BEFORE INSERT ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION enforce_books_lock();

-- 20.3 Enforce double-entry balance on journal post
CREATE OR REPLACE FUNCTION validate_journal_balance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  total_debit  NUMERIC;
  total_credit NUMERIC;
BEGIN
  IF NEW.status = 'posted' AND OLD.status = 'draft' THEN
    SELECT
      COALESCE(SUM(debit),  0),
      COALESCE(SUM(credit), 0)
    INTO total_debit, total_credit
    FROM journal_entry_lines
    WHERE journal_entry_id = NEW.id;

    IF total_debit <> total_credit THEN
      RAISE EXCEPTION 'Journal entry % is unbalanced: debit=% credit=%', NEW.id, total_debit, total_credit;
    END IF;
    NEW.posted_at = NOW();
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_journal_balance
  BEFORE UPDATE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION validate_journal_balance();

-- 20.4 Validate return quantity does not exceed original sold quantity  §5
CREATE OR REPLACE FUNCTION validate_return_quantity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  original_qty   NUMERIC;
  already_returned NUMERIC;
BEGIN
  SELECT quantity INTO original_qty
  FROM invoice_lines WHERE id = NEW.invoice_line_id;

  SELECT COALESCE(SUM(srl.quantity), 0) INTO already_returned
  FROM sales_return_lines srl
  JOIN sales_returns sr ON sr.id = srl.sales_return_id-- ================================================================
-- TENANT DATABASE — Init Script
-- File    : 001_init.sql
-- Purpose : Full schema for a single tenant's operational DB.
--           Run once at tenant provisioning time.
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
-- Tracks which migration files have been applied
-- to THIS tenant DB. Used by the migration runner.
-- ────────────────────────────────────────────
CREATE TABLE migrations (
  filename    TEXT        PRIMARY KEY,
  applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ────────────────────────────────────────────
-- ENUMS
-- ────────────────────────────────────────────
CREATE TYPE account_type    AS ENUM ('asset', 'liability', 'equity', 'revenue', 'expense');
CREATE TYPE journal_status  AS ENUM ('draft', 'posted', 'reversed');
CREATE TYPE invoice_status  AS ENUM ('draft', 'confirmed', 'paid', 'cancelled', 'offline_pending');
CREATE TYPE payment_mode    AS ENUM ('cash', 'upi', 'card', 'credit_note', 'split');
CREATE TYPE return_status   AS ENUM ('pending', 'approved', 'refunded', 'post_gst_tagged');
CREATE TYPE purchase_status AS ENUM ('draft', 'received', 'billed', 'partially_returned', 'returned');
CREATE TYPE stock_movement  AS ENUM ('purchase', 'sale', 'return_in', 'return_out', 'adjustment', 'transfer', 'opening');
CREATE TYPE price_tier      AS ENUM ('retail', 'wholesale', 'distributor', 'promotional');
CREATE TYPE user_role       AS ENUM ('shop_manager', 'cashier', 'accountant', 'viewer');
CREATE TYPE loyalty_tx_type AS ENUM ('earn', 'redeem', 'expire', 'adjust');
CREATE TYPE reorder_status  AS ENUM ('suggested', 'approved', 'ordered', 'received', 'dismissed');
CREATE TYPE sync_status     AS ENUM ('pending', 'synced', 'failed', 'conflict');
CREATE TYPE audit_action    AS ENUM ('insert', 'update', 'delete', 'post', 'reverse', 'lock');


-- ================================================================
-- SECTION 1 — TENANT PROFILE  (single row)
-- ================================================================
CREATE TABLE tenant_profile (
  id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name               TEXT        NOT NULL,
  gst_number         TEXT        UNIQUE,
  pan_number         TEXT,
  address            TEXT,
  phone              TEXT,
  email              TEXT,
  currency           CHAR(3)     NOT NULL DEFAULT 'INR',
  books_locked_till  DATE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 2 — SHOPS
-- ================================================================
CREATE TABLE shops (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL,
  address     TEXT,
  phone       TEXT,
  gst_number  TEXT,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 3 — USERS
-- Operational users only. Tenant admin account lives in master DB.
-- ================================================================
CREATE TABLE users (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       UUID        REFERENCES shops(id) ON DELETE SET NULL,
  name          TEXT        NOT NULL,
  email         TEXT        NOT NULL UNIQUE,
  password_hash TEXT        NOT NULL,
  role          user_role   NOT NULL DEFAULT 'cashier',
  is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 4 — FINANCIAL ACCOUNTING  §1
-- ================================================================
CREATE TABLE chart_of_accounts (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  code        TEXT         NOT NULL UNIQUE,
  name        TEXT         NOT NULL,
  type        account_type NOT NULL,
  parent_id   UUID         REFERENCES chart_of_accounts(id),
  is_system   BOOLEAN      NOT NULL DEFAULT FALSE,
  is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE journal_entries (
  id           UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_type     TEXT           NOT NULL,
  ref_id       UUID           NOT NULL,
  entry_date   DATE           NOT NULL DEFAULT CURRENT_DATE,
  description  TEXT,
  status       journal_status NOT NULL DEFAULT 'draft',
  posted_at    TIMESTAMPTZ,
  posted_by    UUID           REFERENCES users(id),
  reversed_by  UUID           REFERENCES journal_entries(id),
  created_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE TABLE journal_entry_lines (
  id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_entry_id  UUID          NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  account_id        UUID          NOT NULL REFERENCES chart_of_accounts(id),
  debit             NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (debit  >= 0),
  credit            NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  description       TEXT,
  CHECK (debit > 0 OR credit > 0),
  CHECK (NOT (debit > 0 AND credit > 0))
);


-- ================================================================
-- SECTION 5 — TAX RATES
-- ================================================================
CREATE TABLE tax_rates (
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
CREATE TABLE suppliers (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL,
  gst_number  TEXT,
  phone       TEXT,
  email       TEXT,
  address     TEXT,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 7 — PRODUCTS & INVENTORY
-- ================================================================
CREATE TABLE categories (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL UNIQUE,
  parent_id  UUID REFERENCES categories(id)
);

CREATE TABLE products (
  id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  sku          TEXT          NOT NULL UNIQUE,
  name         TEXT          NOT NULL,
  description  TEXT,
  category_id  UUID          REFERENCES categories(id),
  tax_rate_id  UUID          REFERENCES tax_rates(id),
  unit         TEXT          NOT NULL DEFAULT 'pcs',
  barcode      TEXT,
  hsn_code     TEXT,
  base_price   NUMERIC(12,2) NOT NULL DEFAULT 0,
  cost_price   NUMERIC(12,2) NOT NULL DEFAULT 0,
  is_active    BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_products_name_trgm ON products USING GIN (name gin_trgm_ops);
CREATE INDEX idx_products_barcode   ON products (barcode) WHERE barcode IS NOT NULL;

CREATE TABLE inventory (
  id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id        UUID          NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
  product_id     UUID          NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  quantity       NUMERIC(12,3) NOT NULL DEFAULT 0,
  reorder_point  NUMERIC(12,3) NOT NULL DEFAULT 0,
  reorder_qty    NUMERIC(12,3) NOT NULL DEFAULT 0,
  landed_cost    NUMERIC(12,2) NOT NULL DEFAULT 0,
  updated_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, product_id)
);

CREATE TABLE stock_movements (
  id          UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id     UUID           NOT NULL REFERENCES shops(id),
  product_id  UUID           NOT NULL REFERENCES products(id),
  movement    stock_movement NOT NULL,
  quantity    NUMERIC(12,3)  NOT NULL,
  ref_type    TEXT,
  ref_id      UUID,
  note        TEXT,
  created_by  UUID           REFERENCES users(id),
  created_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_stock_movements_product ON stock_movements (product_id, created_at DESC);
CREATE INDEX idx_stock_movements_shop    ON stock_movements (shop_id,    created_at DESC);


-- ================================================================
-- SECTION 8 — PRICING & PRICE LISTS  §3
-- ================================================================
CREATE TABLE price_lists (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL,
  tier        price_tier  NOT NULL DEFAULT 'retail',
  valid_from  DATE,
  valid_to    DATE,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT no_overlapping_promo EXCLUDE USING GIST (
    tier WITH =,
    daterange(valid_from, valid_to, '[]') WITH &&
  ) WHERE (valid_from IS NOT NULL AND valid_to IS NOT NULL AND is_active = TRUE)
);

CREATE TABLE price_list_items (
  id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  price_list_id  UUID          NOT NULL REFERENCES price_lists(id) ON DELETE CASCADE,
  product_id     UUID          NOT NULL REFERENCES products(id)    ON DELETE CASCADE,
  price          NUMERIC(12,2) NOT NULL,
  UNIQUE (price_list_id, product_id)
);


-- ================================================================
-- SECTION 9 — CUSTOMERS  §6
-- ================================================================
CREATE TABLE customer_groups (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name           TEXT NOT NULL UNIQUE,
  price_list_id  UUID REFERENCES price_lists(id)
);

CREATE TABLE customers (
  id                 UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name               TEXT          NOT NULL,
  phone              TEXT,
  email              TEXT,
  gst_number         TEXT,
  address            TEXT,
  customer_group_id  UUID          REFERENCES customer_groups(id),
  loyalty_points     NUMERIC(10,2) NOT NULL DEFAULT 0,
  whatsapp_opt_in    BOOLEAN       NOT NULL DEFAULT FALSE,
  sms_opt_in         BOOLEAN       NOT NULL DEFAULT FALSE,
  is_active          BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_customers_phone     ON customers (phone) WHERE phone IS NOT NULL;
CREATE INDEX idx_customers_name_trgm ON customers USING GIN (name gin_trgm_ops);

CREATE TABLE customer_shop_stats (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     UUID          NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  shop_id         UUID          NOT NULL REFERENCES shops(id)     ON DELETE CASCADE,
  total_invoices  INT           NOT NULL DEFAULT 0,
  total_spent     NUMERIC(14,2) NOT NULL DEFAULT 0,
  last_visited_at TIMESTAMPTZ,
  UNIQUE (customer_id, shop_id)
);

CREATE TABLE loyalty_transactions (
  id           UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id  UUID            NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  shop_id      UUID            REFERENCES shops(id),
  type         loyalty_tx_type NOT NULL,
  points       NUMERIC(10,2)   NOT NULL,
  ref_type     TEXT,
  ref_id       UUID,
  note         TEXT,
  created_at   TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 10 — INVOICES
-- ================================================================
CREATE TABLE invoices (
  id               UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id          UUID           NOT NULL REFERENCES shops(id) ON DELETE RESTRICT,
  invoice_number   TEXT           NOT NULL,
  offline_number   TEXT,
  status           invoice_status NOT NULL DEFAULT 'draft',
  customer_id      UUID           REFERENCES customers(id),
  user_id          UUID           REFERENCES users(id),
  price_list_id    UUID           REFERENCES price_lists(id),
  invoice_date     DATE           NOT NULL DEFAULT CURRENT_DATE,
  due_date         DATE,
  subtotal         NUMERIC(14,2)  NOT NULL DEFAULT 0,
  discount_amount  NUMERIC(14,2)  NOT NULL DEFAULT 0,
  taxable_amount   NUMERIC(14,2)  NOT NULL DEFAULT 0,
  tax_amount       NUMERIC(14,2)  NOT NULL DEFAULT 0,
  total_amount     NUMERIC(14,2)  NOT NULL DEFAULT 0,
  paid_amount      NUMERIC(14,2)  NOT NULL DEFAULT 0,
  payment_mode     payment_mode,
  irn              TEXT,
  ack_no           TEXT,
  ack_date         TIMESTAMPTZ,
  eway_bill_no     TEXT,
  tcs_rate         NUMERIC(5,2),
  tcs_amount       NUMERIC(12,2),
  tds_rate         NUMERIC(5,2),
  tds_amount       NUMERIC(12,2),
  is_offline       BOOLEAN        NOT NULL DEFAULT FALSE,
  synced_at        TIMESTAMPTZ,
  idempotency_key  TEXT           UNIQUE,
  notes            TEXT,
  created_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, invoice_number)
);

CREATE INDEX idx_invoices_customer  ON invoices (customer_id);
CREATE INDEX idx_invoices_date      ON invoices (invoice_date DESC);
CREATE INDEX idx_invoices_shop_date ON invoices (shop_id, invoice_date DESC);
CREATE INDEX idx_invoices_status    ON invoices (status) WHERE status != 'paid';

CREATE TABLE invoice_lines (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id       UUID          NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  product_id       UUID          NOT NULL REFERENCES products(id),
  quantity         NUMERIC(12,3) NOT NULL,
  unit_price       NUMERIC(12,2) NOT NULL,
  discount_pct     NUMERIC(5,2)  NOT NULL DEFAULT 0,
  discount_amount  NUMERIC(12,2) NOT NULL DEFAULT 0,
  taxable_amount   NUMERIC(12,2) NOT NULL DEFAULT 0,
  tax_rate         NUMERIC(5,2)  NOT NULL DEFAULT 0,
  tax_amount       NUMERIC(12,2) NOT NULL DEFAULT 0,
  line_total       NUMERIC(12,2) NOT NULL DEFAULT 0,
  hsn_code         TEXT,
  batch_number     TEXT
);

CREATE TABLE invoice_payments (
  id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id  UUID          NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  mode        payment_mode  NOT NULL,
  amount      NUMERIC(12,2) NOT NULL,
  reference   TEXT,
  paid_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 11 — PURCHASES  §4
-- ================================================================
CREATE TABLE purchases (
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

CREATE TABLE purchase_lines (
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
-- SECTION 12 — SALES RETURNS  §5
-- ================================================================
CREATE TABLE sales_returns (
  id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id        UUID          NOT NULL REFERENCES shops(id),
  return_number  TEXT          NOT NULL,
  invoice_id     UUID          NOT NULL REFERENCES invoices(id),
  customer_id    UUID          REFERENCES customers(id),
  status         return_status NOT NULL DEFAULT 'pending',
  return_date    DATE          NOT NULL DEFAULT CURRENT_DATE,
  subtotal       NUMERIC(14,2) NOT NULL DEFAULT 0,
  tax_amount     NUMERIC(14,2) NOT NULL DEFAULT 0,
  total_amount   NUMERIC(14,2) NOT NULL DEFAULT 0,
  refund_mode    payment_mode,
  refund_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
  is_post_gst    BOOLEAN       NOT NULL DEFAULT FALSE,
  reason         TEXT,
  processed_by   UUID          REFERENCES users(id),
  created_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, return_number)
);

CREATE TABLE sales_return_lines (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_return_id  UUID          NOT NULL REFERENCES sales_returns(id)  ON DELETE CASCADE,
  invoice_line_id  UUID          NOT NULL REFERENCES invoice_lines(id),
  product_id       UUID          NOT NULL REFERENCES products(id),
  quantity         NUMERIC(12,3) NOT NULL,
  unit_price       NUMERIC(12,2) NOT NULL,
  tax_rate         NUMERIC(5,2)  NOT NULL DEFAULT 0,
  tax_amount       NUMERIC(12,2) NOT NULL DEFAULT 0,
  line_total       NUMERIC(12,2) NOT NULL DEFAULT 0
);

CREATE TABLE sales_return_refunds (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_return_id  UUID          NOT NULL REFERENCES sales_returns(id) ON DELETE CASCADE,
  mode             payment_mode  NOT NULL,
  amount           NUMERIC(12,2) NOT NULL,
  reference        TEXT,
  refunded_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 13 — PURCHASE RETURNS  §5
-- ================================================================
CREATE TABLE purchase_returns (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id         UUID          NOT NULL REFERENCES shops(id),
  return_number   TEXT          NOT NULL,
  purchase_id     UUID          NOT NULL REFERENCES purchases(id),
  supplier_id     UUID          REFERENCES suppliers(id),
  status          return_status NOT NULL DEFAULT 'pending',
  return_date     DATE          NOT NULL DEFAULT CURRENT_DATE,
  total_amount    NUMERIC(14,2) NOT NULL DEFAULT 0,
  reason          TEXT,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, return_number)
);

CREATE TABLE purchase_return_lines (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_return_id  UUID          NOT NULL REFERENCES purchase_returns(id) ON DELETE CASCADE,
  purchase_line_id    UUID          NOT NULL REFERENCES purchase_lines(id),
  product_id          UUID          NOT NULL REFERENCES products(id),
  quantity            NUMERIC(12,3) NOT NULL,
  unit_cost           NUMERIC(12,2) NOT NULL,
  line_total          NUMERIC(12,2) NOT NULL DEFAULT 0
);


-- ================================================================
-- SECTION 14 — OFFLINE POS SYNC  §2
-- ================================================================
CREATE TABLE offline_sync_log (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id          UUID        NOT NULL REFERENCES shops(id),
  offline_number   TEXT        NOT NULL,
  final_number     TEXT,
  payload          JSONB       NOT NULL,
  status           sync_status NOT NULL DEFAULT 'pending',
  conflict_reason  TEXT,
  synced_at        TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_offline_sync_status ON offline_sync_log (status)  WHERE status != 'synced';
CREATE INDEX idx_offline_sync_shop   ON offline_sync_log (shop_id, created_at DESC);


-- ================================================================
-- SECTION 15 — IDEMPOTENCY KEYS  §10
-- ================================================================
CREATE TABLE idempotency_keys (
  key         TEXT        PRIMARY KEY,
  endpoint    TEXT        NOT NULL,
  response    JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at  TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '24 hours'
);

CREATE INDEX idx_idempotency_expires ON idempotency_keys (expires_at);


-- ================================================================
-- SECTION 16 — AI / SMART INVENTORY  §9
-- ================================================================
CREATE TABLE product_inventory_metrics (
  id                      UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id                 UUID          NOT NULL REFERENCES shops(id),
  product_id              UUID          NOT NULL REFERENCES products(id),
  demand_velocity         NUMERIC(10,3) NOT NULL DEFAULT 0,
  days_of_inventory_left  NUMERIC(10,1),
  is_dead_stock           BOOLEAN       NOT NULL DEFAULT FALSE,
  dead_stock_since        DATE,
  last_sold_at            DATE,
  calculated_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (shop_id, product_id)
);

CREATE TABLE reorder_suggestions (
  id             UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id        UUID           NOT NULL REFERENCES shops(id),
  product_id     UUID           NOT NULL REFERENCES products(id),
  suggested_qty  NUMERIC(12,3)  NOT NULL,
  reason         TEXT,
  status         reorder_status NOT NULL DEFAULT 'suggested',
  reviewed_by    UUID           REFERENCES users(id),
  reviewed_at    TIMESTAMPTZ,
  created_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);


-- ================================================================
-- SECTION 17 — REPORTING OPTIMISATION  §7
-- ================================================================
CREATE TABLE daily_product_sales_summary (
  id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id        UUID          NOT NULL REFERENCES shops(id),
  product_id     UUID          NOT NULL REFERENCES products(id),
  summary_date   DATE          NOT NULL,
  qty_sold       NUMERIC(12,3) NOT NULL DEFAULT 0,
  gross_revenue  NUMERIC(14,2) NOT NULL DEFAULT 0,
  tax_collected  NUMERIC(14,2) NOT NULL DEFAULT 0,
  net_revenue    NUMERIC(14,2) NOT NULL DEFAULT 0,
  invoice_count  INT           NOT NULL DEFAULT 0,
  UNIQUE (shop_id, product_id, summary_date)
);

CREATE INDEX idx_daily_summary_date    ON daily_product_sales_summary (summary_date DESC);
CREATE INDEX idx_daily_summary_product ON daily_product_sales_summary (product_id, summary_date DESC);


-- ================================================================
-- SECTION 18 — AUDIT LOG  §8
-- ================================================================
CREATE TABLE audit_logs (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name  TEXT         NOT NULL,
  record_id   UUID         NOT NULL,
  action      audit_action NOT NULL,
  old_values  JSONB,
  new_values  JSONB,
  changed_by  UUID         REFERENCES users(id),
  changed_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  ip_address  INET,
  note        TEXT
);

CREATE INDEX idx_audit_logs_record ON audit_logs (table_name, record_id);
CREATE INDEX idx_audit_logs_user   ON audit_logs (changed_by, changed_at DESC);
CREATE INDEX idx_audit_logs_date   ON audit_logs (changed_at DESC);


-- ================================================================
-- SECTION 19 — TRIGGERS
-- ================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tenant_profile_updated_at BEFORE UPDATE ON tenant_profile FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_shops_updated_at          BEFORE UPDATE ON shops          FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_users_updated_at          BEFORE UPDATE ON users          FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_products_updated_at       BEFORE UPDATE ON products       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_customers_updated_at      BEFORE UPDATE ON customers      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_invoices_updated_at       BEFORE UPDATE ON invoices       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_purchases_updated_at      BEFORE UPDATE ON purchases      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_suppliers_updated_at      BEFORE UPDATE ON suppliers      FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Books lock enforcement  §8
CREATE OR REPLACE FUNCTION enforce_books_lock()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  lock_date DATE;
BEGIN
  SELECT books_locked_till INTO lock_date FROM tenant_profile LIMIT 1;
  IF lock_date IS NOT NULL AND NEW.entry_date <= lock_date THEN
    RAISE EXCEPTION 'Books are locked until %. Cannot post entry dated %.', lock_date, NEW.entry_date;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_journal_books_lock
  BEFORE INSERT ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION enforce_books_lock();

-- Double-entry balance validation  §1
CREATE OR REPLACE FUNCTION validate_journal_balance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  total_debit  NUMERIC;
  total_credit NUMERIC;
BEGIN
  IF NEW.status = 'posted' AND OLD.status = 'draft' THEN
    SELECT
      COALESCE(SUM(debit),  0),
      COALESCE(SUM(credit), 0)
    INTO total_debit, total_credit
    FROM journal_entry_lines
    WHERE journal_entry_id = NEW.id;

    IF total_debit <> total_credit THEN
      RAISE EXCEPTION 'Journal % unbalanced: debit=% credit=%', NEW.id, total_debit, total_credit;
    END IF;
    NEW.posted_at = NOW();
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_journal_balance
  BEFORE UPDATE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION validate_journal_balance();

-- Return quantity validation  §5
CREATE OR REPLACE FUNCTION validate_return_quantity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  original_qty     NUMERIC;
  already_returned NUMERIC;
BEGIN
  SELECT quantity INTO original_qty
  FROM invoice_lines WHERE id = NEW.invoice_line_id;

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

CREATE TRIGGER trg_validate_return_qty
  BEFORE INSERT ON sales_return_lines
  FOR EACH ROW EXECUTE FUNCTION validate_return_quantity();


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
  ('5003', 'Operating Expenses',  'expense',   TRUE);

INSERT INTO tax_rates (name, rate, tax_type) VALUES
  ('GST 0%',    0.00, 'GST'),
  ('GST 5%',    5.00, 'GST'),
  ('GST 12%',  12.00, 'GST'),
  ('GST 18%',  18.00, 'GST'),
  ('GST 28%',  28.00, 'GST'),
  ('TCS 0.1%',  0.10, 'TCS');

INSERT INTO customer_groups (name) VALUES
  ('Retail'),
  ('Wholesale'),
  ('Distributor'),
  ('VIP');

INSERT INTO price_lists (name, tier) VALUES
  ('Standard Retail', 'retail'),
  ('Wholesale',       'wholesale'),
  ('Distributor',     'distributor');


-- ================================================================
-- RECORD THIS MIGRATION
-- ================================================================
INSERT INTO migrations (filename) VALUES ('001_init.sql');
  WHERE srl.invoice_line_id = NEW.invoice_line_id
    AND sr.status != 'pending';

  IF (already_returned + NEW.quantity) > original_qty THEN
    RAISE EXCEPTION 'Return quantity % exceeds original sold quantity % (already returned: %)',
      NEW.quantity, original_qty, already_returned;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_return_qty
  BEFORE INSERT ON sales_return_lines
  FOR EACH ROW EXECUTE FUNCTION validate_return_quantity();
