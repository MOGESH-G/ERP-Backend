export type TenantUser = {
  id: string;
  shop_id: string;
  name: string;
  email: string;
  password: string;
  is_active: boolean;
  roles?: string[];
  tenant_id?: string;
};
