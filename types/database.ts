
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "public": {
          Tables: {
            "admin_review_flags": {
                  Row: {
                    "created_at": string,"id": string,"reason": string,"resolution_note": string | null,"resolved_at": string | null,"resolved_by": string | null,"role": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"reason": string,"resolution_note"?: string | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"role": string,"user_id": string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"reason"?: string,"resolution_note"?: string | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"role"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "admin_review_flags_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"api_usage": {
                  Row: {
                    "created_at": string,"google_calls": number,"id": string,"kind": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"google_calls": number,"id"?: string,"kind": string,"user_id": string
                  }
                  Update: {
                    "created_at"?: string,"google_calls"?: number,"id"?: string,"kind"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "api_usage_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"app_settings": {
                  Row: {
                    "awaiting_payment_refuse_after_minutes": number,"base_fee_kobo": number,"commission_bps": number,"commission_trips_per_cycle": number,"customer_late_cancel_flag_after": number,"customer_unpaid_flag_after": number,"delivery_pin_max_attempts": number,"dispatch_max_attempts": number,"dispatch_max_radius_m": number,"dispatch_search_minutes": number,"dispute_window_days": number,"dropoff_arrival_radius_m": number,"false_dispute_flag_after": number,"google_calls_per_day": number,"id": number,"max_active_orders_per_customer": number,"max_order_distance_m": number,"offer_timeout_seconds": number,"per_km_rate_kobo": number,"place_searches_per_hour": number,"quote_valid_minutes": number,"quotes_per_hour": number,"rider_late_cancel_flag_after": number,"rider_stale_after_minutes": number,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "awaiting_payment_refuse_after_minutes"?: number,"base_fee_kobo": number,"commission_bps"?: number,"commission_trips_per_cycle"?: number,"customer_late_cancel_flag_after"?: number,"customer_unpaid_flag_after"?: number,"delivery_pin_max_attempts"?: number,"dispatch_max_attempts"?: number,"dispatch_max_radius_m"?: number,"dispatch_search_minutes"?: number,"dispute_window_days"?: number,"dropoff_arrival_radius_m"?: number,"false_dispute_flag_after"?: number,"google_calls_per_day"?: number,"id"?: number,"max_active_orders_per_customer"?: number,"max_order_distance_m"?: number,"offer_timeout_seconds"?: number,"per_km_rate_kobo": number,"place_searches_per_hour"?: number,"quote_valid_minutes"?: number,"quotes_per_hour"?: number,"rider_late_cancel_flag_after"?: number,"rider_stale_after_minutes"?: number,"updated_at"?: string
                  }
                  Update: {
                    "awaiting_payment_refuse_after_minutes"?: number,"base_fee_kobo"?: number,"commission_bps"?: number,"commission_trips_per_cycle"?: number,"customer_late_cancel_flag_after"?: number,"customer_unpaid_flag_after"?: number,"delivery_pin_max_attempts"?: number,"dispatch_max_attempts"?: number,"dispatch_max_radius_m"?: number,"dispatch_search_minutes"?: number,"dispute_window_days"?: number,"dropoff_arrival_radius_m"?: number,"false_dispute_flag_after"?: number,"google_calls_per_day"?: number,"id"?: number,"max_active_orders_per_customer"?: number,"max_order_distance_m"?: number,"offer_timeout_seconds"?: number,"per_km_rate_kobo"?: number,"place_searches_per_hour"?: number,"quote_valid_minutes"?: number,"quotes_per_hour"?: number,"rider_late_cancel_flag_after"?: number,"rider_stale_after_minutes"?: number,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"cancellation_events": {
                  Row: {
                    "cancelled_by": string | null,"counted": boolean,"created_at": string,"id": string,"order_id": string,"reason": string | null,"recorded_by": string | null,"role": string,"stage": Database["public"]['Enums']["cancel_stage"]
                  }
                  ComputedFields: never
                  Insert: {
                    "cancelled_by"?: string | null,"counted": boolean,"created_at"?: string,"id"?: string,"order_id": string,"reason"?: string | null,"recorded_by"?: string | null,"role": string,"stage": Database["public"]['Enums']["cancel_stage"]
                  }
                  Update: {
                    "cancelled_by"?: string | null,"counted"?: boolean,"created_at"?: string,"id"?: string,"order_id"?: string,"reason"?: string | null,"recorded_by"?: string | null,"role"?: string,"stage"?: Database["public"]['Enums']["cancel_stage"]
                  }
                  Relationships: [
                    {
      foreignKeyName: "cancellation_events_cancelled_by_fkey"
      columns: ["cancelled_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "cancellation_events_order_id_fkey"
      columns: ["order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["id"]
    }
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
                },"dispatch_offers": {
                  Row: {
                    "attempt_no": number,"distance_to_pickup_m": number,"expires_at": string,"id": string,"offered_at": string,"order_id": string,"responded_at": string | null,"rider_id": string,"round_no": number,"status": Database["public"]['Enums']["dispatch_offer_status"]
                  }
                  ComputedFields: never
                  Insert: {
                    "attempt_no": number,"distance_to_pickup_m": number,"expires_at": string,"id"?: string,"offered_at"?: string,"order_id": string,"responded_at"?: string | null,"rider_id": string,"round_no": number,"status"?: Database["public"]['Enums']["dispatch_offer_status"]
                  }
                  Update: {
                    "attempt_no"?: number,"distance_to_pickup_m"?: number,"expires_at"?: string,"id"?: string,"offered_at"?: string,"order_id"?: string,"responded_at"?: string | null,"rider_id"?: string,"round_no"?: number,"status"?: Database["public"]['Enums']["dispatch_offer_status"]
                  }
                  Relationships: [
                    {
      foreignKeyName: "dispatch_offers_order_id_fkey"
      columns: ["order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "dispatch_offers_rider_id_fkey"
      columns: ["rider_id"]
isOneToOne: false
      referencedRelation: "rider_details"
      referencedColumns: ["user_id"]
    }
                  ]
                },"order_admin_actions": {
                  Row: {
                    "action": string,"created_at": string,"id": string,"note": string,"order_id": string,"recorded_by": string
                  }
                  ComputedFields: never
                  Insert: {
                    "action": string,"created_at"?: string,"id"?: string,"note": string,"order_id": string,"recorded_by": string
                  }
                  Update: {
                    "action"?: string,"created_at"?: string,"id"?: string,"note"?: string,"order_id"?: string,"recorded_by"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "order_admin_actions_order_id_fkey"
      columns: ["order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["id"]
    }
                  ]
                },"order_contacts": {
                  Row: {
                    "created_at": string,"order_id": string,"receiver_name": string,"receiver_phone": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"order_id": string,"receiver_name": string,"receiver_phone": string
                  }
                  Update: {
                    "created_at"?: string,"order_id"?: string,"receiver_name"?: string,"receiver_phone"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "order_contacts_order_id_fkey"
      columns: ["order_id"]
isOneToOne: true
      referencedRelation: "orders"
      referencedColumns: ["id"]
    }
                  ]
                },"order_delivery_pins": {
                  Row: {
                    "created_at": string,"locked_at": string | null,"order_id": string,"pin": string,"wrong_attempts": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"locked_at"?: string | null,"order_id": string,"pin": string,"wrong_attempts"?: number
                  }
                  Update: {
                    "created_at"?: string,"locked_at"?: string | null,"order_id"?: string,"pin"?: string,"wrong_attempts"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "order_delivery_pins_order_id_fkey"
      columns: ["order_id"]
isOneToOne: true
      referencedRelation: "orders"
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
                },"order_payment_disputes": {
                  Row: {
                    "created_at": string,"details": string | null,"found_false": boolean,"id": string,"opened_by_admin": string | null,"order_id": string,"outcome": string | null,"raised_as": string,"raised_by": string,"reason": string,"resolution_note": string | null,"resolved_at": string | null,"resolved_by": string | null,"status": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"details"?: string | null,"found_false"?: boolean,"id"?: string,"opened_by_admin"?: string | null,"order_id": string,"outcome"?: string | null,"raised_as": string,"raised_by": string,"reason": string,"resolution_note"?: string | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"status"?: string
                  }
                  Update: {
                    "created_at"?: string,"details"?: string | null,"found_false"?: boolean,"id"?: string,"opened_by_admin"?: string | null,"order_id"?: string,"outcome"?: string | null,"raised_as"?: string,"raised_by"?: string,"reason"?: string,"resolution_note"?: string | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"status"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "order_payment_disputes_order_id_fkey"
      columns: ["order_id"]
isOneToOne: false
      referencedRelation: "orders"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "order_payment_disputes_raised_by_fkey"
      columns: ["raised_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"order_quotes": {
                  Row: {
                    "base_fee_kobo": number,"commission_bps": number,"commission_kobo": number,"created_at": string,"customer_id": string,"distance_m": number,"distance_source": Database["public"]['Enums']["order_distance_source"],"dropoff_address": string,"dropoff_lat": number,"dropoff_lng": number,"dropoff_place_id": string | null,"expires_at": string,"id": string,"order_id": string | null,"per_km_rate_kobo": number,"pickup_address": string,"pickup_lat": number,"pickup_lng": number,"pickup_place_id": string | null,"price_kobo": number
                  }
                  ComputedFields: never
                  Insert: {
                    "base_fee_kobo": number,"commission_bps": number,"commission_kobo": number,"created_at"?: string,"customer_id": string,"distance_m": number,"distance_source": Database["public"]['Enums']["order_distance_source"],"dropoff_address": string,"dropoff_lat": number,"dropoff_lng": number,"dropoff_place_id"?: string | null,"expires_at": string,"id"?: string,"order_id"?: string | null,"per_km_rate_kobo": number,"pickup_address": string,"pickup_lat": number,"pickup_lng": number,"pickup_place_id"?: string | null,"price_kobo": number
                  }
                  Update: {
                    "base_fee_kobo"?: number,"commission_bps"?: number,"commission_kobo"?: number,"created_at"?: string,"customer_id"?: string,"distance_m"?: number,"distance_source"?: Database["public"]['Enums']["order_distance_source"],"dropoff_address"?: string,"dropoff_lat"?: number,"dropoff_lng"?: number,"dropoff_place_id"?: string | null,"expires_at"?: string,"id"?: string,"order_id"?: string | null,"per_km_rate_kobo"?: number,"pickup_address"?: string,"pickup_lat"?: number,"pickup_lng"?: number,"pickup_place_id"?: string | null,"price_kobo"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "order_quotes_customer_id_fkey"
      columns: ["customer_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"orders": {
                  Row: {
                    "accepted_at": string | null,"arrived_dropoff_at": string | null,"arrived_pickup_at": string | null,"base_fee_kobo": number | null,"cancelled_at": string | null,"commission_bps": number | null,"commission_kobo": number,"created_at": string,"customer_id": string,"customer_reported_paid_at": string | null,"delivered_at": string | null,"dispatch_round": number,"dispatch_started_at": string | null,"distance_m": number | null,"distance_source": Database["public"]['Enums']["order_distance_source"] | null,"dropoff_address": string,"dropoff_lat": number,"dropoff_lng": number,"dropoff_place_id": string | null,"dropoff_postcode": string | null,"id": string,"package_description": string | null,"payee_account_id": string | null,"payment_confirmed_at": string | null,"payment_confirmed_by": string | null,"payment_failed_at": string | null,"payment_reference": string | null,"payment_status": Database["public"]['Enums']["payment_status"],"per_km_rate_kobo": number | null,"picked_up_at": string | null,"pickup_address": string,"pickup_lat": number,"pickup_lng": number,"pickup_place_id": string | null,"pickup_postcode": string | null,"price_kobo": number,"priced_with_fallback": boolean | null,"quote_id": string | null,"rider_id": string | null,"status": Database["public"]['Enums']["order_status"],"updated_at": string,"order_ended_at": string | null
                  }
                  ComputedFields: "order_ended_at"
                  Insert: {
                    "accepted_at"?: string | null,"arrived_dropoff_at"?: string | null,"arrived_pickup_at"?: string | null,"base_fee_kobo"?: number | null,"cancelled_at"?: string | null,"commission_bps"?: number | null,"commission_kobo": number,"created_at"?: string,"customer_id": string,"customer_reported_paid_at"?: string | null,"delivered_at"?: string | null,"dispatch_round"?: number,"dispatch_started_at"?: string | null,"distance_m"?: number | null,"distance_source"?: Database["public"]['Enums']["order_distance_source"] | null,"dropoff_address": string,"dropoff_lat": number,"dropoff_lng": number,"dropoff_place_id"?: string | null,"dropoff_postcode"?: string | null,"id"?: string,"package_description"?: string | null,"payee_account_id"?: string | null,"payment_confirmed_at"?: string | null,"payment_confirmed_by"?: string | null,"payment_failed_at"?: string | null,"payment_reference"?: never,"payment_status"?: Database["public"]['Enums']["payment_status"],"per_km_rate_kobo"?: number | null,"picked_up_at"?: string | null,"pickup_address": string,"pickup_lat": number,"pickup_lng": number,"pickup_place_id"?: string | null,"pickup_postcode"?: string | null,"price_kobo": number,"priced_with_fallback"?: never,"quote_id"?: string | null,"rider_id"?: string | null,"status"?: Database["public"]['Enums']["order_status"],"updated_at"?: string
                  }
                  Update: {
                    "accepted_at"?: string | null,"arrived_dropoff_at"?: string | null,"arrived_pickup_at"?: string | null,"base_fee_kobo"?: number | null,"cancelled_at"?: string | null,"commission_bps"?: number | null,"commission_kobo"?: number,"created_at"?: string,"customer_id"?: string,"customer_reported_paid_at"?: string | null,"delivered_at"?: string | null,"dispatch_round"?: number,"dispatch_started_at"?: string | null,"distance_m"?: number | null,"distance_source"?: Database["public"]['Enums']["order_distance_source"] | null,"dropoff_address"?: string,"dropoff_lat"?: number,"dropoff_lng"?: number,"dropoff_place_id"?: string | null,"dropoff_postcode"?: string | null,"id"?: string,"package_description"?: string | null,"payee_account_id"?: string | null,"payment_confirmed_at"?: string | null,"payment_confirmed_by"?: string | null,"payment_failed_at"?: string | null,"payment_reference"?: never,"payment_status"?: Database["public"]['Enums']["payment_status"],"per_km_rate_kobo"?: number | null,"picked_up_at"?: string | null,"pickup_address"?: string,"pickup_lat"?: number,"pickup_lng"?: number,"pickup_place_id"?: string | null,"pickup_postcode"?: string | null,"price_kobo"?: number,"priced_with_fallback"?: never,"quote_id"?: string | null,"rider_id"?: string | null,"status"?: Database["public"]['Enums']["order_status"],"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "orders_customer_id_fkey"
      columns: ["customer_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "orders_payee_account_id_fkey"
      columns: ["payee_account_id"]
isOneToOne: false
      referencedRelation: "rider_bank_accounts"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "orders_quote_id_fkey"
      columns: ["quote_id"]
isOneToOne: true
      referencedRelation: "order_quotes"
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
                },"service_areas": {
                  Row: {
                    "active": boolean,"center_lat": number,"center_lng": number,"created_at": string,"id": string,"name": string,"radius_m": number
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"center_lat": number,"center_lng": number,"created_at"?: string,"id"?: string,"name": string,"radius_m": number
                  }
                  Update: {
                    "active"?: boolean,"center_lat"?: number,"center_lng"?: number,"created_at"?: string,"id"?: string,"name"?: string,"radius_m"?: number
                  }
                  Relationships: [
                    
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
            "accept_offer":
{ Args: { "p_offer_id": string }; Returns: string
                           },
"accrue_trip_commission":
{ Args: { "p_order_id": string }; Returns: boolean
                           },
"admin_cancel_order":
{ Args: { "p_on_behalf_of": string,"p_order_id": string,"p_reason": string,"p_recorded_by": string }; Returns: undefined
                           },
"admin_complete_delivery":
{ Args: { "p_note": string,"p_order_id": string,"p_recorded_by": string }; Returns: undefined
                           },
"admin_confirm_payment":
{ Args: { "p_note": string,"p_order_id": string,"p_recorded_by": string }; Returns: undefined
                           },
"admin_mark_arrived_at_dropoff":
{ Args: { "p_note": string,"p_order_id": string,"p_recorded_by": string }; Returns: undefined
                           },
"admin_open_payment_dispute":
{ Args: { "p_details": string,"p_order_id": string,"p_raised_as": string,"p_reason": string,"p_recorded_by": string }; Returns: string
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
"apply_payment_confirmed":
{ Args: { "p_by": string,"p_order_id": string }; Returns: undefined
                           },
"apply_payment_refused":
{ Args: { "p_order_id": string }; Returns: undefined
                           },
"approve_rider_bank_account":
{ Args: { "p_account_id": string,"p_note"?: string,"p_recorded_by": string,"p_verified_name": string }; Returns: undefined
                           },
"bank_account_name_match":
{ Args: { "p_account_name": string,"p_kyc_name": string }; Returns: Database["public"]['Enums']["bank_name_match"]
                           },
"begin_dispatch":
{ Args: { "p_order_id": string }; Returns: string
                           },
"can_raise_dispute":
{ Args: { "o": Omit<Database["public"]['Tables']["orders"]['Row'], Database["public"]['Tables']["orders"]['ComputedFields']>,"p_role": string }; Returns: boolean
                           },
"cancel_order":
{ Args: { "p_order_id": string }; Returns: undefined
                           },
"check_admin_text":
{ Args: { "p_note": string,"p_recorded_by": string }; Returns: undefined
                           },
"commission_for_price":
{ Args: { "p_bps": number,"p_price_kobo": number }; Returns: number
                           },
"commission_reference_code":
{ Args: { "p_cycle_no": number,"p_rider_id": string }; Returns: string
                           },
"compass_direction":
{ Args: { "p_from_lat": number,"p_from_lng": number,"p_to_lat": number,"p_to_lng": number }; Returns: string
                           },
"complete_delivery":
{ Args: { "p_order_id": string,"p_pin": string }; Returns: {
              "attempts_left": number,"result": string
            }[]
                           },
"confirm_payment_received":
{ Args: { "p_order_id": string }; Returns: undefined
                           },
"create_order_from_quote":
{ Args: { "p_package_description": string,"p_quote_id": string,"p_receiver_name": string,"p_receiver_phone": string }; Returns: string
                           },
"create_order_quote":
{ Args: { "p_customer_id": string,"p_distance_m": number,"p_distance_source": Database["public"]['Enums']["order_distance_source"],"p_dropoff_address": string,"p_dropoff_lat": number,"p_dropoff_lng": number,"p_dropoff_place_id": string,"p_pickup_address": string,"p_pickup_lat": number,"p_pickup_lng": number,"p_pickup_place_id": string }; Returns: {
              "base_fee_kobo": number,
"commission_bps": number,
"commission_kobo": number,
"created_at": string,
"customer_id": string,
"distance_m": number,
"distance_source": Database["public"]['Enums']["order_distance_source"],
"dropoff_address": string,
"dropoff_lat": number,
"dropoff_lng": number,
"dropoff_place_id": string | null,
"expires_at": string,
"id": string,
"order_id": string | null,
"per_km_rate_kobo": number,
"pickup_address": string,
"pickup_lat": number,
"pickup_lng": number,
"pickup_place_id": string | null,
"price_kobo": number
            }
                          SetofOptions: {
        from: "*"
        to: "order_quotes"
        isOneToOne: true
        isSetofReturn: false
      } },
"customer_has_unsettled_order":
{ Args: { "p_customer_id": string }; Returns: boolean
                           },
"customer_role_is_active":
{ Args: { "p_user_id": string }; Returns: boolean
                           },
"customer_unsettled_order":
{ Args: { "p_customer_id": string }; Returns: {
              "order_id": string,"reason": string
            }[]
                           },
"decline_offer":
{ Args: { "p_offer_id": string }; Returns: undefined
                           },
"distance_between_m":
{ Args: { "p_lat1": number,"p_lat2": number,"p_lng1": number,"p_lng2": number }; Returns: number
                           },
"end_search_no_rider":
{ Args: { "p_order_id": string }; Returns: undefined
                           },
"expire_stale_riders":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"flag_after_false_disputes":
{ Args: { "p_role": string,"p_user_id": string }; Returns: undefined
                           },
"flag_after_late_cancels":
{ Args: { "p_role": string,"p_user_id": string }; Returns: undefined
                           },
"flag_after_unpaid_abandons":
{ Args: { "p_customer_id": string }; Returns: undefined
                           },
"get_assigned_rider_location":
{ Args: { "p_order_id": string }; Returns: {
              "accuracy_m": number,"distance_to_dropoff_m": number,"distance_to_pickup_m": number,"lat": number,"lng": number,"updated_at": string
            }[]
                           },
"get_company_payment_account":
{ Args: Record<PropertyKey, never>; Returns: {
              "account_name": string,"account_number": string,"bank_name": string
            }[]
                           },
"get_delivery_pin":
{ Args: { "p_order_id": string }; Returns: string
                           },
"get_job_payment_info":
{ Args: { "p_order_id": string }; Returns: {
              "can_raise_dispute": boolean,"open_dispute_raised_as": string,"pin_attempts_left": number,"pin_locked": boolean,"refuse_available_at": string
            }[]
                           },
"get_my_active_job":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"get_my_offer":
{ Args: Record<PropertyKey, never>; Returns: {
              "area_name": string,"direction": string,"distance_to_pickup_m": number,"offer_id": string,"order_id": string,"price_kobo": number,"seconds_left": number,"trip_distance_m": number
            }[]
                           },
"get_my_order_block":
{ Args: Record<PropertyKey, never>; Returns: {
              "order_id": string,"reason": string
            }[]
                           },
"get_order_contact_details":
{ Args: { "p_order_id": string }; Returns: {
              "customer_name": string,"customer_phone": string,"receiver_name": string,"receiver_phone": string
            }[]
                           },
"get_order_dispute":
{ Args: { "p_order_id": string }; Returns: {
              "can_raise": boolean,"created_at": string,"dispute_status": string,"outcome": string,"raised_as": string,"reason": string,"resolved_at": string
            }[]
                           },
"get_order_receipt":
{ Args: { "p_order_id": string }; Returns: {
              "account_masked": string,"account_name": string,"bank_name": string,"delivered_at": string,"order_status": Database["public"]['Enums']["order_status"],"payment_confirmed_at": string,"payment_confirmed_by": string,"payment_reference": string,"plate_number": string,"price_kobo": number,"rider_name": string
            }[]
                           },
"get_order_rider":
{ Args: { "p_order_id": string }; Returns: {
              "account_name": string,"account_number": string,"bank_name": string,"bike_colour": string,"bike_make_model": string,"plate_number": string,"rider_name": string
            }[]
                           },
"has_active_role":
{ Args: { "r": Database["public"]['Enums']["app_role"] }; Returns: boolean
                           },
"is_admin":
{ Args: Record<PropertyKey, never>; Returns: boolean
                           },
"is_admin_caller":
{ Args: Record<PropertyKey, never>; Returns: boolean
                           },
"is_own_kyc_file":
{ Args: { "p_path": string,"p_user_id": string }; Returns: boolean
                           },
"lock_dispatch":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"lock_rider_commission":
{ Args: { "p_rider_id": string }; Returns: undefined
                           },
"mark_arrived_at_dropoff":
{ Args: { "p_order_id": string }; Returns: undefined
                           },
"mark_arrived_at_pickup":
{ Args: { "p_order_id": string }; Returns: undefined
                           },
"mark_payment_refused":
{ Args: { "p_order_id": string }; Returns: undefined
                           },
"mark_picked_up":
{ Args: { "p_order_id": string }; Returns: undefined
                           },
"new_delivery_pin":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"offer_next_rider":
{ Args: { "p_order_id": string }; Returns: string
                           },
"open_review_flag":
{ Args: { "p_reason": string,"p_role": string,"p_user_id": string }; Returns: undefined
                           },
"order_counts_as_trip":
{ Args: { "p_payment_status": Database["public"]['Enums']["payment_status"],"p_status": Database["public"]['Enums']["order_status"] }; Returns: boolean
                           },
"order_ended_at":
{ Args: { "o": Omit<Database["public"]['Tables']["orders"]['Row'], Database["public"]['Tables']["orders"]['ComputedFields']> }; Returns: string
                           },
"point_in_service_area":
{ Args: { "p_lat": number,"p_lng": number }; Returns: boolean
                           },
"price_for_distance":
{ Args: { "p_base_fee_kobo": number,"p_distance_m": number,"p_per_km_rate_kobo": number }; Returns: number
                           },
"raise_payment_dispute":
{ Args: { "p_details": string,"p_order_id": string,"p_reason": string }; Returns: string
                           },
"record_commission_payment":
{ Args: { "p_amount_kobo": number,"p_bank_reference": string,"p_note": string,"p_paid_at": string,"p_recorded_by": string,"p_reference_code": string }; Returns: number
                           },
"reject_rider_bank_account":
{ Args: { "p_account_id": string,"p_reason": string,"p_recorded_by": string }; Returns: undefined
                           },
"report_payment_sent":
{ Args: { "p_order_id": string }; Returns: undefined
                           },
"resolve_payment_dispute":
{ Args: { "p_dispute_id": string,"p_found_false": boolean,"p_note": string,"p_outcome": string,"p_recorded_by": string }; Returns: undefined
                           },
"resolve_review_flag":
{ Args: { "p_flag_id": string,"p_note": string,"p_recorded_by": string }; Returns: undefined
                           },
"retry_dispatch":
{ Args: { "p_order_id": string }; Returns: undefined
                           },
"reverse_commission_entry":
{ Args: { "p_entry_id": string,"p_reason": string,"p_recorded_by": string }; Returns: number
                           },
"revoke_rider_bank_account":
{ Args: { "p_account_id": string,"p_reason": string,"p_recorded_by": string }; Returns: undefined
                           },
"rider_can_take_job":
{ Args: { "p_rider_id": string }; Returns: boolean
                           },
"rider_cancel_job":
{ Args: { "p_order_id": string,"p_reason": string }; Returns: undefined
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
"rider_is_dispatchable":
{ Args: { "p_rider_id": string }; Returns: boolean
                           },
"rider_role_is_active":
{ Args: { "p_user_id": string }; Returns: boolean
                           },
"rider_stale_cutoff":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"run_dispatch_sweep":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"set_company_payment_account":
{ Args: { "p_account_name": string,"p_account_number": string,"p_bank_name": string,"p_changed_by": string }; Returns: undefined
                           },
"settle_commission_cycles":
{ Args: { "p_rider_id": string }; Returns: undefined
                           },
"start_dispatch":
{ Args: { "p_order_id": string }; Returns: string
                           },
"submit_rider_bank_account":
{ Args: { "p_account_name": string,"p_account_number": string,"p_bank_name": string }; Returns: string
                           },
"take_rider_offline_for_commission":
{ Args: { "p_rider_id": string }; Returns: undefined
                           },
"use_api_quota":
{ Args: { "p_google_calls": number,"p_kind": string,"p_user_id": string }; Returns: undefined
                           },
"withdraw_pending_offers":
{ Args: { "p_order_id": string }; Returns: undefined
                           }
          }
          Enums: {
            "app_role": "customer"|"rider"|"admin","bank_account_status": "pending"|"verified"|"rejected"|"withdrawn"|"replaced"|"revoked","bank_name_match": "match"|"partial"|"mismatch","cancel_stage": "before_accept"|"after_accept"|"after_pickup","commission_cycle_status": "open"|"due"|"paid","commission_entry_type": "commission"|"payment"|"reversal","dispatch_offer_status": "pending"|"accepted"|"declined"|"expired"|"withdrawn","kyc_status": "pending"|"approved"|"rejected","order_distance_source": "routes"|"straight_line_fallback","order_status": "created"|"rider_requested"|"accepted"|"picked_up"|"delivered"|"completed"|"cancelled_by_customer"|"cancelled_by_rider"|"no_rider_found"|"payment_failed","payment_status": "unpaid"|"awaiting_payment"|"paid"|"failed","role_status": "active"|"suspended","vehicle_type": "bike"
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
            "app_role": ["customer", "rider", "admin"],"bank_account_status": ["pending", "verified", "rejected", "withdrawn", "replaced", "revoked"],"bank_name_match": ["match", "partial", "mismatch"],"cancel_stage": ["before_accept", "after_accept", "after_pickup"],"commission_cycle_status": ["open", "due", "paid"],"commission_entry_type": ["commission", "payment", "reversal"],"dispatch_offer_status": ["pending", "accepted", "declined", "expired", "withdrawn"],"kyc_status": ["pending", "approved", "rejected"],"order_distance_source": ["routes", "straight_line_fallback"],"order_status": ["created", "rider_requested", "accepted", "picked_up", "delivered", "completed", "cancelled_by_customer", "cancelled_by_rider", "no_rider_found", "payment_failed"],"payment_status": ["unpaid", "awaiting_payment", "paid", "failed"],"role_status": ["active", "suspended"],"vehicle_type": ["bike"]
          }
        }
} as const
