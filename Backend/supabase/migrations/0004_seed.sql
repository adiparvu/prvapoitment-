-- =============================================================================
-- PRV Beauty — 0004_seed.sql
--
-- Two things live here:
--
--   1. `role_permissions` — NOT demo data. This is the server-side mirror of
--      `UserRole.permissions` in Sources/PRVModels/User.swift and the authority
--      behind every `has_permission(...)` call in the RLS policies. Keep it in
--      lockstep with the Swift enum; `Tests/PRVModelsTests` asserts the role
--      supersets that this table encodes.
--
--   2. The demo fixture set, mirroring `PRVModels.PreviewData` — same UUIDs, so
--      the app pointed at a local stack shows the same salons, services, and
--      appointment as it does in demo mode. Applied by `supabase db reset`.
--      Never run against production.
--
-- Note on aggregates: `salons.rating` / `review_count` and
-- `coupons.redemption_count` are trigger-derived (0003), so they reflect the
-- reviews and redemptions actually seeded here rather than the marketing
-- figures baked into the Swift fixtures.
-- =============================================================================

set search_path = public, extensions;

-- -----------------------------------------------------------------------------
-- 1. Role → permission matrix (mirrors UserRole.permissions)
-- -----------------------------------------------------------------------------

insert into role_permissions (role, permission)
select 'guest'::user_role, p from unnest(array[
  'browse'
]::permission[]) as p
union all
select 'client', p from unnest(array[
  'browse', 'book', 'review', 'chat', 'payOnline'
]::permission[]) as p
union all
-- premiumClient = client ∪ { priorityBooking }
select 'premium_client', p from unnest(array[
  'browse', 'book', 'review', 'chat', 'payOnline', 'priorityBooking'
]::permission[]) as p
union all
select 'freelancer', p from unnest(array[
  'browse', 'chat', 'manageOwnCalendar', 'manageOwnServices', 'viewOwnEarnings'
]::permission[]) as p
union all
select 'salon_employee', p from unnest(array[
  'browse', 'chat', 'manageOwnCalendar', 'viewClients', 'checkInOut'
]::permission[]) as p
union all
-- salonManager = salonEmployee ∪ { … }
select 'salon_manager', p from unnest(array[
  'browse', 'chat', 'manageOwnCalendar', 'viewClients', 'checkInOut',
  'manageCalendar', 'manageTeam', 'manageInventory', 'viewReports',
  'manageServices', 'respondToReviews', 'manageCRM'
]::permission[]) as p
union all
-- salonOwner = salonManager ∪ { … }
select 'salon_owner', p from unnest(array[
  'browse', 'chat', 'manageOwnCalendar', 'viewClients', 'checkInOut',
  'manageCalendar', 'manageTeam', 'manageInventory', 'viewReports',
  'manageServices', 'respondToReviews', 'manageCRM',
  'manageSalon', 'managePayroll', 'manageMarketing', 'manageMemberships',
  'manageFinance', 'configurePrepayment'
]::permission[]) as p
union all
-- multiSalonOwner / regionalManager = salonOwner ∪ { multi-location }
select r, p
from unnest(array['multi_salon_owner', 'regional_manager']::user_role[]) as r
cross join unnest(array[
  'browse', 'chat', 'manageOwnCalendar', 'viewClients', 'checkInOut',
  'manageCalendar', 'manageTeam', 'manageInventory', 'viewReports',
  'manageServices', 'respondToReviews', 'manageCRM',
  'manageSalon', 'managePayroll', 'manageMarketing', 'manageMemberships',
  'manageFinance', 'configurePrepayment',
  'manageMultipleLocations', 'compareLocations'
]::permission[]) as p
union all
select 'support', p from unnest(array[
  'browse', 'viewClients', 'manageRefunds', 'chat', 'moderateReviews'
]::permission[]) as p
union all
select 'finance', p from unnest(array[
  'viewReports', 'manageFinance', 'manageRefunds', 'managePayroll'
]::permission[]) as p
union all
select 'marketing', p from unnest(array[
  'viewReports', 'manageMarketing'
]::permission[]) as p
union all
-- administrator = everything except developerTools
select 'administrator', p from unnest(enum_range(null::permission)) as p
where p <> 'developerTools'
union all
-- superAdmin / developer = everything
select r, p
from unnest(array['super_admin', 'developer']::user_role[]) as r
cross join unnest(enum_range(null::permission)) as p
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 2. Demo accounts
--
-- Password for every demo account: `prv-demo-password`.
-- `handle_new_auth_user` (0003) creates the profile + loyalty profile; the
-- upserts below pin the exact fixture values.
-- -----------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
)
values
  (
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000001',
    'authenticated', 'authenticated', 'sofia@example.com',
    crypt('prv-demo-password', gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"first_name":"Sofia","last_name":"Laurent","role":"premium_client"}'::jsonb
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000002',
    'authenticated', 'authenticated', 'emma@maisonlumiere.be',
    crypt('prv-demo-password', gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"first_name":"Emma","last_name":"Verhoeven","role":"salon_owner"}'::jsonb
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000009',
    'authenticated', 'authenticated', 'marie@example.com',
    crypt('prv-demo-password', gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"first_name":"Marie","last_name":"Vermeulen","role":"client"}'::jsonb
  )
on conflict (id) do nothing;

-- GoTrue requires a matching identity row for email sign-in.
insert into auth.identities (
  provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
)
select
  u.id::text,
  u.id,
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
  'email',
  now(), now(), now()
from auth.users u
where u.id in (
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000009'
)
on conflict do nothing;

insert into profiles (id, role, first_name, last_name, email, phone, preferred_language)
values
  ('00000000-0000-0000-0000-000000000001', 'premium_client', 'Sofia', 'Laurent',
   'sofia@example.com', '+32 470 12 34 56', 'en'),
  ('00000000-0000-0000-0000-000000000002', 'salon_owner', 'Emma', 'Verhoeven',
   'emma@maisonlumiere.be', '+32 3 123 45 67', 'nl'),
  ('00000000-0000-0000-0000-000000000009', 'client', 'Marie', 'Vermeulen',
   'marie@example.com', null, 'nl')
on conflict (id) do update
  set role = excluded.role,
      first_name = excluded.first_name,
      last_name = excluded.last_name,
      email = excluded.email,
      phone = excluded.phone,
      preferred_language = excluded.preferred_language;

-- -----------------------------------------------------------------------------
-- 3. Organization & salons
-- -----------------------------------------------------------------------------

insert into organizations (id, name, owner_id)
values (
  '00000000-0000-0000-0008-000000000001',
  'Maison Lumière Group',
  '00000000-0000-0000-0000-000000000002'
)
on conflict (id) do nothing;

insert into salons (
  id, organization_id, name, tagline, about, categories, amenities, languages,
  street, city, postal_code, country, latitude, longitude, phone,
  currency, is_verified,
  policy_free_cancellation_hours, policy_late_cancellation_percent,
  policy_no_show_percent, policy_late_grace_minutes
)
values
  (
    '00000000-0000-0000-0001-000000000001',
    '00000000-0000-0000-0008-000000000001',
    'Maison Lumière',
    'Luxury hair & beauty atelier',
    'An award-winning atelier in the heart of Antwerp blending Parisian technique with Belgian precision. Every visit begins with a personal consultation and ends with a look made to last.',
    '{hair_salon,makeup_studio}',
    '{luxury,parking,wheelchair_access,refreshments,wifi}',
    '{en,nl,fr}',
    'Schuttershofstraat 24', 'Antwerp', '2000', 'BE', 51.2178, 4.4041,
    '+32 3 123 45 67', 'EUR', true,
    24, 50, 100, 10
  ),
  (
    '00000000-0000-0000-0001-000000000002',
    null,
    'Velvet Nails Studio',
    'Nail artistry, elevated',
    'A boutique nail studio known for intricate nail art and flawless gel work.',
    '{nail_studio,lash_studio}',
    '{premium,pet_friendly,wifi}',
    '{en,fr}',
    'Rue du Bailli 58', 'Brussels', '1050', 'BE', 50.8265, 4.3595,
    null, 'EUR', true,
    24, 50, 100, 10
  )
on conflict (id) do nothing;

-- Maison Lumière: Monday–Saturday 09:00–19:00 (weekday 1 = Sunday, closed).
insert into salon_opening_hours (salon_id, weekday, open_minutes, close_minutes)
select '00000000-0000-0000-0001-000000000001'::uuid, weekday, 540, 1140
from generate_series(2, 7) as weekday
union all
-- Velvet: Tuesday–Saturday 10:00–18:30.
select '00000000-0000-0000-0001-000000000002'::uuid, weekday, 600, 1110
from generate_series(3, 7) as weekday
on conflict do nothing;

insert into prepayment_policies (
  salon_id, offered_percents, full_prepayment_discount_percent,
  reward_points_multiplier, cashback_percent, grants_priority_booking
)
values
  ('00000000-0000-0000-0001-000000000001', '{20,50,100}', 10, 2, 2, true),
  ('00000000-0000-0000-0001-000000000002', '{50,100}', 5, 2, 1, false)
on conflict (salon_id) do nothing;

-- -----------------------------------------------------------------------------
-- 4. Professionals
-- -----------------------------------------------------------------------------

insert into professionals (
  id, user_id, salon_id, display_name, title, biography, years_of_experience,
  specialties, languages, rating, review_count, average_response_minutes, is_freelancer
)
values
  (
    '00000000-0000-0000-0002-000000000001', null,
    '00000000-0000-0000-0001-000000000001',
    'Amélie Dubois', 'Senior Colorist',
    'Balayage specialist trained in Paris with 12 years behind the chair.',
    12, '{Balayage,"Color Correction",Bridal}', '{en,fr}', 0, 0, 18, false
  ),
  (
    '00000000-0000-0000-0002-000000000002', null,
    '00000000-0000-0000-0001-000000000002',
    'Noor El Amrani', 'Nail Artist',
    'Editorial nail artist featured in Vogue Belgium.',
    7, '{"Nail Art","Gel Extensions"}', '{en,fr,ar}', 0, 0, 25, false
  ),
  (
    '00000000-0000-0000-0002-000000000003',
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0001-000000000001',
    'Emma Verhoeven', 'Founder & Creative Director',
    'Opened Maison Lumière in 2014 after a decade in Parisian ateliers.',
    18, '{Consultation,Bridal}', '{en,nl,fr}', 0, 0, 12, false
  )
on conflict (id) do nothing;

insert into certificates (professional_id, title, issuer, issued_at)
values
  ('00000000-0000-0000-0002-000000000001', 'L''Oréal Professionnel Colour Specialist',
   'L''Oréal Professionnel', timestamptz '2019-06-01T00:00:00Z'),
  ('00000000-0000-0000-0002-000000000001', 'Olaplex Certified Stylist',
   'Olaplex', timestamptz '2021-03-15T00:00:00Z'),
  ('00000000-0000-0000-0002-000000000002', 'Gel Extension Masterclass',
   'The Nail Institute', timestamptz '2022-09-10T00:00:00Z')
on conflict do nothing;

insert into portfolio_items (professional_id, kind, media_url, before_url, caption)
values
  ('00000000-0000-0000-0002-000000000001', 'before_after',
   'https://cdn.prvbeauty.com/demo/amelie-balayage-after.jpg',
   'https://cdn.prvbeauty.com/demo/amelie-balayage-before.jpg',
   'Cool-toned balayage, four hours, single session'),
  ('00000000-0000-0000-0002-000000000001', 'photo',
   'https://cdn.prvbeauty.com/demo/amelie-bridal.jpg', null,
   'Bridal upstyle with hand-set waves'),
  ('00000000-0000-0000-0002-000000000002', 'photo',
   'https://cdn.prvbeauty.com/demo/noor-chrome.jpg', null,
   'Chrome French with hand-painted detail')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 5. Services & add-ons
-- -----------------------------------------------------------------------------

insert into services (
  id, salon_id, name, details, category, price_amount, price_currency,
  is_starting_price, duration_minutes, preparation_minutes, cleanup_minutes,
  requires_prepayment
)
values
  (
    '00000000-0000-0000-0003-000000000001',
    '00000000-0000-0000-0001-000000000001',
    'Balayage & Gloss',
    'Hand-painted dimension with a customized gloss finish. Includes consultation, treatment, and styling.',
    'hair_salon', 185.00, 'EUR', true, 150, 10, 15, true
  ),
  (
    '00000000-0000-0000-0003-000000000002',
    '00000000-0000-0000-0001-000000000001',
    'Cut & Blow-Dry',
    'Precision cut with consultation and signature blow-dry.',
    'hair_salon', 75.00, 'EUR', false, 60, 0, 10, false
  ),
  (
    '00000000-0000-0000-0003-000000000003',
    '00000000-0000-0000-0001-000000000002',
    'Gel Manicure',
    'Long-lasting gel color with cuticle care and hand massage.',
    'nail_studio', 55.00, 'EUR', false, 75, 0, 10, false
  )
on conflict (id) do nothing;

insert into service_add_ons (id, service_id, name, price_amount, extra_minutes)
values
  ('00000000-0000-0000-0007-000000000001', '00000000-0000-0000-0003-000000000001',
   'Olaplex Treatment', 35.00, 15),
  ('00000000-0000-0000-0007-000000000002', '00000000-0000-0000-0003-000000000001',
   'Luxury Scalp Massage', 25.00, 15)
on conflict (id) do nothing;

insert into professional_services (professional_id, service_id)
values
  ('00000000-0000-0000-0002-000000000001', '00000000-0000-0000-0003-000000000001'),
  ('00000000-0000-0000-0002-000000000001', '00000000-0000-0000-0003-000000000002'),
  ('00000000-0000-0000-0002-000000000003', '00000000-0000-0000-0003-000000000002'),
  ('00000000-0000-0000-0002-000000000002', '00000000-0000-0000-0003-000000000003')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 6. Team
-- -----------------------------------------------------------------------------

insert into employees (
  id, salon_id, professional_id, user_id, role, compensation,
  monthly_salary_amount, commission_percent, hired_at
)
values
  (
    '00000000-0000-0000-0009-000000000001',
    '00000000-0000-0000-0001-000000000001',
    '00000000-0000-0000-0002-000000000003',
    '00000000-0000-0000-0000-000000000002',
    'salon_owner', 'salary', 4200.00, 0, timestamptz '2014-04-01T00:00:00Z'
  ),
  (
    '00000000-0000-0000-0009-000000000002',
    '00000000-0000-0000-0001-000000000001',
    '00000000-0000-0000-0002-000000000001',
    null,
    'salon_employee', 'hybrid', 2400.00, 15, timestamptz '2018-09-01T00:00:00Z'
  ),
  (
    '00000000-0000-0000-0009-000000000003',
    '00000000-0000-0000-0001-000000000002',
    '00000000-0000-0000-0002-000000000002',
    null,
    'salon_manager', 'commission', null, 40, timestamptz '2020-02-01T00:00:00Z'
  )
on conflict (id) do nothing;

insert into shifts (id, salon_id, employee_id, starts_at, ends_at, note)
select
  ('00000000-0000-0000-0013-00000000000' || d::text)::uuid,
  '00000000-0000-0000-0001-000000000001',
  '00000000-0000-0000-0009-000000000002',
  date_trunc('day', now()) + make_interval(days => d, hours => 9),
  date_trunc('day', now()) + make_interval(days => d, hours => 18),
  case when d = 3 then 'Bridal trial in the afternoon' end
from generate_series(1, 5) as d
on conflict (id) do nothing;

insert into performance_goals (employee_id, metric, target, progress, period_start, period_end)
values
  ('00000000-0000-0000-0009-000000000002', 'revenue', 12000.00, 7450.00,
   date_trunc('month', now()), date_trunc('month', now()) + interval '1 month'),
  ('00000000-0000-0000-0009-000000000002', 'rebook_rate', 70.00, 62.00,
   date_trunc('month', now()), date_trunc('month', now()) + interval '1 month')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 7. Appointments
--
-- `upcomingAppointment` keeps PreviewData's identity; a completed visit six
-- weeks ago gives the wallet, loyalty, and CRM screens real history.
-- -----------------------------------------------------------------------------

insert into appointments (
  id, salon_id, salon_name, client_id, status, client_notes
)
values
  (
    '00000000-0000-0000-0004-000000000001',
    '00000000-0000-0000-0001-000000000001',
    'Maison Lumière',
    '00000000-0000-0000-0000-000000000001',
    'confirmed',
    'Going a touch cooler than last time, please.'
  ),
  (
    '00000000-0000-0000-0004-000000000002',
    '00000000-0000-0000-0001-000000000001',
    'Maison Lumière',
    '00000000-0000-0000-0000-000000000001',
    'completed',
    null
  )
on conflict (id) do nothing;

insert into appointment_items (
  id, appointment_id, service_id, service_name, professional_id, professional_name,
  starts_at, duration_minutes, ends_at, price_amount, position, is_blocking
)
values
  (
    '00000000-0000-0000-0014-000000000001',
    '00000000-0000-0000-0004-000000000001',
    '00000000-0000-0000-0003-000000000001',
    'Balayage & Gloss',
    '00000000-0000-0000-0002-000000000001',
    'Amélie Dubois',
    date_trunc('day', now()) + interval '3 days 10 hours',
    150,
    date_trunc('day', now()) + interval '3 days 10 hours' + interval '165 minutes',
    185.00, 0, true
  ),
  (
    -- Completed: the chair is free again, so this row must not participate in
    -- the overlap exclusion constraint.
    '00000000-0000-0000-0014-000000000002',
    '00000000-0000-0000-0004-000000000002',
    '00000000-0000-0000-0003-000000000002',
    'Cut & Blow-Dry',
    '00000000-0000-0000-0002-000000000001',
    'Amélie Dubois',
    date_trunc('day', now()) - interval '42 days' + interval '14 hours',
    60,
    date_trunc('day', now()) - interval '42 days' + interval '14 hours' + interval '70 minutes',
    75.00, 0, false
  )
on conflict (id) do nothing;

insert into waitlist_entries (salon_id, client_id, service_id, professional_id, earliest, latest)
values (
  '00000000-0000-0000-0001-000000000001',
  '00000000-0000-0000-0000-000000000009',
  '00000000-0000-0000-0003-000000000002',
  '00000000-0000-0000-0002-000000000001',
  date_trunc('day', now()) + interval '1 day 9 hours',
  date_trunc('day', now()) + interval '2 days 19 hours'
)
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 8. Money — the completed visit, paid in full
-- -----------------------------------------------------------------------------

insert into orders (
  id, salon_id, client_id, appointment_id, status, discount_amount,
  vat_percent, amount_paid, points_earned, currency, created_at, paid_at
)
values (
  '00000000-0000-0000-000a-000000000001',
  '00000000-0000-0000-0001-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0004-000000000002',
  'paid', 0, 21, 75.00, 75, 'EUR',
  now() - interval '42 days', now() - interval '42 days'
)
on conflict (id) do nothing;

insert into order_lines (order_id, kind, title, quantity, unit_price, reference_id, position)
values (
  '00000000-0000-0000-000a-000000000001', 'service', 'Cut & Blow-Dry', 1, 75.00,
  '00000000-0000-0000-0003-000000000002', 0
)
on conflict do nothing;

update appointments
set order_id = '00000000-0000-0000-000a-000000000001'
where id = '00000000-0000-0000-0004-000000000002';

insert into invoices (order_id, number, issued_at)
values ('00000000-0000-0000-000a-000000000001', 'PRV-2026-000148', now() - interval '42 days')
on conflict (number) do nothing;

insert into wallet_transactions (user_id, kind, amount, points, title, order_id, created_at)
values
  ('00000000-0000-0000-0000-000000000001', 'payment', -75.00, 0,
   'Cut & Blow-Dry — Maison Lumière', '00000000-0000-0000-000a-000000000001',
   now() - interval '42 days'),
  ('00000000-0000-0000-0000-000000000001', 'cashback', 1.50, 0,
   'Prepayment cashback', '00000000-0000-0000-000a-000000000001',
   now() - interval '42 days'),
  ('00000000-0000-0000-0000-000000000001', 'store_credit_top_up', 25.00, 0,
   'Gift card redeemed', null, now() - interval '30 days')
on conflict do nothing;

insert into gift_cards (code, salon_id, initial_balance, remaining_balance, purchaser_id, message)
values (
  'LUMIERE-GLOW-2026',
  '00000000-0000-0000-0001-000000000001',
  100.00, 75.00,
  '00000000-0000-0000-0000-000000000009',
  'Happy birthday — enjoy something beautiful.'
)
on conflict do nothing;

insert into saved_payment_methods (user_id, kind, display_label, last_four, expiry_month, expiry_year, is_default)
values (
  '00000000-0000-0000-0000-000000000001', 'card', 'Visa •••• 4242', '4242', 11, 2029, true
)
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 9. Memberships & packages
-- -----------------------------------------------------------------------------

insert into membership_plans (id, salon_id, tier, name, details, price_amount, cycle)
values (
  '00000000-0000-0000-0005-000000000001',
  '00000000-0000-0000-0001-000000000001',
  'gold', 'Lumière Gold',
  'Monthly blow-dry, 15% off all color, priority booking, and a birthday ritual.',
  89.00, 'monthly'
)
on conflict (id) do nothing;

insert into membership_benefits (id, plan_id, kind, title, value, position)
values
  ('00000000-0000-0000-000b-000000000001', '00000000-0000-0000-0005-000000000001',
   'free_service', '1 Signature Blow-Dry / month', 1, 0),
  ('00000000-0000-0000-000b-000000000002', '00000000-0000-0000-0005-000000000001',
   'discount_percent', '15% off color services', 15, 1),
  ('00000000-0000-0000-000b-000000000003', '00000000-0000-0000-0005-000000000001',
   'priority_booking', 'Priority booking', null, 2),
  ('00000000-0000-0000-000b-000000000004', '00000000-0000-0000-0005-000000000001',
   'birthday_gift', 'Birthday ritual', null, 3)
on conflict (id) do nothing;

insert into membership_subscriptions (plan_id, user_id, status, started_at, renews_at)
values (
  '00000000-0000-0000-0005-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'active',
  now() - interval '90 days',
  date_trunc('day', now()) + interval '11 days'
)
on conflict do nothing;

insert into service_packages (
  id, salon_id, name, details, theme, regular_price, package_price, validity_days
)
values (
  '00000000-0000-0000-0006-000000000001',
  '00000000-0000-0000-0001-000000000001',
  'Bridal Radiance',
  'Trial + wedding-day hair and makeup, with a glow facial the week before.',
  'wedding', 520.00, 440.00, 180
)
on conflict (id) do nothing;

insert into package_services (package_id, service_id, quantity, position)
values
  ('00000000-0000-0000-0006-000000000001', '00000000-0000-0000-0003-000000000001', 1, 0),
  ('00000000-0000-0000-0006-000000000001', '00000000-0000-0000-0003-000000000002', 2, 1)
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 10. Loyalty
-- -----------------------------------------------------------------------------

insert into achievements (id, title, details, symbol_name, xp_reward, points_reward)
values
  ('00000000-0000-0000-0011-000000000001', 'First Visit',
   'Completed your first appointment on PRV.', 'sparkles', 100, 50),
  ('00000000-0000-0000-0011-000000000002', 'Colour Devotee',
   'Booked five colour services.', 'paintpalette.fill', 500, 250),
  ('00000000-0000-0000-0011-000000000003', 'Early Bird',
   'Booked ten appointments more than a week in advance.', 'sunrise.fill', 300, 150)
on conflict (id) do nothing;

insert into loyalty_profiles (user_id, xp, spendable_points, referral_code, current_streak_days)
values ('00000000-0000-0000-0000-000000000001', 6450, 1240, 'SOFIA-GLOW', 4)
on conflict (user_id) do update
  set xp = excluded.xp,
      spendable_points = excluded.spendable_points,
      referral_code = excluded.referral_code,
      current_streak_days = excluded.current_streak_days;

insert into loyalty_achievements (loyalty_profile_id, achievement_id)
select lp.id, a.id
from loyalty_profiles lp
cross join achievements a
where lp.user_id = '00000000-0000-0000-0000-000000000001'
  and a.id in (
    '00000000-0000-0000-0011-000000000001',
    '00000000-0000-0000-0011-000000000002'
  )
on conflict do nothing;

insert into loyalty_challenges (
  id, user_id, title, details, symbol_name, target_count, progress_count, points_reward, ends_at
)
values (
  '00000000-0000-0000-0011-000000000101',
  '00000000-0000-0000-0000-000000000001',
  'Three visits this month',
  'Book and complete three appointments before the month ends.',
  'flame.fill', 3, 1, 500,
  date_trunc('month', now()) + interval '1 month'
)
on conflict (id) do nothing;

-- -----------------------------------------------------------------------------
-- 11. Reviews
-- -----------------------------------------------------------------------------

insert into reviews (
  id, salon_id, professional_id, author_id, author_name, rating, text,
  verified_appointment_id, owner_response, owner_responded_at, moderation, created_at
)
values
  (
    '00000000-0000-0000-0012-000000000001',
    '00000000-0000-0000-0001-000000000001',
    '00000000-0000-0000-0002-000000000001',
    '00000000-0000-0000-0000-000000000001', 'Sofia L.', 5,
    'Amélie is a magician. The balayage looks completely natural and grew out beautifully.',
    '00000000-0000-0000-0004-000000000001',
    'Thank you Sofia — see you at your gloss refresh!', now() - interval '39 days',
    'approved', now() - interval '40 days'
  ),
  (
    '00000000-0000-0000-0012-000000000002',
    '00000000-0000-0000-0001-000000000001',
    null,
    '00000000-0000-0000-0000-000000000009', 'Marie V.', 4,
    'Beautiful salon, slightly long wait but worth it.',
    null, null, null, 'approved', now() - interval '20 days'
  ),
  (
    '00000000-0000-0000-0012-000000000003',
    '00000000-0000-0000-0001-000000000002',
    '00000000-0000-0000-0002-000000000002',
    '00000000-0000-0000-0000-000000000001', 'Sofia L.', 5,
    'The chrome French Noor did lasted three weeks without a single chip.',
    null, null, null, 'approved', now() - interval '12 days'
  )
on conflict (id) do nothing;

insert into review_likes (review_id, user_id)
values
  ('00000000-0000-0000-0012-000000000001', '00000000-0000-0000-0000-000000000009'),
  ('00000000-0000-0000-0012-000000000001', '00000000-0000-0000-0000-000000000002')
on conflict do nothing;

insert into review_comments (review_id, author_id, author_name, text)
values (
  '00000000-0000-0000-0012-000000000001',
  '00000000-0000-0000-0000-000000000009', 'Marie V.',
  'Booked with Amélie because of this review — she is wonderful.'
)
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 12. Chat
-- -----------------------------------------------------------------------------

insert into conversations (id, kind, title, salon_id, last_message_preview, last_message_at)
values
  (
    '00000000-0000-0000-000c-000000000001', 'client_salon', 'Maison Lumière',
    '00000000-0000-0000-0001-000000000001',
    'Perfect — see you Thursday at 10:00.', now() - interval '2 days'
  ),
  (
    '00000000-0000-0000-000c-000000000002', 'assistant', 'Beauty Assistant',
    null, 'Here are three looks that suit your goal.', now() - interval '1 day'
  )
on conflict (id) do nothing;

insert into conversation_participants (conversation_id, user_id, last_read_at)
values
  ('00000000-0000-0000-000c-000000000001', '00000000-0000-0000-0000-000000000001', now() - interval '2 days'),
  ('00000000-0000-0000-000c-000000000001', '00000000-0000-0000-0000-000000000002', now() - interval '2 days'),
  ('00000000-0000-0000-000c-000000000002', '00000000-0000-0000-0000-000000000001', now() - interval '1 day')
on conflict do nothing;

insert into messages (
  conversation_id, sender_id, is_from_assistant, content_kind, body, sent_at
)
values
  ('00000000-0000-0000-000c-000000000001', '00000000-0000-0000-0000-000000000001', false,
   'text', 'Hi! Could I move my balayage to the morning?', now() - interval '2 days 30 minutes'),
  ('00000000-0000-0000-000c-000000000001', '00000000-0000-0000-0000-000000000002', false,
   'text', 'Perfect — see you Thursday at 10:00.', now() - interval '2 days'),
  ('00000000-0000-0000-000c-000000000002', null, true,
   'text', 'Here are three looks that suit your goal.', now() - interval '1 day')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 13. CRM
-- -----------------------------------------------------------------------------

insert into client_records (
  id, salon_id, user_id, first_name, last_name, email, phone,
  hair_type, allergies, preferences, total_visits, total_spend_amount, last_visit_at
)
values (
  '00000000-0000-0000-000e-000000000001',
  '00000000-0000-0000-0001-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'Sofia', 'Laurent', 'sofia@example.com', '+32 470 12 34 56',
  'Fine, wavy', '{PPD}', '{"Cool tones","Sparkling water, no coffee"}',
  7, 940.00, now() - interval '42 days'
)
on conflict (id) do nothing;

insert into client_notes (client_record_id, author_id, kind, text, appointment_id)
values (
  '00000000-0000-0000-000e-000000000001',
  '00000000-0000-0000-0000-000000000002',
  'color_formula',
  'Root: 7.1 + 6% (20 min). Mid/ends: balayage lift to 9, gloss 9.12 + 1.5% (10 min).',
  '00000000-0000-0000-0004-000000000002'
)
on conflict do nothing;

insert into consent_forms (client_record_id, title, version, signed_at)
values (
  '00000000-0000-0000-000e-000000000001',
  'Colour treatment & patch test consent', '2026.1', now() - interval '42 days'
)
on conflict (client_record_id, title, version) do nothing;

-- -----------------------------------------------------------------------------
-- 14. Inventory
--
-- The second product sits below its threshold on insert, which exercises the
-- `notify_low_stock` trigger from 0003 and gives Emma a real notification.
-- -----------------------------------------------------------------------------

insert into suppliers (id, salon_id, name, email)
values (
  '00000000-0000-0000-000f-000000000001',
  '00000000-0000-0000-0001-000000000001',
  'Benelux Salon Supply', 'orders@beneluxsalonsupply.be'
)
on conflict (id) do nothing;

insert into products (
  id, salon_id, supplier_id, name, brand, barcode,
  retail_price_amount, cost_price_amount, stock_quantity, low_stock_threshold
)
values
  (
    '00000000-0000-0000-000f-000000000011',
    '00000000-0000-0000-0001-000000000001',
    '00000000-0000-0000-000f-000000000001',
    'Bond Repair Shampoo 250ml', 'Olaplex', '5060791209000',
    32.00, 17.50, 24, 6
  ),
  (
    '00000000-0000-0000-000f-000000000012',
    '00000000-0000-0000-0001-000000000001',
    '00000000-0000-0000-000f-000000000001',
    'Gloss Drops 50ml', 'Maison Lumière', '5060791209017',
    28.00, 11.00, 3, 5
  )
on conflict (id) do nothing;

insert into purchase_orders (id, salon_id, supplier_id, status, expected_at, created_by)
values (
  '00000000-0000-0000-000f-000000000021',
  '00000000-0000-0000-0001-000000000001',
  '00000000-0000-0000-000f-000000000001',
  'sent',
  date_trunc('day', now()) + interval '4 days',
  '00000000-0000-0000-0000-000000000002'
)
on conflict (id) do nothing;

insert into purchase_order_lines (
  purchase_order_id, product_id, product_name, quantity, unit_cost_amount, position
)
values (
  '00000000-0000-0000-000f-000000000021',
  '00000000-0000-0000-000f-000000000012',
  'Gloss Drops 50ml', 24, 11.00, 0
)
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 15. Marketing
-- -----------------------------------------------------------------------------

insert into coupons (
  id, salon_id, code, discount_kind, discount_percent, max_redemptions,
  minimum_spend_amount, valid_from, valid_until
)
values (
  '00000000-0000-0000-0010-000000000001',
  '00000000-0000-0000-0001-000000000001',
  'GLOW20', 'percent', 20, 200, 80.00,
  now() - interval '7 days', now() + interval '30 days'
)
on conflict (id) do nothing;

insert into campaigns (
  id, salon_id, name, kind, channels, message, coupon_id, status,
  scheduled_at, sent_count, open_count, booking_count, attributed_revenue_amount, created_by
)
values (
  '00000000-0000-0000-0010-000000000011',
  '00000000-0000-0000-0001-000000000001',
  'Spring Glow — 20% off colour', 'promotion', '{push,email}',
  'Spring refresh: 20% off any colour service this month with code GLOW20.',
  '00000000-0000-0000-0010-000000000001', 'running',
  now() - interval '5 days', 412, 268, 31, 4180.00,
  '00000000-0000-0000-0000-000000000002'
)
on conflict (id) do nothing;

-- -----------------------------------------------------------------------------
-- 16. Notifications & feature flags
-- -----------------------------------------------------------------------------

insert into notifications (user_id, kind, title, body, route)
values
  (
    '00000000-0000-0000-0000-000000000001', 'appointment_confirmed',
    'Your appointment is confirmed',
    'Balayage & Gloss with Amélie Dubois at Maison Lumière.',
    -- `AppRoute` uses Swift's synthesized enum encoding: one key per case, with
    -- positional associated values keyed `_0`.
    jsonb_build_object('appointment', jsonb_build_object('_0', '00000000-0000-0000-0004-000000000001'))
  ),
  (
    '00000000-0000-0000-0000-000000000001', 'loyalty_reward',
    'You reached Gold',
    'Gold unlocks priority booking and a birthday ritual.',
    jsonb_build_object('loyalty', jsonb_build_object())
  )
on conflict do nothing;

insert into feature_flags (key, is_enabled, description)
values
  ('ai_assistant', true, 'AI Beauty Assistant in chat.'),
  ('ai_search', true, 'Natural-language salon search in Discover.'),
  ('group_booking', true, 'Book a visit for several people at once.'),
  ('gift_cards', true, 'Gift card purchase and redemption.'),
  ('memberships', true, 'Membership plans and subscriptions.'),
  ('packages', true, 'Bundled service packages.'),
  ('live_activities', true, 'Booking Live Activity and Dynamic Island.'),
  ('virtual_tour', false, 'Salon virtual tours — pilot locations only.'),
  ('tiktok_feed', false, 'Embedded TikTok feed on salon profiles.'),
  ('instagram_feed', true, 'Embedded Instagram feed on salon profiles.'),
  ('referral_program', true, 'Referral codes and rewards.'),
  ('daily_rewards', true, 'Daily reward streaks.'),
  ('smart_calendar_optimization', true, 'Gap-filling slot recommendations.'),
  ('fraud_detection', true, 'Server-side velocity checks on refunds and gift cards.'),
  ('multi_salon', true, 'Multi-location switching and comparison.')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- 17. Audit trail
-- -----------------------------------------------------------------------------

insert into audit_log (actor_id, salon_id, action, operation, entity, entity_id, detail)
values (
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0001-000000000001',
  'prepayment_policy.updated', 'update', 'prepayment_policies',
  '00000000-0000-0000-0001-000000000001',
  'Cashback raised from 1% to 2% and full-prepayment discount set to 10%.'
)
on conflict do nothing;
