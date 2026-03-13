export type TenantUser = {
  id: string;
  shop_id: string;
  name: string;
  email: string;
  password: string;
  is_active: boolean;
  roles?: string[];
  permissions?: Record<string, Record<string, boolean>>;
  tenant_id?: string;
};
