# Master Database Schema - Field by Field Explanation (Q&A)

## 1. What is the purpose of the `tenants` table and its key fields?
**Answer:** Core routing table used by middleware on **every request** to resolve tenant DB connection.
- `id UUID PK`: Internal tenant identifier
- `slug TEXT UNIQUE`: **Critical** - subdomain (`slug.yourerp.com`) **and** DB prefix (`tenant_${slug}`)
- `company_name TEXT UNIQUE`: Full Postgres DB name (`tenant_${slug}`) - enforces unique DB names
- `status tenant_status`: Workflow: provisioning→active→suspended/expired→deprovisioned. Middleware **only** routes to 'active'
- `feature_ids [intended JSONB]`: **Source of truth** for feature flags/limits. Cached by middleware. Populated by `fn_apply_plan_to_tenant`
- `create_info/update_info JSONB`: Audit trail `{created_by: user_id, created_at: time}`
**Connections:** `subscriptions.tenant_id → this.id`, generates tenant DB name

## 2. How does `subscriptions` link tenants to billing/plans?
**Answer:** 1:1 active subscription per tenant (others historical).
- `tenant_id → tenants.id`: Links to tenant (ON DELETE RESTRICT)
- `plan_id → plan_details.id`: Current plan reference
- `payment_id → payment_details.id`: **BROKEN** - missing target table
- `feature_ids TEXT[]`: **Unused/duplicated** - real flags in `tenants.feature_ids`
- `is_active BOOL`: Only one active per tenant_id (index)
- `expires_at`: Drives suspension (cron checks?)
**Connections:** Core billing → `tenants.status` updates

## 3. What is `plan_details` and how are features assigned?
**Answer:** Defines plan limits/features. **fn_apply_plan_to_tenant** copies to tenant.
- `name TEXT UNIQUE`: 'trial', 'starter', 'growth'
- `max_shops/users/products`: Hard limits (middleware enforces)
- `feature_ids TEXT[]`: Plan features → copied to `tenants.feature_ids JSONB`
**BROKEN:** No junction table, fn_apply_plan_to_tenant assumes `features.plan`/`feature_id` cols (don't exist)
**Connections:** `subscriptions.plan_id → this.id`

## 4. Why `admin_accounts` separate from tenant users?
**Answer:** Platform admins (provision tenants). **Tenant ops users** (cashiers) in tenant DBs.
- `email/password`: Platform login
- `UNIQUE(tenant_id, email)`: **BROKEN** - tenant_id column **missing**
**Connections:** Provisions → `tenants.status='provisioning'`

## 5. How does `features` registry work across DBs?
**Answer:** Master list of **all** features. Adding feature = INSERT row (no migrations).
- `key UNIQUE`: 'feat_pos', 'limit_users' - used in `tenants.feature_ids`
- `parent_id self-ref`: Feature hierarchy
**Cross-DB:** tenant DB `fn_generate_admin_permissions()` queries `SELECT key FROM master.features`
**Confusing:** 2nd INSERT refs missing `category/is_limit/default_val` cols

## 6. What is `fn_apply_plan_to_tenant` and why broken?
**Answer:** Called on provisioning/plan-change. Copies plan → `tenants.feature_ids`.
**BROKEN JOINS:**
```
SELECT FROM features pf JOIN features f ON f.id=pf.feature_id  ❌ no feature_id
WHERE pf.plan = p_plan  ❌ no plan col
```
**Sets:** `tenants.plan::plan_type` ❌ undefined enum/col
**Fix:** Need `plan_features` junction: `plan_id, feature_id, value JSONB`

## 7. Cross-DB interlinks with tenant schema?
**Answer:**
```
Master.tenants.slug → CREATE DB tenant_${slug}
Master.features → tenant.roles.permissions (fn_generate_admin_permissions)
Master.tenants.feature_ids → Frontend middleware feature gates
Master.tenants.status → Provisioning workflow (create/delete DB)
```

## 8. Missing tables causing failures?
**Answer:**
- `payment_details`: subscriptions.payment_id FK
- `tenant_feature_changelog`: trg_log_feature_changes INSERT
**Fix:** Add both tables

## 9. Why feature_ids JSONB not TEXT[]?
**Answer:** Middleware performance - GIN index, `feature_ids ? 'feat_pos'`, `feature_ids->>'limit_users'::int > current_users`. TEXT[] slower.

## 10. Migration safety?
**Answer:** All `IF NOT EXISTS`, idempotent. Safe re-run. Migrations table tracks `filename`.

**CLI:** `code ERP-Backend/docs/schema/MasterDB-Schema-Interlinks.md`


