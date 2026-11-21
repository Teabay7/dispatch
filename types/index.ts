// Shared TypeScript types for Dispatch.
// types/database.ts is generated: `supabase gen types typescript --local --schema public > types/database.ts`
import type { Database } from './database';

export type { Database };

export type AppRole = Database['public']['Enums']['app_role'];
export type RoleStatus = Database['public']['Enums']['role_status'];

export type Profile = Pick<Database['public']['Tables']['profiles']['Row'], 'id' | 'phone' | 'full_name'>;
export type UserRole = Pick<Database['public']['Tables']['user_roles']['Row'], 'role' | 'status'>;
