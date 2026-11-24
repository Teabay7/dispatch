
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "public": {
          Tables: {
            "app_settings": {
                  Row: {
                    "base_fee_kobo": number,"commission_bps": number,"commission_trips_per_cycle": number,"id": number,"per_km_rate_kobo": number,"rider_stale_after_minutes": number,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "base_fee_kobo": number,"commission_bps"?: number,"commission_trips_per_cycle"?: number,"id"?: number,"per_km_rate_kobo": number,"rider_stale_after_minutes"?: number,"updated_at"?: string
                  }
                  Update: {
                    "base_fee_kobo"?: number,"commission_bps"?: number,"commission_trips_per_cycle"?: number,"id"?: number,"per_km_rate_kobo"?: number,"rider_stale_after_minutes"?: number,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"commission_cycles": {
                  Row: {
                    "cycle_no": number,"due_at": string | null,"id": string,"opened_at": string,"paid_at": string | null,"reference_code": string,"rider_id": string,"status": Database["public"]['Enums']["commission_cycle_status"],"trip_count": number,"trips_required": number
                  }
                  ComputedFields: never
                  Insert: {
                    "cycle_no": number,"due_at"?: string | null,"id"?: string,"opened_at"?: string,"paid_at"?: string | null,"reference_code": string,"rider_id": string,"status"?: Database["public"]['Enums']["commission_cycle_status"],"trip_count"?: number,"trips_required": number
                  }
                  Update: {
                    "cycle_no"?: number,"due_at"?: string | null,"id"?: string,"opened_at"?: string,"paid_at"?: string | null,"reference_code"?: string,"rider_id"?: string,"status"?: Database["public"]['Enums']["commission_cycle_status"],"trip_count"?: number,"trips_required"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "commission_cycles_rider_id_fkey"
      columns: ["rider_id"]
isOneToOne: false
      referencedRelation: "rider_details"
      referencedColumns: ["user_id"]
    }
                  ]
                },"commission_entries": {
                  Row: {
                    "amount_kobo": number,"balance_after_kobo": number,"bank_reference": string | null,"created_at": string,"cycle_id": string,"entry_no": number,"id": string,"note": string | null,"order_id": string | null,"paid_at": string | null,"recorded_by": string | null,"reverses_entry_id": string | null,"rider_id": string,"type": Database["public"]['Enums']["commission_entry_type"]
                  }
                  ComputedFields: never
                  Insert: {
                    "amount_kobo": number,"balance_after_kobo": number,"bank_reference"?: string | null,"created_at"?: string,"cycle_id": string,"entry_no": number,"id"?: string,"note"?: string | null,"order_id"?: string | null,"paid_at"?: string | null,"recorded_by"?: string | null,"reverses_entry_id"?: string | null,"rider_id": string,"type": Database["public"]['Enums']["commission_entry_type"]
                  }
                  Update: {
                    "amount_kobo"?: number,"balance_after_kobo"?: number,"bank_reference"?: string | null,"created_at"?: string,"cycle_id"?: string,"entry_no"?: number,"id"?: string,"note"?: string | null,"order_id"?: string | null,"paid_at"?: string | null,"recorded_by"?: string | null,"reverses_entry_id"?: string | null,"rider_id"?: string,"type"?: Database["public"]['Enums']["commission_entry_type"]
                  }
                  Relationships: [
                    {
      foreignKeyName: "commission_entries_cycle_id_fkey"
      columns: ["cycle_id"]
isOneToOne: false
      referencedRelation: "commission_cycles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_entries_order_id_fkey"
      columns: ["order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_entries_reverses_entry_id_fkey"
      columns: ["reverses_entry_id"]
isOneToOne: true
      referencedRelation: "commission_entries"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_entries_rider_id_fkey"
      columns: ["rider_id"]
isOneToOne: false
      referencedRelation: "rider_details"
      referencedColumns: ["user_id"]
    }
                  ]
                },"company_payment_account": {
                  Row: {
                    "account_name": string | null,"account_number": string | null,"bank_name": string | null,"id": number,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_name"?: string | null,"account_number"?: string | null,"bank_name"?: string | null,"id"?: number,"updated_at"?: string
                  }
                  Update: {
                    "account_name"?: string | null,"account_number"?: string | null,"bank_name"?: string | null,"id"?: number,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"company_payment_account_changes": {
                  Row: {
                    "changed_at": string,"changed_by": string,"changed_by_user": string | null,"field": string,"id": string,"new_value": string | null,"old_value": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "changed_at"?: string,"changed_by": string,"changed_by_user"?: string | null,"field": string,"id"?: string,"new_value"?: string | null,"old_value"?: string | null
                  }
                  Update: {
                    "changed_at"?: string,"changed_by"?: string,"changed_by_user"?: string | null,"field"?: string,"id"?: string,"new_value"?: string | null,"old_value"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "company_payment_account_changes_changed_by_user_fkey"
      columns: ["changed_by_user"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"order_events": {
                  Row: {
                    "actor_id": string | null,"created_at": string,"id": string,"note": string | null,"order_id": string,"status": Database["public"]['Enums']["order_status"]
                  }
                  ComputedFields: never
                  Insert: {
                    "actor_id"?: string | null,"created_at"?: string,"id"?: string,"note"?: string | null,"order_id": string,"status": Database["public"]['Enums']["order_status"]
                  }
                  Update: {
                    "actor_id"?: string | null,"created_at"?: string,"id"?: string,"note"?: string | null,"order_id"?: string,"status"?: Database["public"]['Enums']["order_status"]
                  }
                  Relationships: [
                    {
      foreignKeyName: "order_events_actor_id_fkey"
      columns: ["actor_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "order_events_order_id_fkey"
      columns: ["order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["id"]
    }
                  ]
                },"orders": {
                  Row: {
                    "commission_kobo": number,"created_at": string,"customer_id": string,"dropoff_address": string,"dropoff_lat": number,"dropoff_lng": number,"dropoff_postcode": string | null,"id": string,"payment_status": Database["public"]['Enums']["payment_status"],"pickup_address": string,"pickup_lat": number,"pickup_lng": number,"pickup_postcode": string | null,"price_kobo": number,"rider_id": string | null,"status": Database["public"]['Enums']["order_status"],"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "commission_kobo": number,"created_at"?: string,"customer_id": string,"dropoff_address": string,"dropoff_lat": number,"dropoff_lng": number,"dropoff_postcode"?: string | null,"id"?: string,"payment_status"?: Database["public"]['Enums']["payment_status"],"pickup_address": string,"pickup_lat": number,"pickup_lng": number,"pickup_postcode"?: string | null,"price_kobo": number,"rider_id"?: string | null,"status"?: Database["public"]['Enums']["order_status"],"updated_at"?: string
                  }
                  Update: {
                    "commission_kobo"?: number,"created_at"?: string,"customer_id"?: string,"dropoff_address"?: string,"dropoff_lat"?: number,"dropoff_lng"?: number,"dropoff_postcode"?: string | null,"id"?: string,"payment_status"?: Database["public"]['Enums']["payment_status"],"pickup_address"?: string,"pickup_lat"?: number,"pickup_lng"?: number,"pickup_postcode"?: string | null,"price_kobo"?: number,"rider_id"?: string | null,"status"?: Database["public"]['Enums']["order_status"],"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "orders_customer_id_fkey"
      columns: ["customer_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "orders_rider_id_fkey"
      columns: ["rider_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"profiles": {
                  Row: {
                    "created_at": string,"flagged_for_admin_review": boolean,"full_name": string | null,"has_unsettled_unpaid_order": boolean,"id": string,"phone": string | null,"unpaid_abandon_count": number,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"flagged_for_admin_review"?: boolean,"full_name"?: string | null,"has_unsettled_unpaid_order"?: boolean,"id": string,"phone"?: string | null,"unpaid_abandon_count"?: number,"updated_at"?: string
                  }
                  Update: {
                    "created_at"?: string,"flagged_for_admin_review"?: boolean,"full_name"?: string | null,"has_unsettled_unpaid_order"?: boolean,"id"?: string,"phone"?: string | null,"unpaid_abandon_count"?: number,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"ratings": {
                  Row: {
                    "comment": string | null,"created_at": string,"from_id": string,"id": string,"order_id": string,"score": number,"to_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "comment"?: string | null,"created_at"?: string,"from_id": string,"id"?: string,"order_id": string,"score": number,"to_id": string
                  }
                  Update: {
                    "comment"?: string | null,"created_at"?: string,"from_id"?: string,"id"?: string,"order_id"?: string,"score"?: number,"to_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "ratings_from_id_fkey"
      columns: ["from_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ratings_order_id_fkey"
      columns: ["order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ratings_to_id_fkey"
      columns: ["to_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"rider_bank_accounts": {
                  Row: {
                    "account_name": string,"account_number": string,"bank_name": string,"created_at": string,"id": string,"name_match": Database["public"]['Enums']["bank_name_match"],"reason": string | null,"recorded_by": string | null,"review_note": string | null,"reviewed_at": string | null,"reviewed_by": string | null,"revoked_at": string | null,"revoked_recorded_by": string | null,"rider_id": string,"status": Database["public"]['Enums']["bank_account_status"],"updated_at": string,"verified_name": string | null,"verified_name_match": Database["public"]['Enums']["bank_name_match"] | null
                  }
                  ComputedFields: never
                  Insert: {
                    "account_name": string,"account_number": string,"bank_name": string,"created_at"?: string,"id"?: string,"name_match": Database["public"]['Enums']["bank_name_match"],"reason"?: string | null,"recorded_by"?: string | null,"review_note"?: string | null,"reviewed_at"?: string | null,"reviewed_by"?: string | null,"revoked_at"?: string | null,"revoked_recorded_by"?: string | null,"rider_id": string,"status"?: Database["public"]['Enums']["bank_account_status"],"updated_at"?: string,"verified_name"?: string | null,"verified_name_match"?: Database["public"]['Enums']["bank_name_match"] | null
                  }
                  Update: {
                    "account_name"?: string,"account_number"?: string,"bank_name"?: string,"created_at"?: string,"id"?: string,"name_match"?: Database["public"]['Enums']["bank_name_match"],"reason"?: string | null,"recorded_by"?: string | null,"review_note"?: string | null,"reviewed_at"?: string | null,"reviewed_by"?: string | null,"revoked_at"?: string | null,"revoked_recorded_by"?: string | null,"rider_id"?: string,"status"?: Database["public"]['Enums']["bank_account_status"],"updated_at"?: string,"verified_name"?: string | null,"verified_name_match"?: Database["public"]['Enums']["bank_name_match"] | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "rider_bank_accounts_reviewed_by_fkey"
      columns: ["reviewed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "rider_bank_accounts_rider_id_fkey"
      columns: ["rider_id"]
isOneToOne: false
      referencedRelation: "rider_details"
      referencedColumns: ["user_id"]
    }
                  ]
                },"rider_details": {
                  Row: {
                    "bike_colour": string,"bike_make_model": string,"created_at": string,"full_name": string,"id_photo_path": string,"is_online": boolean,"kyc_status": Database["public"]['Enums']["kyc_status"],"online_since": string | null,"plate_number": string,"plate_released": boolean,"rejection_reason": string | null,"reviewed_at": string | null,"reviewed_by": string | null,"selfie_path": string,"submitted_at": string,"updated_at": string,"user_id": string,"vehicle_type": Database["public"]['Enums']["vehicle_type"]
                  }
                  ComputedFields: never
                  Insert: {
                    "bike_colour": string,"bike_make_model": string,"created_at"?: string,"full_name": string,"id_photo_path": string,"is_online"?: boolean,"kyc_status"?: Database["public"]['Enums']["kyc_status"],"online_since"?: string | null,"plate_number": string,"plate_released"?: boolean,"rejection_reason"?: string | null,"reviewed_at"?: string | null,"reviewed_by"?: string | null,"selfie_path": string,"submitted_at"?: string,"updated_at"?: string,"user_id": string,"vehicle_type"?: Database["public"]['Enums']["vehicle_type"]
                  }
                  Update: {
                    "bike_colour"?: string,"bike_make_model"?: string,"created_at"?: string,"full_name"?: string,"id_photo_path"?: string,"is_online"?: boolean,"kyc_status"?: Database["public"]['Enums']["kyc_status"],"online_since"?: string | null,"plate_number"?: string,"plate_released"?: boolean,"rejection_reason"?: string | null,"reviewed_at"?: string | null,"reviewed_by"?: string | null,"selfie_path"?: string,"submitted_at"?: string,"updated_at"?: string,"user_id"?: string,"vehicle_type"?: Database["public"]['Enums']["vehicle_type"]
                  }
                  Relationships: [
                    {
      foreignKeyName: "rider_details_reviewed_by_fkey"
      columns: ["reviewed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "rider_details_user_id_fkey"
      columns: ["user_id"]
isOneToOne: true
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"rider_locations": {
                  Row: {
                    "accuracy_m": number | null,"lat": number,"lng": number,"rider_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "accuracy_m"?: number | null,"lat": number,"lng": number,"rider_id": string,"updated_at"?: string
                  }
                  Update: {
                    "accuracy_m"?: number | null,"lat"?: number,"lng"?: number,"rider_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "rider_locations_rider_id_fkey"
      columns: ["rider_id"]
isOneToOne: true
      referencedRelation: "rider_details"
      referencedColumns: ["user_id"]
    }
                  ]
                },"user_roles": {
                  Row: {
                    "created_at": string,"id": string,"role": Database["public"]['Enums']["app_role"],"status": Database["public"]['Enums']["role_status"],"suspended_reason": string | null,"updated_at": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"role": Database["public"]['Enums']["app_role"],"status"?: Database["public"]['Enums']["role_status"],"suspended_reason"?: string | null,"updated_at"?: string,"user_id": string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"role"?: Database["public"]['Enums']["app_role"],"status"?: Database["public"]['Enums']["role_status"],"suspended_reason"?: string | null,"updated_at"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "user_roles_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                }
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "accrue_trip_commission":
{ Args: { "p_order_id": string }; Returns: boolean
                           },
"append_commission_entry":
{ Args: { "p_amount_kobo": number,"p_bank_reference"?: string,"p_cycle_id": string,"p_note"?: string,"p_order_id"?: string,"p_paid_at"?: string,"p_recorded_by"?: string,"p_reverses_entry_id"?: string,"p_rider_id": string,"p_type": Database["public"]['Enums']["commission_entry_type"] }; Returns: {
              "amount_kobo": number,
"balance_after_kobo": number,
"bank_reference": string | null,
"created_at": string,
"cycle_id": string,
"entry_no": number,
"id": string,
"note": string | null,
"order_id": string | null,
"paid_at": string | null,
"recorded_by": string | null,
"reverses_entry_id": string | null,
"rider_id": string,
"type": Database["public"]['Enums']["commission_entry_type"]
            }
                          SetofOptions: {
        from: "*"
        to: "commission_entries"
        isOneToOne: true
        isSetofReturn: false
      } },
"approve_rider_bank_account":
{ Args: { "p_account_id": string,"p_note"?: string,"p_recorded_by": string,"p_verified_name": string }; Returns: undefined
                           },
"bank_account_name_match":
{ Args: { "p_account_name": string,"p_kyc_name": string }; Returns: Database["public"]['Enums']["bank_name_match"]
                           },
"commission_for_price":
{ Args: { "p_bps": number,"p_price_kobo": number }; Returns: number
                           },
"commission_reference_code":
{ Args: { "p_cycle_no": number,"p_rider_id": string }; Returns: string
                           },
"expire_stale_riders":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"get_company_payment_account":
{ Args: Record<PropertyKey, never>; Returns: {
              "account_name": string,"account_number": string,"bank_name": string
            }[]
                           },
"has_active_role":
{ Args: { "r": Database["public"]['Enums']["app_role"] }; Returns: boolean
                           },
"is_admin":
{ Args: Record<PropertyKey, never>; Returns: boolean
                           },
"is_own_kyc_file":
{ Args: { "p_path": string,"p_user_id": string }; Returns: boolean
                           },
"lock_rider_commission":
{ Args: { "p_rider_id": string }; Returns: undefined
                           },
"order_counts_as_trip":
{ Args: { "p_payment_status": Database["public"]['Enums']["payment_status"],"p_status": Database["public"]['Enums']["order_status"] }; Returns: boolean
                           },
"record_commission_payment":
{ Args: { "p_amount_kobo": number,"p_bank_reference": string,"p_note": string,"p_paid_at": string,"p_recorded_by": string,"p_reference_code": string }; Returns: number
                           },
"reject_rider_bank_account":
{ Args: { "p_account_id": string,"p_reason": string,"p_recorded_by": string }; Returns: undefined
                           },
"reverse_commission_entry":
{ Args: { "p_entry_id": string,"p_reason": string,"p_recorded_by": string }; Returns: number
                           },
"revoke_rider_bank_account":
{ Args: { "p_account_id": string,"p_reason": string,"p_recorded_by": string }; Returns: undefined
                           },
"rider_commission_balance":
{ Args: { "p_rider_id": string }; Returns: number
                           },
"rider_has_commission_due":
{ Args: { "p_rider_id": string }; Returns: boolean
                           },
"rider_has_verified_bank_account":
{ Args: { "p_user_id": string }; Returns: boolean
                           },
"rider_role_is_active":
{ Args: { "p_user_id": string }; Returns: boolean
                           },
"rider_stale_cutoff":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"set_company_payment_account":
{ Args: { "p_account_name": string,"p_account_number": string,"p_bank_name": string,"p_changed_by": string }; Returns: undefined
                           },
"settle_commission_cycles":
{ Args: { "p_rider_id": string }; Returns: undefined
                           },
"submit_rider_bank_account":
{ Args: { "p_account_name": string,"p_account_number": string,"p_bank_name": string }; Returns: string
                           },
"take_rider_offline_for_commission":
{ Args: { "p_rider_id": string }; Returns: undefined
                           }
          }
          Enums: {
            "app_role": "customer"|"rider"|"admin","bank_account_status": "pending"|"verified"|"rejected"|"withdrawn"|"replaced"|"revoked","bank_name_match": "match"|"partial"|"mismatch","commission_cycle_status": "open"|"due"|"paid","commission_entry_type": "commission"|"payment"|"reversal","kyc_status": "pending"|"approved"|"rejected","order_status": "created"|"rider_requested"|"accepted"|"picked_up"|"delivered"|"completed"|"cancelled_by_customer"|"cancelled_by_rider"|"no_rider_found"|"payment_failed","payment_status": "unpaid"|"awaiting_payment"|"paid"|"failed","role_status": "active"|"suspended","vehicle_type": "bike"
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "public": {
          Enums: {
            "app_role": ["customer", "rider", "admin"],"bank_account_status": ["pending", "verified", "rejected", "withdrawn", "replaced", "revoked"],"bank_name_match": ["match", "partial", "mismatch"],"commission_cycle_status": ["open", "due", "paid"],"commission_entry_type": ["commission", "payment", "reversal"],"kyc_status": ["pending", "approved", "rejected"],"order_status": ["created", "rider_requested", "accepted", "picked_up", "delivered", "completed", "cancelled_by_customer", "cancelled_by_rider", "no_rider_found", "payment_failed"],"payment_status": ["unpaid", "awaiting_payment", "paid", "failed"],"role_status": ["active", "suspended"],"vehicle_type": ["bike"]
          }
        }
} as const
