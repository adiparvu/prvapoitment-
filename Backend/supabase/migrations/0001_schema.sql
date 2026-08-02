-- =============================================================================
-- PRV Beauty — 0001_schema.sql
--
-- The relational mirror of `Sources/PRVModels`. Conventions, applied without
-- exception:
--
--   * tables and columns are snake_case; every enum label matches the Swift
--     `RawValue` byte for byte so `JSONDecoder(keyDecodingStrategy:
--     .convertFromSnakeCase)` decodes a PostgREST row straight into the
--     domain type.
--   * primary keys are `uuid` and default to `gen_random_uuid()`; the Swift
--     side wraps them in `PRVID<Entity>`.
--   * timestamps are `timestamptz` — the database is the single clock.
--   * money is `numeric(12,2)` plus a `char(3)` currency column, never a
--     float. `Money` = (amount, currency).
--   * percentages are integers constrained to 0…100, ratings to 1…5, and
--     every amount that can only be a credit is constrained non-negative.
--
-- Row Level Security is enabled in 0002; triggers, the booking RPC, and the
-- loyalty/stock automation live in 0003. This file only defines shape.
-- =============================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid(), crypt()
create extension if not exists btree_gist; -- uuid `=` inside a gist exclusion

-- -----------------------------------------------------------------------------
-- Enumerations
-- -----------------------------------------------------------------------------

-- PRVModels/User.swift — UserRole
create type user_role as enum (
  'guest',
  'client',
  'premium_client',
  'freelancer',
  'salon_employee',
  'salon_manager',
  'salon_owner',
  'multi_salon_owner',
  'regional_manager',
  'support',
  'finance',
  'marketing',
  'administrator',
  'super_admin',
  'developer'
);

-- PRVModels/User.swift — Permission.
--
-- NOTE: `Permission` has no explicit raw values in Swift, so its wire format is
-- the camelCase case name. These labels intentionally break the snake_case
-- house rule so that permission payloads round-trip without a custom coding
-- key strategy. The role → permission mapping in `role_permissions` mirrors
-- `UserRole.permissions` exactly and is the server-side source of truth.
create type permission as enum (
  'browse',
  'book',
  'review',
  'chat',
  'payOnline',
  'priorityBooking',
  'manageOwnCalendar',
  'manageOwnServices',
  'viewOwnEarnings',
  'viewClients',
  'checkInOut',
  'manageCalendar',
  'manageTeam',
  'manageInventory',
  'viewReports',
  'manageServices',
  'respondToReviews',
  'manageCRM',
  'manageSalon',
  'managePayroll',
  'manageMarketing',
  'manageMemberships',
  'manageFinance',
  'configurePrepayment',
  'manageMultipleLocations',
  'compareLocations',
  'manageRefunds',
  'moderateReviews',
  'manageFeatureFlags',
  'developerTools'
);

-- PRVModels/Salon.swift
create type business_category as enum (
  'hair_salon', 'nail_studio', 'lash_studio', 'brow_studio', 'makeup_studio',
  'barbershop', 'spa', 'massage', 'esthetics', 'cosmetic_clinic'
);

create type salon_amenity as enum (
  'parking', 'wheelchair_access', 'pet_friendly', 'women_only', 'men_only',
  'luxury', 'premium', 'kid_friendly', 'wifi', 'refreshments'
);

-- PRVModels/Professional.swift — PortfolioItem.Kind
create type portfolio_item_kind as enum ('photo', 'video', 'before_after');

-- PRVModels/Appointment.swift
create type appointment_status as enum (
  'pending_confirmation',
  'confirmed',
  'checked_in',
  'in_progress',
  'completed',
  'cancelled_by_client',
  'cancelled_by_salon',
  'no_show'
);

create type recurrence_frequency as enum ('weekly', 'biweekly', 'every_4_weeks', 'monthly');

-- PRVModels/Payments.swift
create type order_status as enum (
  'draft', 'awaiting_payment', 'partially_paid', 'paid',
  'refunded', 'partially_refunded', 'failed', 'cancelled'
);

create type order_line_kind as enum (
  'service', 'product', 'membership', 'package', 'gift_card', 'tip', 'fee'
);

create type payment_method_kind as enum (
  'apple_pay', 'card', 'bancontact', 'paypal', 'gift_card', 'store_credit', 'cash_on_site'
);

create type refund_reason as enum ('cancellation', 'service_issue', 'duplicate', 'fraud', 'goodwill');

create type wallet_transaction_kind as enum (
  'payment', 'refund', 'cashback', 'store_credit_top_up',
  'store_credit_spend', 'gift_card_redemption', 'reward_points'
);

-- PRVModels/Membership.swift
create type membership_tier as enum ('silver', 'gold', 'diamond', 'black', 'custom');
create type billing_cycle as enum ('monthly', 'quarterly', 'yearly');
create type membership_benefit_kind as enum (
  'free_service', 'discount_percent', 'priority_booking',
  'birthday_gift', 'exclusive_events', 'partner_benefit'
);
create type subscription_status as enum ('active', 'past_due', 'cancelled', 'expired');
create type package_theme as enum (
  'wedding', 'holiday', 'seasonal', 'monthly', 'luxury_spa', 'combo', 'custom'
);

-- PRVModels/Loyalty.swift
create type loyalty_tier as enum ('bronze', 'silver', 'gold', 'diamond', 'black');

-- PRVModels/Review.swift — Review.ModerationStatus
create type review_moderation_status as enum ('pending', 'approved', 'flagged', 'removed');

-- PRVModels/Chat.swift
create type conversation_kind as enum ('client_salon', 'client_professional', 'assistant', 'support');
create type message_delivery_state as enum ('sending', 'sent', 'delivered', 'read', 'failed');
create type message_content_kind as enum (
  'text', 'photo', 'video', 'voice', 'appointment_request', 'recommendation'
);

-- PRVModels/Notifications.swift — PRVNotification.Kind
create type notification_kind as enum (
  'appointment_reminder', 'appointment_confirmed', 'appointment_cancelled',
  'waitlist_slot_opened', 'promotion', 'review_request', 'membership_renewal',
  'package_expiring', 'price_change', 'loyalty_reward', 'chat_message', 'system'
);

-- PRVModels/CRM.swift — ClientNote.Kind
create type client_note_kind as enum ('general', 'color_formula', 'treatment', 'photo');

-- PRVModels/Team.swift
create type compensation_model as enum ('salary', 'hourly', 'commission', 'hybrid');
create type performance_metric as enum (
  'revenue', 'appointments', 'retail_sales', 'rebook_rate', 'review_score'
);

-- PRVModels/Inventory.swift — PurchaseOrder.Status
create type purchase_order_status as enum ('draft', 'sent', 'received', 'cancelled');

-- PRVModels/Marketing.swift
create type campaign_kind as enum ('promotion', 'referral', 'birthday', 'win_back', 'new_service', 'automatic');
create type campaign_channel as enum ('push', 'email', 'sms');
create type campaign_status as enum ('draft', 'scheduled', 'running', 'completed', 'paused');
create type coupon_discount_kind as enum ('percent', 'fixed');

-- PRVPersistence/SyncContracts.swift — SyncOperation.Kind. Used by the audit
-- log and by the offline replay endpoint so a queued mutation names its own
-- verb in the same vocabulary the client used.
create type sync_operation_kind as enum ('create', 'update', 'delete');

-- Push transport for `device_tokens`.
create type device_platform as enum ('ios', 'android', 'web');

-- -----------------------------------------------------------------------------
-- Shared domains
-- -----------------------------------------------------------------------------

-- PRVModels/Money.swift — Currency.
create domain currency_code as char(3)
  check (value in ('EUR', 'USD', 'GBP', 'CHF', 'RON'));

-- Money amounts. Signed: wallet debits and discounts are legitimately negative.
create domain money_amount as numeric(12, 2);

create domain percent_0_100 as integer check (value between 0 and 100);

-- -----------------------------------------------------------------------------
-- Identity
-- -----------------------------------------------------------------------------

-- Mirrors `User`. One row per `auth.users` row; deleting the auth user cascades
-- so a GDPR erasure request removes the profile in the same transaction.
create table profiles (
  id                 uuid primary key references auth.users (id) on delete cascade,
  role               user_role   not null default 'client',
  first_name         text        not null default '',
  last_name          text        not null default '',
  email              text        not null,
  phone              text,
  avatar_url         text,
  preferred_language text        not null default 'en',
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint profiles_email_not_blank check (length(btrim(email)) > 0)
);

create unique index profiles_email_key on profiles (lower(email));
create index profiles_role_idx on profiles (role);

-- Role → permission matrix, seeded in 0004 to mirror `UserRole.permissions`.
-- Kept as data rather than code so the platform team can audit it with a query.
create table role_permissions (
  role       user_role  not null,
  permission permission not null,
  primary key (role, permission)
);

-- Mirrors `Organization`: a brand that owns several locations.
create table organizations (
  id         uuid        primary key default gen_random_uuid(),
  name       text        not null,
  owner_id   uuid        not null references profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index organizations_owner_idx on organizations (owner_id);

-- -----------------------------------------------------------------------------
-- Salons
-- -----------------------------------------------------------------------------

-- Mirrors `Salon`. `SalonPolicies` is flattened into the policy_* columns;
-- `PrepaymentPolicy` and `OpeningHours` get their own tables below.
create table salons (
  id                uuid              primary key default gen_random_uuid(),
  organization_id   uuid              references organizations (id) on delete set null,
  name              text              not null,
  tagline           text,
  about             text              not null default '',
  categories        business_category[] not null default '{}',
  amenities         salon_amenity[]   not null default '{}',
  languages         text[]            not null default '{en}',
  street            text              not null,
  city              text              not null,
  postal_code       text              not null,
  country           char(2)           not null,
  latitude          double precision  not null,
  longitude         double precision  not null,
  phone             text,
  email             text,
  hero_image_url    text,
  hero_video_url    text,
  gallery_urls      text[]            not null default '{}',
  instagram_handle  text,
  tiktok_handle     text,
  virtual_tour_url  text,
  certificates      text[]            not null default '{}',
  awards            text[]            not null default '{}',
  currency          currency_code     not null default 'EUR',
  rating            numeric(3, 2)     not null default 0,
  review_count      integer           not null default 0,
  is_verified       boolean           not null default false,
  is_active         boolean           not null default true,
  -- SalonPolicies
  policy_free_cancellation_hours   integer       not null default 24,
  policy_late_cancellation_percent percent_0_100 not null default 50,
  policy_no_show_percent           percent_0_100 not null default 100,
  policy_late_grace_minutes        integer       not null default 10,
  policy_children_allowed          boolean       not null default true,
  policy_notes                     text,
  created_at        timestamptz       not null default now(),
  updated_at        timestamptz       not null default now(),
  constraint salons_rating_range check (rating between 0 and 5),
  constraint salons_review_count_non_negative check (review_count >= 0),
  constraint salons_latitude_range check (latitude between -90 and 90),
  constraint salons_longitude_range check (longitude between -180 and 180),
  constraint salons_free_cancellation_hours_non_negative check (policy_free_cancellation_hours >= 0),
  constraint salons_late_grace_non_negative check (policy_late_grace_minutes >= 0)
);

create index salons_city_idx on salons (lower(city));
create index salons_rating_idx on salons (rating desc) where is_active;
create index salons_organization_idx on salons (organization_id);
-- Discover's "salons near me" filters on a bounding box before ranking.
create index salons_geo_idx on salons (latitude, longitude) where is_active;
create index salons_categories_idx on salons using gin (categories);
create index salons_amenities_idx on salons using gin (amenities);

-- Mirrors `OpeningHours`: one row per weekday interval. A weekday with no rows
-- is closed, which is exactly `intervals.isEmpty`.
create table salon_opening_hours (
  id            uuid    primary key default gen_random_uuid(),
  salon_id      uuid    not null references salons (id) on delete cascade,
  weekday       integer not null,
  open_minutes  integer not null,
  close_minutes integer not null,
  constraint salon_opening_hours_weekday_range check (weekday between 1 and 7),
  constraint salon_opening_hours_open_range check (open_minutes between 0 and 1440),
  constraint salon_opening_hours_close_range check (close_minutes between 0 and 1440),
  constraint salon_opening_hours_ordered check (close_minutes > open_minutes)
);

create index salon_opening_hours_salon_idx on salon_opening_hours (salon_id, weekday);

-- Mirrors `PrepaymentPolicy` — the owner-configured prepayment incentives.
create table prepayment_policies (
  salon_id                          uuid          primary key references salons (id) on delete cascade,
  offered_percents                  integer[]     not null default '{20,50,100}',
  full_prepayment_discount_percent  percent_0_100 not null default 10,
  reward_points_multiplier          integer       not null default 2,
  cashback_percent                  percent_0_100 not null default 2,
  grants_priority_booking           boolean       not null default true,
  updated_at                        timestamptz   not null default now(),
  constraint prepayment_policies_multiplier_range check (reward_points_multiplier between 1 and 10),
  -- `PrepaymentPolicy.Percent` is a closed set in Swift; keep it closed here.
  constraint prepayment_policies_offered_percents_valid
    check (offered_percents <@ array[10, 20, 30, 50, 100])
);

-- -----------------------------------------------------------------------------
-- Professionals & services
-- -----------------------------------------------------------------------------

-- Mirrors `Professional`. `user_id` is null for staff who have no app account
-- yet; `salon_id` is null for independent freelancers.
create table professionals (
  id                        uuid          primary key default gen_random_uuid(),
  user_id                   uuid          references profiles (id) on delete set null,
  salon_id                  uuid          references salons (id) on delete cascade,
  display_name              text          not null,
  title                     text          not null default '',
  biography                 text          not null default '',
  photo_url                 text,
  years_of_experience       integer       not null default 0,
  specialties               text[]        not null default '{}',
  languages                 text[]        not null default '{en}',
  instagram_handle          text,
  tiktok_handle             text,
  rating                    numeric(3, 2) not null default 0,
  review_count              integer       not null default 0,
  average_response_minutes  integer,
  is_freelancer             boolean       not null default false,
  is_active                 boolean       not null default true,
  created_at                timestamptz   not null default now(),
  updated_at                timestamptz   not null default now(),
  constraint professionals_rating_range check (rating between 0 and 5),
  constraint professionals_review_count_non_negative check (review_count >= 0),
  constraint professionals_experience_non_negative check (years_of_experience >= 0),
  constraint professionals_response_positive check (average_response_minutes is null or average_response_minutes > 0),
  -- A professional belongs to a salon or is a freelancer — never neither.
  constraint professionals_affiliation check (salon_id is not null or is_freelancer)
);

create index professionals_salon_idx on professionals (salon_id) where is_active;
create index professionals_user_idx on professionals (user_id);

-- Mirrors `Certificate`.
create table certificates (
  id              uuid        primary key default gen_random_uuid(),
  professional_id uuid        not null references professionals (id) on delete cascade,
  title           text        not null,
  issuer          text        not null,
  issued_at       timestamptz not null,
  document_url    text,
  created_at      timestamptz not null default now()
);

create index certificates_professional_idx on certificates (professional_id);

-- Mirrors `PortfolioItem`.
create table portfolio_items (
  id              uuid                primary key default gen_random_uuid(),
  professional_id uuid                not null references professionals (id) on delete cascade,
  kind            portfolio_item_kind not null default 'photo',
  media_url       text                not null,
  before_url      text,
  caption         text,
  created_at      timestamptz         not null default now(),
  -- A before/after item is meaningless without its "before" frame.
  constraint portfolio_items_before_after_has_before
    check (kind <> 'before_after' or before_url is not null)
);

create index portfolio_items_professional_idx on portfolio_items (professional_id, created_at desc);

-- Mirrors `SalonService` (`SalonService` in Swift; `services` here — `service`
-- is not reserved, and the plural matches every other table).
create table services (
  id                  uuid              primary key default gen_random_uuid(),
  salon_id            uuid              references salons (id) on delete cascade,
  name                text              not null,
  details             text              not null default '',
  category            business_category not null,
  price_amount        money_amount      not null,
  price_currency      currency_code     not null default 'EUR',
  is_starting_price   boolean           not null default false,
  duration_minutes    integer           not null,
  preparation_minutes integer           not null default 0,
  cleanup_minutes     integer           not null default 0,
  buffer_minutes      integer           not null default 0,
  image_url           text,
  is_active           boolean           not null default true,
  requires_prepayment boolean           not null default false,
  created_at          timestamptz       not null default now(),
  updated_at          timestamptz       not null default now(),
  constraint services_price_non_negative check (price_amount >= 0),
  constraint services_duration_positive check (duration_minutes > 0),
  constraint services_prep_non_negative check (preparation_minutes >= 0),
  constraint services_cleanup_non_negative check (cleanup_minutes >= 0),
  constraint services_buffer_non_negative check (buffer_minutes >= 0)
);

create index services_salon_idx on services (salon_id) where is_active;
create index services_category_idx on services (category) where is_active;

-- Mirrors `ServiceAddOn`.
create table service_add_ons (
  id            uuid          primary key default gen_random_uuid(),
  service_id    uuid          not null references services (id) on delete cascade,
  name          text          not null,
  price_amount  money_amount  not null,
  price_currency currency_code not null default 'EUR',
  extra_minutes integer       not null default 0,
  is_active     boolean       not null default true,
  constraint service_add_ons_price_non_negative check (price_amount >= 0),
  constraint service_add_ons_extra_minutes_non_negative check (extra_minutes >= 0)
);

create index service_add_ons_service_idx on service_add_ons (service_id) where is_active;

-- Which services a professional performs (`Professional.serviceIDs`).
create table professional_services (
  professional_id uuid not null references professionals (id) on delete cascade,
  service_id      uuid not null references services (id) on delete cascade,
  primary key (professional_id, service_id)
);

create index professional_services_service_idx on professional_services (service_id);

-- -----------------------------------------------------------------------------
-- Appointments
-- -----------------------------------------------------------------------------

-- Mirrors `Appointment`. `starts_at`/`ends_at` are denormalized from the items
-- by trigger (0003) — the calendar reads them on every screen and deriving them
-- with an aggregate per row does not survive a busy salon day.
create table appointments (
  id                    uuid                 primary key default gen_random_uuid(),
  salon_id              uuid                 not null references salons (id) on delete cascade,
  salon_name            text                 not null,
  client_id             uuid                 not null references profiles (id) on delete cascade,
  additional_client_ids uuid[]               not null default '{}',
  status                appointment_status   not null default 'pending_confirmation',
  recurrence_frequency  recurrence_frequency,
  recurrence_occurrences integer,
  order_id              uuid,
  client_notes          text,
  internal_notes        text,
  starts_at             timestamptz,
  ends_at               timestamptz,
  cancelled_at          timestamptz,
  cancellation_reason   text,
  created_at            timestamptz          not null default now(),
  updated_at            timestamptz          not null default now(),
  constraint appointments_recurrence_occurrences_positive
    check (recurrence_occurrences is null or recurrence_occurrences > 0),
  constraint appointments_recurrence_requires_frequency
    check (recurrence_occurrences is null or recurrence_frequency is not null),
  constraint appointments_span_ordered check (ends_at is null or starts_at is null or ends_at > starts_at)
);

-- The salon calendar's hot path: "everything at this location on this day".
create index appointments_salon_start_idx on appointments (salon_id, starts_at);
create index appointments_client_start_idx on appointments (client_id, starts_at desc);
create index appointments_status_idx on appointments (status) where status in
  ('pending_confirmation', 'confirmed', 'checked_in', 'in_progress');

-- Mirrors `AppointmentItem`. `is_blocking` is maintained by trigger from the
-- parent status so the exclusion constraint below can enforce, in the database,
-- that one professional is never double-booked — including against a racing
-- insert from another connection.
create table appointment_items (
  id                uuid          primary key default gen_random_uuid(),
  appointment_id    uuid          not null references appointments (id) on delete cascade,
  service_id        uuid          not null references services (id) on delete restrict,
  service_name      text          not null,
  professional_id   uuid          references professionals (id) on delete set null,
  professional_name text,
  starts_at         timestamptz   not null,
  duration_minutes  integer       not null,
  ends_at           timestamptz   not null,
  price_amount      money_amount  not null,
  price_currency    currency_code not null default 'EUR',
  add_on_ids        uuid[]        not null default '{}',
  position          integer       not null default 0,
  is_blocking       boolean       not null default true,
  constraint appointment_items_duration_positive check (duration_minutes > 0),
  constraint appointment_items_price_non_negative check (price_amount >= 0),
  constraint appointment_items_span_ordered check (ends_at > starts_at)
);

-- The staff timeline groups by professional and scans a day window.
create index appointment_items_professional_start_idx
  on appointment_items (professional_id, starts_at)
  where professional_id is not null;
create index appointment_items_appointment_idx on appointment_items (appointment_id, position);
create index appointment_items_service_idx on appointment_items (service_id);

-- Double-booking is a data-integrity problem, not an application problem.
alter table appointment_items
  add constraint appointment_items_no_overlap
  exclude using gist (
    professional_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (professional_id is not null and is_blocking);

-- Mirrors `WaitlistEntry`.
create table waitlist_entries (
  id              uuid        primary key default gen_random_uuid(),
  salon_id        uuid        not null references salons (id) on delete cascade,
  client_id       uuid        not null references profiles (id) on delete cascade,
  service_id      uuid        not null references services (id) on delete cascade,
  professional_id uuid        references professionals (id) on delete set null,
  earliest        timestamptz not null,
  latest          timestamptz not null,
  notified        boolean     not null default false,
  fulfilled_at    timestamptz,
  created_at      timestamptz not null default now(),
  constraint waitlist_entries_window_ordered check (latest > earliest)
);

create index waitlist_entries_salon_window_idx on waitlist_entries (salon_id, earliest)
  where fulfilled_at is null;
create index waitlist_entries_client_idx on waitlist_entries (client_id);

-- -----------------------------------------------------------------------------
-- Orders, payments, wallet
-- -----------------------------------------------------------------------------

-- Mirrors `Order`. Totals are never stored: `subtotal`/`total`/
-- `outstanding_balance` are computed by the `order_totals` view (0003) from the
-- lines, so a tampered client cannot talk the server into a different number.
create table orders (
  id                        uuid          primary key default gen_random_uuid(),
  salon_id                  uuid          not null references salons (id) on delete restrict,
  client_id                 uuid          not null references profiles (id) on delete restrict,
  appointment_id            uuid          references appointments (id) on delete set null,
  status                    order_status  not null default 'draft',
  discount_amount           money_amount  not null default 0,
  discount_reason           text,
  vat_percent               numeric(5, 2) not null default 21,
  amount_paid               money_amount  not null default 0,
  points_earned             integer       not null default 0,
  currency                  currency_code not null default 'EUR',
  stripe_payment_intent_id  text,
  stripe_customer_id        text,
  idempotency_key           text,
  created_at                timestamptz   not null default now(),
  updated_at                timestamptz   not null default now(),
  paid_at                   timestamptz,
  constraint orders_discount_non_negative check (discount_amount >= 0),
  constraint orders_amount_paid_non_negative check (amount_paid >= 0),
  constraint orders_points_non_negative check (points_earned >= 0),
  constraint orders_vat_range check (vat_percent between 0 and 100)
);

create unique index orders_stripe_payment_intent_key
  on orders (stripe_payment_intent_id) where stripe_payment_intent_id is not null;
create index orders_client_idx on orders (client_id, created_at desc);
create index orders_salon_idx on orders (salon_id, created_at desc);
create index orders_appointment_idx on orders (appointment_id);

alter table appointments
  add constraint appointments_order_fk
  foreign key (order_id) references orders (id) on delete set null;

-- Mirrors `OrderLine`.
create table order_lines (
  id           uuid            primary key default gen_random_uuid(),
  order_id     uuid            not null references orders (id) on delete cascade,
  kind         order_line_kind not null,
  title        text            not null,
  quantity     integer         not null default 1,
  unit_price   money_amount    not null,
  currency     currency_code   not null default 'EUR',
  reference_id uuid,
  position     integer         not null default 0,
  constraint order_lines_quantity_positive check (quantity > 0),
  constraint order_lines_unit_price_non_negative check (unit_price >= 0)
);

create index order_lines_order_idx on order_lines (order_id, position);

-- Mirrors `Refund`.
create table refunds (
  id                uuid          primary key default gen_random_uuid(),
  order_id          uuid          not null references orders (id) on delete cascade,
  amount            money_amount  not null,
  currency          currency_code not null default 'EUR',
  reason            refund_reason not null,
  note              text,
  is_automatic      boolean       not null default false,
  stripe_refund_id  text,
  created_by        uuid          references profiles (id) on delete set null,
  created_at        timestamptz   not null default now(),
  constraint refunds_amount_positive check (amount > 0)
);

create unique index refunds_stripe_refund_key on refunds (stripe_refund_id)
  where stripe_refund_id is not null;
create index refunds_order_idx on refunds (order_id, created_at desc);

-- Mirrors `GiftCard`. `code` is uppercase and globally unique.
create table gift_cards (
  id                uuid          primary key default gen_random_uuid(),
  code              text          not null,
  salon_id          uuid          references salons (id) on delete set null,
  initial_balance   money_amount  not null,
  remaining_balance money_amount  not null,
  currency          currency_code not null default 'EUR',
  purchaser_id      uuid          references profiles (id) on delete set null,
  recipient_email   text,
  message           text,
  expires_at        timestamptz,
  created_at        timestamptz   not null default now(),
  constraint gift_cards_initial_positive check (initial_balance > 0),
  constraint gift_cards_remaining_range check (remaining_balance >= 0 and remaining_balance <= initial_balance)
);

create unique index gift_cards_code_key on gift_cards (upper(code));
create index gift_cards_purchaser_idx on gift_cards (purchaser_id);

-- Mirrors `WalletTransaction`. Amount is signed: positive credits the Beauty
-- Wallet, negative debits it. The ledger is append-only.
create table wallet_transactions (
  id         uuid                    primary key default gen_random_uuid(),
  user_id    uuid                    not null references profiles (id) on delete cascade,
  kind       wallet_transaction_kind not null,
  amount     money_amount            not null,
  currency   currency_code           not null default 'EUR',
  points     integer                 not null default 0,
  title      text                    not null,
  order_id   uuid                    references orders (id) on delete set null,
  created_at timestamptz             not null default now()
);

create index wallet_transactions_user_idx on wallet_transactions (user_id, created_at desc);
create index wallet_transactions_order_idx on wallet_transactions (order_id);

-- Mirrors `Invoice`.
create table invoices (
  id        uuid        primary key default gen_random_uuid(),
  order_id  uuid        not null references orders (id) on delete cascade,
  number    text        not null,
  issued_at timestamptz not null default now(),
  pdf_url   text
);

create unique index invoices_number_key on invoices (number);
create index invoices_order_idx on invoices (order_id);

-- Mirrors `SavedPaymentMethod`.
--
-- SECURITY: this table stores Stripe tokens and display metadata only. A PAN,
-- CVC, IBAN, or any other raw instrument datum must never be written here or
-- anywhere else in this database — the app presents Apple Pay or a
-- Stripe-hosted tokenization sheet, and only the resulting `pm_…` token and the
-- last four digits ever reach us. Inserting cardholder data would put this
-- database in PCI scope; it is out of scope by construction.
create table saved_payment_methods (
  id                        uuid                primary key default gen_random_uuid(),
  user_id                   uuid                not null references profiles (id) on delete cascade,
  kind                      payment_method_kind not null,
  display_label             text                not null,
  last_four                 char(4),
  expiry_month              integer,
  expiry_year               integer,
  is_default                boolean             not null default false,
  stripe_payment_method_id  text,
  created_at                timestamptz         not null default now(),
  constraint saved_payment_methods_last_four_numeric check (last_four is null or last_four ~ '^[0-9]{4}$'),
  constraint saved_payment_methods_expiry_month_range check (expiry_month is null or expiry_month between 1 and 12),
  constraint saved_payment_methods_expiry_year_range check (expiry_year is null or expiry_year between 2020 and 2100)
);

create unique index saved_payment_methods_default_key on saved_payment_methods (user_id) where is_default;
create unique index saved_payment_methods_stripe_key on saved_payment_methods (stripe_payment_method_id)
  where stripe_payment_method_id is not null;
create index saved_payment_methods_user_idx on saved_payment_methods (user_id);

-- -----------------------------------------------------------------------------
-- Memberships & packages
-- -----------------------------------------------------------------------------

-- Mirrors `MembershipPlan`.
create table membership_plans (
  id         uuid            primary key default gen_random_uuid(),
  salon_id   uuid            not null references salons (id) on delete cascade,
  tier       membership_tier not null,
  name       text            not null,
  details    text            not null default '',
  price_amount   money_amount  not null,
  price_currency currency_code not null default 'EUR',
  cycle      billing_cycle   not null default 'monthly',
  is_active  boolean         not null default true,
  created_at timestamptz     not null default now(),
  updated_at timestamptz     not null default now(),
  constraint membership_plans_price_non_negative check (price_amount >= 0)
);

create index membership_plans_salon_idx on membership_plans (salon_id) where is_active;

-- Mirrors `MembershipBenefit`.
create table membership_benefits (
  id         uuid                    primary key default gen_random_uuid(),
  plan_id    uuid                    not null references membership_plans (id) on delete cascade,
  kind       membership_benefit_kind not null,
  title      text                    not null,
  value      integer,
  service_id uuid                    references services (id) on delete set null,
  position   integer                 not null default 0,
  constraint membership_benefits_value_non_negative check (value is null or value >= 0),
  -- A percentage benefit's value is a percentage.
  constraint membership_benefits_discount_range
    check (kind <> 'discount_percent' or (value is not null and value between 0 and 100))
);

create index membership_benefits_plan_idx on membership_benefits (plan_id, position);

-- Mirrors `MembershipSubscription`.
create table membership_subscriptions (
  id                      uuid                primary key default gen_random_uuid(),
  plan_id                 uuid                not null references membership_plans (id) on delete restrict,
  user_id                 uuid                not null references profiles (id) on delete cascade,
  status                  subscription_status not null default 'active',
  started_at              timestamptz         not null default now(),
  renews_at               timestamptz         not null,
  cancelled_at            timestamptz,
  stripe_subscription_id  text,
  created_at              timestamptz         not null default now(),
  updated_at              timestamptz         not null default now(),
  constraint membership_subscriptions_renews_after_start check (renews_at > started_at),
  constraint membership_subscriptions_cancelled_consistency
    check (status <> 'cancelled' or cancelled_at is not null)
);

create unique index membership_subscriptions_active_key
  on membership_subscriptions (user_id, plan_id) where status = 'active';
create unique index membership_subscriptions_stripe_key
  on membership_subscriptions (stripe_subscription_id) where stripe_subscription_id is not null;
create index membership_subscriptions_user_idx on membership_subscriptions (user_id, status);

-- Mirrors `ServicePackage`.
create table service_packages (
  id             uuid          primary key default gen_random_uuid(),
  salon_id       uuid          not null references salons (id) on delete cascade,
  name           text          not null,
  details        text          not null default '',
  theme          package_theme not null default 'custom',
  regular_price  money_amount  not null,
  package_price  money_amount  not null,
  currency       currency_code not null default 'EUR',
  image_url      text,
  validity_days  integer       not null default 365,
  is_active      boolean       not null default true,
  created_at     timestamptz   not null default now(),
  updated_at     timestamptz   not null default now(),
  constraint service_packages_regular_price_positive check (regular_price > 0),
  constraint service_packages_package_price_non_negative check (package_price >= 0),
  -- A "package" that costs more than its parts is a pricing bug, not an offer.
  constraint service_packages_savings_non_negative check (package_price <= regular_price),
  constraint service_packages_validity_positive check (validity_days > 0)
);

create index service_packages_salon_idx on service_packages (salon_id) where is_active;

-- Mirrors `ServicePackage.serviceIDs`.
create table package_services (
  package_id uuid    not null references service_packages (id) on delete cascade,
  service_id uuid    not null references services (id) on delete cascade,
  quantity   integer not null default 1,
  position   integer not null default 0,
  primary key (package_id, service_id),
  constraint package_services_quantity_positive check (quantity > 0)
);

create index package_services_service_idx on package_services (service_id);

-- -----------------------------------------------------------------------------
-- Loyalty
-- -----------------------------------------------------------------------------

-- Mirrors `LoyaltyProfile`. The tier is derived from xp, never stored, so the
-- thresholds in `LoyaltyTier` stay the single definition.
create table loyalty_profiles (
  id                    uuid        primary key default gen_random_uuid(),
  user_id               uuid        not null unique references profiles (id) on delete cascade,
  xp                    integer     not null default 0,
  spendable_points      integer     not null default 0,
  referral_code         text        not null,
  referred_by_code      text,
  current_streak_days   integer     not null default 0,
  last_daily_reward_at  timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint loyalty_profiles_xp_non_negative check (xp >= 0),
  constraint loyalty_profiles_points_non_negative check (spendable_points >= 0),
  constraint loyalty_profiles_streak_non_negative check (current_streak_days >= 0),
  constraint loyalty_profiles_no_self_referral check (referred_by_code is null or referred_by_code <> referral_code)
);

create unique index loyalty_profiles_referral_code_key on loyalty_profiles (upper(referral_code));

-- Mirrors `Achievement` — the platform-wide catalogue.
create table achievements (
  id             uuid        primary key default gen_random_uuid(),
  title          text        not null,
  details        text        not null default '',
  symbol_name    text        not null default 'star.fill',
  xp_reward      integer     not null default 0,
  points_reward  integer     not null default 0,
  is_active      boolean     not null default true,
  created_at     timestamptz not null default now(),
  constraint achievements_xp_non_negative check (xp_reward >= 0),
  constraint achievements_points_non_negative check (points_reward >= 0)
);

-- Mirrors `LoyaltyProfile.achievements` — which user unlocked what, and when.
create table loyalty_achievements (
  loyalty_profile_id uuid        not null references loyalty_profiles (id) on delete cascade,
  achievement_id     uuid        not null references achievements (id) on delete cascade,
  unlocked_at        timestamptz not null default now(),
  primary key (loyalty_profile_id, achievement_id)
);

create index loyalty_achievements_achievement_idx on loyalty_achievements (achievement_id);

-- Mirrors `LoyaltyChallenge`. `user_id` null = a challenge offered to everyone.
create table loyalty_challenges (
  id             uuid        primary key default gen_random_uuid(),
  user_id        uuid        references profiles (id) on delete cascade,
  title          text        not null,
  details        text        not null default '',
  symbol_name    text        not null default 'flame.fill',
  target_count   integer     not null,
  progress_count integer     not null default 0,
  points_reward  integer     not null default 0,
  ends_at        timestamptz not null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint loyalty_challenges_target_positive check (target_count > 0),
  constraint loyalty_challenges_progress_non_negative check (progress_count >= 0),
  constraint loyalty_challenges_points_non_negative check (points_reward >= 0)
);

create index loyalty_challenges_user_idx on loyalty_challenges (user_id, ends_at desc);

-- -----------------------------------------------------------------------------
-- Reviews
-- -----------------------------------------------------------------------------

-- Mirrors `Review`. `verified_appointment_id` being non-null is exactly
-- `Review.isVerified`; the salon aggregate is maintained by trigger in 0003.
create table reviews (
  id                       uuid                     primary key default gen_random_uuid(),
  salon_id                 uuid                     not null references salons (id) on delete cascade,
  professional_id          uuid                     references professionals (id) on delete set null,
  author_id                uuid                     not null references profiles (id) on delete cascade,
  author_name              text                     not null,
  author_avatar_url        text,
  rating                   integer                  not null,
  text                     text                     not null default '',
  photo_urls               text[]                   not null default '{}',
  video_urls               text[]                   not null default '{}',
  verified_appointment_id  uuid                     references appointments (id) on delete set null,
  like_count               integer                  not null default 0,
  owner_response           text,
  owner_responded_at       timestamptz,
  moderation               review_moderation_status not null default 'pending',
  created_at               timestamptz              not null default now(),
  updated_at               timestamptz              not null default now(),
  constraint reviews_rating_range check (rating between 1 and 5),
  constraint reviews_like_count_non_negative check (like_count >= 0),
  constraint reviews_owner_response_timestamped
    check (owner_response is null or owner_responded_at is not null)
);

-- One review per client per visit; unverified reviews are one per salon.
create unique index reviews_appointment_key on reviews (verified_appointment_id, author_id)
  where verified_appointment_id is not null;
-- The salon profile lists approved reviews newest-first — the hottest read.
create index reviews_salon_idx on reviews (salon_id, created_at desc) where moderation = 'approved';
create index reviews_professional_idx on reviews (professional_id, created_at desc)
  where moderation = 'approved' and professional_id is not null;
create index reviews_moderation_queue_idx on reviews (moderation, created_at)
  where moderation in ('pending', 'flagged');

-- Mirrors `Review.likedByMe` — stored per user so "did I like this" is a fact,
-- not a guess.
create table review_likes (
  review_id uuid        not null references reviews (id) on delete cascade,
  user_id   uuid        not null references profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (review_id, user_id)
);

-- Mirrors `ReviewComment`.
create table review_comments (
  id          uuid        primary key default gen_random_uuid(),
  review_id   uuid        not null references reviews (id) on delete cascade,
  author_id   uuid        not null references profiles (id) on delete cascade,
  author_name text        not null,
  text        text        not null,
  created_at  timestamptz not null default now(),
  constraint review_comments_text_not_blank check (length(btrim(text)) > 0)
);

create index review_comments_review_idx on review_comments (review_id, created_at);

-- -----------------------------------------------------------------------------
-- Chat
-- -----------------------------------------------------------------------------

-- Mirrors `Conversation`.
create table conversations (
  id                  uuid              primary key default gen_random_uuid(),
  kind                conversation_kind not null,
  title               text              not null,
  avatar_url          text,
  salon_id            uuid              references salons (id) on delete cascade,
  last_message_preview text,
  last_message_at     timestamptz,
  is_encrypted        boolean           not null default true,
  created_at          timestamptz       not null default now(),
  updated_at          timestamptz       not null default now()
);

create index conversations_salon_idx on conversations (salon_id, last_message_at desc);

-- Mirrors `Conversation.participantIDs`, plus the read cursor that produces
-- `unreadCount` without a second round trip.
create table conversation_participants (
  conversation_id uuid        not null references conversations (id) on delete cascade,
  user_id         uuid        not null references profiles (id) on delete cascade,
  last_read_at    timestamptz not null default 'epoch',
  is_muted        boolean     not null default false,
  joined_at       timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create index conversation_participants_user_idx on conversation_participants (user_id);

-- Mirrors `ChatMessage`. `ChatMessage.Content` is an enum with associated
-- values: `content_kind` is the discriminator and the payload columns carry the
-- associated values, so a message is queryable rather than an opaque blob.
create table messages (
  id                  uuid                  primary key default gen_random_uuid(),
  conversation_id     uuid                  not null references conversations (id) on delete cascade,
  sender_id           uuid                  references profiles (id) on delete set null,
  is_from_assistant   boolean               not null default false,
  content_kind        message_content_kind  not null default 'text',
  body                text,
  media_url           text,
  caption             text,
  duration_seconds    integer,
  service_id          uuid                  references services (id) on delete set null,
  preferred_date      timestamptz,
  recommendation      jsonb,
  delivery_state      message_delivery_state not null default 'sent',
  sent_at             timestamptz           not null default now(),
  constraint messages_author check (sender_id is not null or is_from_assistant),
  constraint messages_text_has_body check (content_kind <> 'text' or length(coalesce(body, '')) > 0),
  constraint messages_media_has_url
    check (content_kind not in ('photo', 'video', 'voice') or media_url is not null),
  constraint messages_voice_has_duration
    check (content_kind <> 'voice' or (duration_seconds is not null and duration_seconds > 0)),
  constraint messages_request_has_service
    check (content_kind <> 'appointment_request' or (service_id is not null and preferred_date is not null)),
  constraint messages_recommendation_has_payload
    check (content_kind <> 'recommendation' or recommendation is not null)
);

-- The conversation view pages backwards from the newest message.
create index messages_conversation_sent_idx on messages (conversation_id, sent_at desc);
create index messages_sender_idx on messages (sender_id);

-- -----------------------------------------------------------------------------
-- Notifications & devices
-- -----------------------------------------------------------------------------

-- Mirrors `PRVNotification`. `route` holds the encoded `AppRoute` so a tap
-- deep-links without the client re-deriving the destination.
create table notifications (
  id         uuid              primary key default gen_random_uuid(),
  user_id    uuid              not null references profiles (id) on delete cascade,
  kind       notification_kind not null,
  title      text              not null,
  body       text              not null default '',
  route      jsonb,
  is_read    boolean           not null default false,
  read_at    timestamptz,
  created_at timestamptz       not null default now()
);

create index notifications_user_idx on notifications (user_id, created_at desc);
create index notifications_unread_idx on notifications (user_id) where not is_read;

-- APNs / FCM registration. One row per (user, token); a token that moves to a
-- different account replaces the old row.
create table device_tokens (
  id           uuid            primary key default gen_random_uuid(),
  user_id      uuid            not null references profiles (id) on delete cascade,
  token        text            not null,
  platform     device_platform not null default 'ios',
  bundle_id    text,
  locale       text            not null default 'en',
  is_sandbox   boolean         not null default false,
  last_seen_at timestamptz     not null default now(),
  created_at   timestamptz     not null default now(),
  constraint device_tokens_token_not_blank check (length(btrim(token)) > 0)
);

create unique index device_tokens_token_key on device_tokens (token);
create index device_tokens_user_idx on device_tokens (user_id);

-- -----------------------------------------------------------------------------
-- CRM
-- -----------------------------------------------------------------------------

-- Mirrors `ClientRecord` — the salon's own record of a client, which exists
-- whether or not that client has an app account.
create table client_records (
  id            uuid          primary key default gen_random_uuid(),
  salon_id      uuid          not null references salons (id) on delete cascade,
  user_id       uuid          references profiles (id) on delete set null,
  first_name    text          not null,
  last_name     text          not null default '',
  email         text,
  phone         text,
  avatar_url    text,
  birthday      date,
  skin_type     text,
  hair_type     text,
  allergies     text[]        not null default '{}',
  preferences   text[]        not null default '{}',
  total_visits  integer       not null default 0,
  total_spend_amount   money_amount  not null default 0,
  total_spend_currency currency_code not null default 'EUR',
  last_visit_at timestamptz,
  created_at    timestamptz   not null default now(),
  updated_at    timestamptz   not null default now(),
  constraint client_records_visits_non_negative check (total_visits >= 0),
  constraint client_records_spend_non_negative check (total_spend_amount >= 0)
);

create unique index client_records_salon_user_key on client_records (salon_id, user_id)
  where user_id is not null;
create index client_records_salon_name_idx on client_records (salon_id, lower(last_name), lower(first_name));
create index client_records_salon_last_visit_idx on client_records (salon_id, last_visit_at desc);

-- Mirrors `ClientRecord.favoriteProductIDs`.
create table client_favorite_products (
  client_record_id uuid not null references client_records (id) on delete cascade,
  product_id       uuid not null,
  primary key (client_record_id, product_id)
);

-- Mirrors `ClientNote` — colour formulas, treatment notes, consultation photos.
create table client_notes (
  id               uuid            primary key default gen_random_uuid(),
  client_record_id uuid            not null references client_records (id) on delete cascade,
  author_id        uuid            not null references profiles (id) on delete restrict,
  kind             client_note_kind not null default 'general',
  text             text            not null default '',
  photo_urls       text[]          not null default '{}',
  appointment_id   uuid            references appointments (id) on delete set null,
  created_at       timestamptz     not null default now(),
  constraint client_notes_has_content
    check (length(btrim(text)) > 0 or cardinality(photo_urls) > 0)
);

create index client_notes_record_idx on client_notes (client_record_id, created_at desc);

-- Mirrors `ConsentForm` — versioned so a salon can prove which text was signed.
create table consent_forms (
  id               uuid        primary key default gen_random_uuid(),
  client_record_id uuid        not null references client_records (id) on delete cascade,
  title            text        not null,
  version          text        not null,
  document_url     text,
  signature_url    text,
  signed_at        timestamptz,
  created_at       timestamptz not null default now()
);

create unique index consent_forms_version_key on consent_forms (client_record_id, title, version);
create index consent_forms_record_idx on consent_forms (client_record_id, signed_at desc nulls last);

-- -----------------------------------------------------------------------------
-- Team
-- -----------------------------------------------------------------------------

-- Mirrors `Employee`.
create table employees (
  id                    uuid               primary key default gen_random_uuid(),
  salon_id              uuid               not null references salons (id) on delete cascade,
  professional_id       uuid               not null references professionals (id) on delete cascade,
  user_id               uuid               references profiles (id) on delete set null,
  role                  user_role          not null default 'salon_employee',
  compensation          compensation_model not null default 'hybrid',
  monthly_salary_amount money_amount,
  hourly_rate_amount    money_amount,
  currency              currency_code      not null default 'EUR',
  commission_percent    percent_0_100      not null default 0,
  vacation_days_per_year integer           not null default 20,
  vacation_days_used     integer           not null default 0,
  hired_at              timestamptz        not null default now(),
  terminated_at         timestamptz,
  created_at            timestamptz        not null default now(),
  updated_at            timestamptz        not null default now(),
  constraint employees_salary_non_negative check (monthly_salary_amount is null or monthly_salary_amount >= 0),
  constraint employees_hourly_non_negative check (hourly_rate_amount is null or hourly_rate_amount >= 0),
  constraint employees_vacation_non_negative check (vacation_days_per_year >= 0 and vacation_days_used >= 0),
  constraint employees_vacation_not_overdrawn check (vacation_days_used <= vacation_days_per_year),
  constraint employees_termination_after_hire check (terminated_at is null or terminated_at >= hired_at)
);

create unique index employees_salon_professional_key on employees (salon_id, professional_id);
create index employees_user_idx on employees (user_id) where user_id is not null;
create index employees_salon_idx on employees (salon_id) where terminated_at is null;

-- Mirrors `Shift`.
create table shifts (
  id          uuid        primary key default gen_random_uuid(),
  salon_id    uuid        not null references salons (id) on delete cascade,
  employee_id uuid        not null references employees (id) on delete cascade,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint shifts_span_ordered check (ends_at > starts_at)
);

create index shifts_salon_week_idx on shifts (salon_id, starts_at);
create index shifts_employee_idx on shifts (employee_id, starts_at);

-- Mirrors `TimeEntry` — clock in/out with optional geofence validation.
create table time_entries (
  id                     uuid             primary key default gen_random_uuid(),
  employee_id            uuid             not null references employees (id) on delete cascade,
  clock_in               timestamptz      not null default now(),
  clock_out              timestamptz,
  clock_in_latitude      double precision,
  clock_in_longitude     double precision,
  clock_out_latitude     double precision,
  clock_out_longitude    double precision,
  gps_validated          boolean          not null default false,
  created_at             timestamptz      not null default now(),
  constraint time_entries_span_ordered check (clock_out is null or clock_out > clock_in),
  constraint time_entries_clock_in_coordinate_pair
    check ((clock_in_latitude is null) = (clock_in_longitude is null)),
  constraint time_entries_clock_out_coordinate_pair
    check ((clock_out_latitude is null) = (clock_out_longitude is null))
);

-- At most one shift in progress per employee.
create unique index time_entries_open_key on time_entries (employee_id) where clock_out is null;
create index time_entries_employee_idx on time_entries (employee_id, clock_in desc);

-- Mirrors `PerformanceGoal`.
create table performance_goals (
  id           uuid               primary key default gen_random_uuid(),
  employee_id  uuid               not null references employees (id) on delete cascade,
  metric       performance_metric not null,
  target       numeric(12, 2)     not null,
  progress     numeric(12, 2)     not null default 0,
  period_start timestamptz        not null,
  period_end   timestamptz        not null,
  created_at   timestamptz        not null default now(),
  updated_at   timestamptz        not null default now(),
  constraint performance_goals_target_positive check (target > 0),
  constraint performance_goals_progress_non_negative check (progress >= 0),
  constraint performance_goals_period_ordered check (period_end > period_start)
);

create unique index performance_goals_period_key on performance_goals (employee_id, metric, period_start);
create index performance_goals_employee_idx on performance_goals (employee_id, period_start desc);

-- -----------------------------------------------------------------------------
-- Inventory
-- -----------------------------------------------------------------------------

-- Mirrors `Supplier`.
create table suppliers (
  id         uuid        primary key default gen_random_uuid(),
  salon_id   uuid        references salons (id) on delete cascade,
  name       text        not null,
  email      text,
  phone      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index suppliers_salon_idx on suppliers (salon_id);

-- Mirrors `Product`.
create table products (
  id                  uuid          primary key default gen_random_uuid(),
  salon_id            uuid          not null references salons (id) on delete cascade,
  supplier_id         uuid          references suppliers (id) on delete set null,
  name                text          not null,
  brand               text          not null default '',
  details             text          not null default '',
  barcode             text,
  retail_price_amount money_amount  not null,
  cost_price_amount   money_amount  not null default 0,
  currency            currency_code not null default 'EUR',
  stock_quantity      integer       not null default 0,
  low_stock_threshold integer       not null default 5,
  expires_at          timestamptz,
  image_url           text,
  is_retail           boolean       not null default true,
  is_active           boolean       not null default true,
  created_at          timestamptz   not null default now(),
  updated_at          timestamptz   not null default now(),
  constraint products_retail_price_non_negative check (retail_price_amount >= 0),
  constraint products_cost_price_non_negative check (cost_price_amount >= 0),
  constraint products_stock_non_negative check (stock_quantity >= 0),
  constraint products_threshold_non_negative check (low_stock_threshold >= 0)
);

-- Barcode scanning resolves within one salon, so the uniqueness is scoped.
create unique index products_barcode_key on products (salon_id, barcode) where barcode is not null;
create index products_salon_idx on products (salon_id) where is_active;
create index products_low_stock_idx on products (salon_id)
  where is_active and stock_quantity <= low_stock_threshold;

alter table client_favorite_products
  add constraint client_favorite_products_product_fk
  foreign key (product_id) references products (id) on delete cascade;

-- Mirrors `PurchaseOrder`.
create table purchase_orders (
  id          uuid                  primary key default gen_random_uuid(),
  salon_id    uuid                  not null references salons (id) on delete cascade,
  supplier_id uuid                  not null references suppliers (id) on delete restrict,
  status      purchase_order_status not null default 'draft',
  currency    currency_code         not null default 'EUR',
  expected_at timestamptz,
  received_at timestamptz,
  created_by  uuid                  references profiles (id) on delete set null,
  created_at  timestamptz           not null default now(),
  updated_at  timestamptz           not null default now(),
  constraint purchase_orders_received_consistency
    check (status <> 'received' or received_at is not null)
);

create index purchase_orders_salon_idx on purchase_orders (salon_id, created_at desc);
create index purchase_orders_supplier_idx on purchase_orders (supplier_id);

-- Mirrors `PurchaseOrder.Line`.
create table purchase_order_lines (
  id                uuid          primary key default gen_random_uuid(),
  purchase_order_id uuid          not null references purchase_orders (id) on delete cascade,
  product_id        uuid          not null references products (id) on delete restrict,
  product_name      text          not null,
  quantity          integer       not null,
  unit_cost_amount  money_amount  not null,
  currency          currency_code not null default 'EUR',
  position          integer       not null default 0,
  constraint purchase_order_lines_quantity_positive check (quantity > 0),
  constraint purchase_order_lines_cost_non_negative check (unit_cost_amount >= 0)
);

create index purchase_order_lines_order_idx on purchase_order_lines (purchase_order_id, position);
create index purchase_order_lines_product_idx on purchase_order_lines (product_id);

-- -----------------------------------------------------------------------------
-- Marketing
-- -----------------------------------------------------------------------------

-- Mirrors `Coupon`. `Coupon.Discount` is an enum with associated values:
-- `discount_kind` discriminates, and exactly one of the value columns is set.
create table coupons (
  id                    uuid                 primary key default gen_random_uuid(),
  salon_id              uuid                 not null references salons (id) on delete cascade,
  code                  text                 not null,
  discount_kind         coupon_discount_kind not null,
  discount_percent      percent_0_100,
  discount_amount       money_amount,
  currency              currency_code        not null default 'EUR',
  max_redemptions       integer,
  redemption_count      integer              not null default 0,
  minimum_spend_amount  money_amount,
  valid_from            timestamptz          not null default now(),
  valid_until           timestamptz,
  is_active             boolean              not null default true,
  created_at            timestamptz          not null default now(),
  updated_at            timestamptz          not null default now(),
  constraint coupons_percent_payload
    check (discount_kind <> 'percent' or (discount_percent is not null and discount_amount is null)),
  constraint coupons_fixed_payload
    check (discount_kind <> 'fixed' or (discount_amount is not null and discount_amount > 0 and discount_percent is null)),
  constraint coupons_max_redemptions_positive check (max_redemptions is null or max_redemptions > 0),
  constraint coupons_redemption_count_non_negative check (redemption_count >= 0),
  constraint coupons_not_over_redeemed
    check (max_redemptions is null or redemption_count <= max_redemptions),
  constraint coupons_minimum_spend_non_negative check (minimum_spend_amount is null or minimum_spend_amount >= 0),
  constraint coupons_window_ordered check (valid_until is null or valid_until > valid_from)
);

create unique index coupons_salon_code_key on coupons (salon_id, upper(code));
create index coupons_salon_idx on coupons (salon_id) where is_active;

-- Mirrors `Campaign`.
create table campaigns (
  id                        uuid               primary key default gen_random_uuid(),
  salon_id                  uuid               not null references salons (id) on delete cascade,
  name                      text               not null,
  kind                      campaign_kind      not null,
  channels                  campaign_channel[] not null default '{push}',
  message                   text               not null,
  coupon_id                 uuid               references coupons (id) on delete set null,
  status                    campaign_status    not null default 'draft',
  scheduled_at              timestamptz,
  sent_count                integer            not null default 0,
  open_count                integer            not null default 0,
  booking_count             integer            not null default 0,
  attributed_revenue_amount money_amount       not null default 0,
  currency                  currency_code      not null default 'EUR',
  created_by                uuid               references profiles (id) on delete set null,
  created_at                timestamptz        not null default now(),
  updated_at                timestamptz        not null default now(),
  constraint campaigns_channels_not_empty check (cardinality(channels) > 0),
  constraint campaigns_counts_non_negative
    check (sent_count >= 0 and open_count >= 0 and booking_count >= 0),
  -- You cannot open more messages than were sent.
  constraint campaigns_opens_within_sends check (open_count <= sent_count),
  constraint campaigns_revenue_non_negative check (attributed_revenue_amount >= 0),
  constraint campaigns_scheduled_has_date check (status <> 'scheduled' or scheduled_at is not null)
);

create index campaigns_salon_idx on campaigns (salon_id, created_at desc);
create index campaigns_due_idx on campaigns (scheduled_at) where status = 'scheduled';

-- One row per redemption — the audit trail behind `coupons.redemption_count`.
create table coupon_redemptions (
  id         uuid        primary key default gen_random_uuid(),
  coupon_id  uuid        not null references coupons (id) on delete cascade,
  user_id    uuid        not null references profiles (id) on delete cascade,
  order_id   uuid        references orders (id) on delete set null,
  amount     money_amount not null default 0,
  currency   currency_code not null default 'EUR',
  created_at timestamptz not null default now(),
  constraint coupon_redemptions_amount_non_negative check (amount >= 0)
);

create unique index coupon_redemptions_order_key on coupon_redemptions (coupon_id, order_id)
  where order_id is not null;
create index coupon_redemptions_coupon_idx on coupon_redemptions (coupon_id, created_at desc);
create index coupon_redemptions_user_idx on coupon_redemptions (user_id);

-- -----------------------------------------------------------------------------
-- Platform
-- -----------------------------------------------------------------------------

-- Mirrors `AuditLogEntry`. Append-only by policy (0002) — every privileged
-- mutation lands here and nothing may edit or erase it.
create table audit_log (
  id         uuid                primary key default gen_random_uuid(),
  actor_id   uuid                references profiles (id) on delete set null,
  salon_id   uuid                references salons (id) on delete set null,
  action     text                not null,
  operation  sync_operation_kind,
  entity     text                not null,
  entity_id  uuid,
  detail     text,
  metadata   jsonb               not null default '{}'::jsonb,
  created_at timestamptz         not null default now(),
  constraint audit_log_action_not_blank check (length(btrim(action)) > 0),
  constraint audit_log_entity_not_blank check (length(btrim(entity)) > 0)
);

create index audit_log_actor_idx on audit_log (actor_id, created_at desc);
create index audit_log_entity_idx on audit_log (entity, entity_id, created_at desc);
create index audit_log_salon_idx on audit_log (salon_id, created_at desc);

-- Mirrors `PRVFoundation.FeatureFlag`. Rows override the client's compiled-in
-- defaults; `salon_id` null = platform-wide.
create table feature_flags (
  id           uuid        primary key default gen_random_uuid(),
  key          text        not null,
  salon_id     uuid        references salons (id) on delete cascade,
  is_enabled   boolean     not null default false,
  rollout_percent percent_0_100 not null default 100,
  description  text,
  updated_at   timestamptz not null default now(),
  constraint feature_flags_key_not_blank check (length(btrim(key)) > 0)
);

create unique index feature_flags_key_global_key on feature_flags (key) where salon_id is null;
create unique index feature_flags_key_salon_key on feature_flags (key, salon_id) where salon_id is not null;
