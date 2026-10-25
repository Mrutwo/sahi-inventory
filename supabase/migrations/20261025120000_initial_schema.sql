-- =============================================================================
-- סח"י — Shared food inventory for volunteers
-- Initial schema: profiles & roles, product catalog, inventory, stock movements,
-- row-level security, and the RPC functions that are the ONLY write path.
--
-- Design notes
--  * Clients never write tables directly. Every change goes through a
--    SECURITY DEFINER function that validates input, locks the affected rows
--    (products row first, then inventory row — one global lock order, so no
--    deadlocks) and records an append-only stock movement in the same
--    transaction.
--  * Product identity = (normalized name, unit, normalized variant). Adding
--    "אורז" twice in the same unit always lands on the same row; the same name
--    in an incompatible unit (e.g. ק"ג vs. יחידות) is a separate product.
--  * Every write accepts an optional client-generated request id. Replaying the
--    same request (retry after a network failure, double tap, offline queue)
--    returns the original result instead of applying the change twice.
--  * Errors are raised with stable machine-readable messages ("SAHI_*") that
--    the app maps to Hebrew text.
-- =============================================================================

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- -----------------------------------------------------------------------------
-- Types
-- -----------------------------------------------------------------------------
create type public.member_role as enum ('pending', 'volunteer', 'admin');

create type public.movement_kind as enum (
  'create',       -- product created together with its first stock
  'increase',     -- stock added
  'decrease',     -- stock removed (distribution, expiry, …)
  'set',          -- stock count corrected to an exact value
  'edit',         -- product details changed (name, category, notes)
  'unit_change',  -- unit changed, quantity converted
  'archive',      -- removed from the active inventory
  'restore'       -- returned to the active inventory
);

-- -----------------------------------------------------------------------------
-- Text helpers
-- -----------------------------------------------------------------------------

-- Canonical key used for product identity and search. Mirrors
-- ProductNameNormalizer.key(_:) in the iOS app.
--  * strips Hebrew niqqud / cantillation marks
--  * unifies gershayim/geresh and typographic quotes with ASCII quotes
--  * lower-cases and collapses whitespace
create or replace function public.normalize_product_name(p_value text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select pg_catalog.btrim(
    pg_catalog.regexp_replace(
      pg_catalog.lower(
        pg_catalog.translate(
          pg_catalog.regexp_replace(
            coalesce(p_value, ''),
            '[֑-ׇֽֿׁׂׅׄ]', '', 'g'),
          E'״“”׳‘’',
          E'"""\'\'\'')),
      '\s+', ' ', 'g'))
$$;

-- Trims and collapses whitespace; returns NULL for blank input.
create or replace function private.clean_text(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(pg_catalog.btrim(pg_catalog.regexp_replace(coalesce(p_value, ''), '\s+', ' ', 'g')), '')
$$;

-- Trims multi-line text (notes) without collapsing line breaks.
create or replace function private.clean_multiline(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(pg_catalog.btrim(coalesce(p_value, ''), E' \t\r\n'), '')
$$;

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------

create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text not null check (char_length(btrim(display_name)) between 1 and 80),
  role          public.member_role not null default 'pending',
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.profiles is
  'One row per volunteer. role=pending until the volunteer enters the join code or an admin approves them. is_active=false revokes access immediately (enforced by RLS on every query).';

create table public.units (
  code          text primary key check (code ~ '^[a-z][a-z0-9_]{0,23}$'),
  name_he       text not null,
  name_en       text,
  name_ru       text,
  dimension     text not null check (dimension in ('count', 'mass', 'volume')),
  base_factor   numeric(14, 6) not null check (base_factor > 0),
  sort_order    integer not null default 0,
  is_active     boolean not null default true
);
comment on table public.units is
  'Units of measurement. Quantities are only ever combined within the same unit; conversion (kg <-> g, liter <-> ml) uses base_factor within one dimension. Count units (boxes, bottles, …) are never converted into each other.';

create table public.categories (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique check (slug ~ '^[a-z][a-z0-9_]{0,39}$'),
  name_he       text not null unique,
  name_en       text,
  name_ru       text,
  icon          text not null default 'shippingbox',
  sort_order    integer not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

create table public.products (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (char_length(btrim(name)) between 1 and 120),
  name_key      text generated always as (public.normalize_product_name(name)) stored,
  -- Reserved for tracking brands / package sizes separately in the future
  -- (e.g. "אורז" + "פרסי 1 ק"ג"). Empty string = generic product.
  variant       text not null default '' check (char_length(variant) <= 120),
  category_id   uuid references public.categories (id),
  unit_code     text not null references public.units (code),
  notes         text check (notes is null or char_length(notes) <= 500),
  is_active     boolean not null default true,
  version       integer not null default 1 check (version > 0),
  created_at    timestamptz not null default now(),
  created_by    uuid references public.profiles (id) on delete set null,
  updated_at    timestamptz not null default now(),
  updated_by    uuid references public.profiles (id) on delete set null
);

create unique index products_identity_key
  on public.products (name_key, unit_code, public.normalize_product_name(variant));
create index products_active_name_idx on public.products (is_active, name_key);
create index products_category_idx on public.products (category_id);

create table public.inventory (
  product_id    uuid primary key references public.products (id) on delete restrict,
  quantity      numeric(14, 3) not null default 0
                  check (quantity >= 0 and quantity <= 1000000000),
  version       integer not null default 1 check (version > 0),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references public.profiles (id) on delete set null
);

create table public.stock_movements (
  id                 bigint generated always as identity primary key,
  product_id         uuid not null references public.products (id) on delete restrict,
  kind               public.movement_kind not null,
  quantity_delta     numeric(14, 3) not null default 0,
  previous_quantity  numeric(14, 3),
  new_quantity       numeric(14, 3),
  unit_code          text not null references public.units (code),
  reason             text check (reason is null or char_length(reason) <= 500),
  details            jsonb,
  request_id         uuid unique,
  created_at         timestamptz not null default now(),
  -- No FK on purpose: history must survive even if a volunteer's account is
  -- deleted. actor_name keeps a readable snapshot.
  created_by         uuid,
  actor_name         text
);
comment on table public.stock_movements is
  'Append-only audit log of every inventory change. Rows cannot be updated or deleted (trigger enforced).';

create index stock_movements_product_idx on public.stock_movements (product_id, created_at desc);
create index stock_movements_created_idx on public.stock_movements (created_at desc);

create table private.app_settings (
  id              boolean primary key default true check (id),
  join_code_hash  text,
  join_code_salt  text,
  updated_at      timestamptz not null default now(),
  updated_by      uuid
);
insert into private.app_settings (id) values (true);

create table private.join_attempts (
  user_id       uuid not null,
  attempted_at  timestamptz not null default now()
);
create index join_attempts_user_idx on private.join_attempts (user_id, attempted_at desc);

-- -----------------------------------------------------------------------------
-- Reference data
-- -----------------------------------------------------------------------------
insert into public.units (code, name_he, name_en, name_ru, dimension, base_factor, sort_order) values
  ('unit',    'יחידות',   'units',    'шт.',       'count',  1,    10),
  ('box',     'קופסאות',  'cans/boxes','банки',    'count',  1,    20),
  ('bottle',  'בקבוקים',  'bottles',  'бутылки',   'count',  1,    30),
  ('package', 'חבילות',   'packages', 'упаковки',  'count',  1,    40),
  ('kg',      'ק"ג',      'kg',       'кг',        'mass',   1000, 50),
  ('g',       'גרם',      'g',        'г',         'mass',   1,    60),
  ('liter',   'ליטרים',   'liters',   'л',         'volume', 1000, 70)
on conflict (code) do nothing;

insert into public.categories (slug, name_he, name_en, name_ru, icon, sort_order) values
  ('basics',        'מוצרי יסוד',     'Staples',          'Основные продукты',   'basket',               10),
  ('grains',        'קטניות ודגנים',  'Grains & legumes', 'Крупы и бобовые',     'leaf',                 20),
  ('canned',        'שימורים',        'Canned food',      'Консервы',            'shippingbox',          30),
  ('dairy',         'מוצרי חלב',      'Dairy',            'Молочные продукты',   'waterbottle',          40),
  ('oil_spices',    'שמן ותבלינים',   'Oil & spices',     'Масло и специи',      'drop.halffull',        50),
  ('drinks',        'שתייה',          'Drinks',           'Напитки',             'mug',                  60),
  ('hygiene',       'מוצרי היגיינה',  'Hygiene',          'Гигиена',             'bubbles.and.sparkles', 70),
  ('other',         'אחר',            'Other',            'Другое',              'square.grid.2x2',      999)
on conflict (slug) do nothing;

-- -----------------------------------------------------------------------------
-- Membership helpers (SECURITY DEFINER so RLS policies can call them without
-- recursing into the profiles policy)
-- -----------------------------------------------------------------------------
create or replace function private.is_member()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role in ('volunteer', 'admin')
  )
$$;

create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.role = 'admin'
  )
$$;

-- Returns the caller's profile or raises if the caller may not use the inventory.
create or replace function private.require_member()
returns public.profiles
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
begin
  if auth.uid() is null then
    raise exception 'SAHI_NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  select * into v_profile from public.profiles where id = auth.uid();
  if not found or v_profile.role = 'pending' then
    raise exception 'SAHI_NOT_MEMBER' using errcode = '42501';
  end if;
  if not v_profile.is_active then
    raise exception 'SAHI_ACCOUNT_DISABLED' using errcode = '42501';
  end if;
  return v_profile;
end;
$$;

create or replace function private.require_admin()
returns public.profiles
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
begin
  v_profile := private.require_member();
  if v_profile.role <> 'admin' then
    raise exception 'SAHI_NOT_ADMIN' using errcode = '42501';
  end if;
  return v_profile;
end;
$$;

-- Validates a quantity for the given unit dimension.
create or replace function private.validate_quantity(p_quantity numeric, p_dimension text, p_allow_zero boolean)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_quantity is null or p_quantity < 0 or (p_quantity = 0 and not p_allow_zero) then
    raise exception 'SAHI_INVALID_QUANTITY' using errcode = '22023';
  end if;
  if p_quantity > 1000000 then
    raise exception 'SAHI_QUANTITY_TOO_LARGE' using errcode = '22023';
  end if;
  if p_quantity <> round(p_quantity, 3) then
    raise exception 'SAHI_INVALID_QUANTITY' using errcode = '22023';
  end if;
  if p_dimension = 'count' and p_quantity <> trunc(p_quantity) then
    raise exception 'SAHI_WHOLE_NUMBER_REQUIRED' using errcode = '22023';
  end if;
end;
$$;

create or replace function private.movement_result(p_movement public.stock_movements, p_replayed boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'movement_id',       p_movement.id,
    'product_id',        p_movement.product_id,
    'kind',              p_movement.kind,
    'quantity_delta',    p_movement.quantity_delta,
    'previous_quantity', p_movement.previous_quantity,
    'new_quantity',      p_movement.new_quantity,
    'replayed',          p_replayed
  )
$$;

create or replace function private.hash_join_code(p_code text, p_salt text)
returns text
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(coalesce(p_salt, '') || ':' || pg_catalog.upper(pg_catalog.btrim(coalesce(p_code, ''))), 'UTF8')),
    'hex')
$$;

-- -----------------------------------------------------------------------------
-- Triggers
-- -----------------------------------------------------------------------------

-- Every new auth user gets a pending profile.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    left(coalesce(
      private.clean_text(new.raw_user_meta_data ->> 'display_name'),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'מתנדב/ת'), 80)
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- Stock history is append-only.
create or replace function private.prevent_history_changes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'SAHI_HISTORY_IMMUTABLE' using errcode = '42501';
end;
$$;

create trigger stock_movements_append_only
  before update or delete on public.stock_movements
  for each row execute function private.prevent_history_changes();

create trigger stock_movements_no_truncate
  before truncate on public.stock_movements
  for each statement execute function private.prevent_history_changes();

-- -----------------------------------------------------------------------------
-- Read models (views run with the caller's permissions → RLS applies)
-- -----------------------------------------------------------------------------
create view public.inventory_items with (security_invoker = true) as
select
  p.id,
  p.name,
  p.name_key,
  p.variant,
  p.category_id,
  p.unit_code,
  p.notes,
  p.is_active,
  coalesce(i.quantity, 0)  as quantity,
  p.version                as product_version,
  coalesce(i.version, 0)   as stock_version,
  p.created_at,
  p.updated_at,
  pr.display_name          as updated_by_name
from public.products p
left join public.inventory i on i.product_id = p.id
left join public.profiles pr on pr.id = p.updated_by;

create view public.activity_feed with (security_invoker = true) as
select
  m.id,
  m.product_id,
  p.name as product_name,
  m.kind,
  m.quantity_delta,
  m.previous_quantity,
  m.new_quantity,
  m.unit_code,
  m.reason,
  m.details,
  m.created_at,
  m.created_by,
  coalesce(pr.display_name, m.actor_name) as actor_name
from public.stock_movements m
join public.products p on p.id = m.product_id
left join public.profiles pr on pr.id = m.created_by;

-- -----------------------------------------------------------------------------
-- Row-level security: members may read; nobody may write directly.
-- -----------------------------------------------------------------------------
alter table public.profiles        enable row level security;
alter table public.units           enable row level security;
alter table public.categories      enable row level security;
alter table public.products        enable row level security;
alter table public.inventory       enable row level security;
alter table public.stock_movements enable row level security;
alter table private.app_settings   enable row level security;
alter table private.join_attempts  enable row level security;

create policy "profiles: own row or members"
  on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.is_member()));

create policy "units: members read"
  on public.units for select to authenticated
  using ((select private.is_member()));

create policy "categories: members read"
  on public.categories for select to authenticated
  using ((select private.is_member()));

create policy "products: members read"
  on public.products for select to authenticated
  using ((select private.is_member()));

create policy "inventory: members read"
  on public.inventory for select to authenticated
  using ((select private.is_member()));

create policy "stock_movements: members read"
  on public.stock_movements for select to authenticated
  using ((select private.is_member()));

-- -----------------------------------------------------------------------------
-- RPC: membership
-- -----------------------------------------------------------------------------

-- Joins the shared inventory with the organization's join code.
-- Returns a status instead of raising, so failed attempts are recorded and
-- rate limited (5 attempts per 15 minutes).
create or replace function public.join_with_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_profile  public.profiles;
  v_settings private.app_settings;
  v_attempts integer;
begin
  if v_uid is null then
    raise exception 'SAHI_NOT_AUTHENTICATED' using errcode = '28000';
  end if;

  select * into v_profile from public.profiles where id = v_uid for update;
  if not found then
    insert into public.profiles (id, display_name)
    select u.id, left(coalesce(nullif(split_part(coalesce(u.email, ''), '@', 1), ''), 'מתנדב/ת'), 80)
    from auth.users u where u.id = v_uid
    returning * into v_profile;
    if not found then
      raise exception 'SAHI_NOT_AUTHENTICATED' using errcode = '28000';
    end if;
  end if;

  if not v_profile.is_active then
    return jsonb_build_object('status', 'account_disabled');
  end if;
  if v_profile.role <> 'pending' then
    return jsonb_build_object('status', 'already_member');
  end if;

  select count(*) into v_attempts
  from private.join_attempts
  where user_id = v_uid and attempted_at > now() - interval '15 minutes';
  if v_attempts >= 5 then
    return jsonb_build_object('status', 'too_many_attempts');
  end if;

  select * into v_settings from private.app_settings where id;
  if v_settings.join_code_hash is null then
    return jsonb_build_object('status', 'not_configured');
  end if;

  insert into private.join_attempts (user_id) values (v_uid);

  if private.hash_join_code(p_code, v_settings.join_code_salt) = v_settings.join_code_hash then
    update public.profiles
       set role = 'volunteer', updated_at = now()
     where id = v_uid;
    delete from private.join_attempts where user_id = v_uid;
    return jsonb_build_object('status', 'joined');
  end if;

  return jsonb_build_object('status', 'invalid_code');
end;
$$;

create or replace function public.update_my_profile(p_display_name text)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name    text := private.clean_text(p_display_name);
  v_profile public.profiles;
begin
  if auth.uid() is null then
    raise exception 'SAHI_NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if v_name is null or char_length(v_name) > 80 then
    raise exception 'SAHI_INVALID_DISPLAY_NAME' using errcode = '22023';
  end if;
  update public.profiles
     set display_name = v_name, updated_at = now()
   where id = auth.uid()
  returning * into v_profile;
  if not found then
    raise exception 'SAHI_NOT_MEMBER' using errcode = '42501';
  end if;
  return v_profile;
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC: stock
-- -----------------------------------------------------------------------------

-- Adds stock by product name. Creates the product if it does not exist yet,
-- otherwise atomically increases the existing product's quantity (aggregation).
-- An archived product with the same identity is restored instead of duplicated.
create or replace function public.add_stock(
  p_name        text,
  p_unit_code   text,
  p_quantity    numeric,
  p_category_id uuid default null,
  p_notes       text default null,
  p_variant     text default '',
  p_request_id  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor       public.profiles;
  v_existing    public.stock_movements;
  v_movement    public.stock_movements;
  v_name        text;
  v_variant     text;
  v_notes       text;
  v_unit        public.units;
  v_category_id uuid;
  v_product     public.products;
  v_created     boolean := false;
  v_prev        numeric;
  v_new         numeric;
begin
  v_actor := private.require_member();

  if p_request_id is not null then
    select * into v_existing from public.stock_movements where request_id = p_request_id;
    if found then
      return private.movement_result(v_existing, true);
    end if;
  end if;

  v_name := private.clean_text(p_name);
  if v_name is null or char_length(v_name) > 120 then
    raise exception 'SAHI_INVALID_NAME' using errcode = '22023';
  end if;
  v_variant := coalesce(private.clean_text(p_variant), '');
  v_notes := private.clean_multiline(p_notes);
  if char_length(v_notes) > 500 then
    raise exception 'SAHI_NOTES_TOO_LONG' using errcode = '22023';
  end if;

  select * into v_unit from public.units where code = p_unit_code and is_active;
  if not found then
    raise exception 'SAHI_INVALID_UNIT' using errcode = '22023';
  end if;
  perform private.validate_quantity(p_quantity, v_unit.dimension, false);

  if p_category_id is null then
    select id into v_category_id from public.categories where slug = 'other';
  else
    select id into v_category_id from public.categories where id = p_category_id and is_active;
    if not found then
      raise exception 'SAHI_INVALID_CATEGORY' using errcode = '22023';
    end if;
  end if;

  insert into public.products (name, variant, category_id, unit_code, notes, created_by, updated_by)
  values (v_name, v_variant, v_category_id, v_unit.code, v_notes, v_actor.id, v_actor.id)
  on conflict (name_key, unit_code, public.normalize_product_name(variant)) do nothing
  returning * into v_product;

  if found then
    v_created := true;
    insert into public.inventory (product_id, quantity, updated_by)
    values (v_product.id, 0, v_actor.id);
  else
    select * into v_product
      from public.products
     where name_key = public.normalize_product_name(v_name)
       and unit_code = v_unit.code
       and public.normalize_product_name(variant) = public.normalize_product_name(v_variant)
     for update;

    if not v_product.is_active then
      update public.products
         set is_active = true, version = version + 1, updated_at = now(), updated_by = v_actor.id
       where id = v_product.id;
      select quantity into v_prev from public.inventory where product_id = v_product.id;
      insert into public.stock_movements
        (product_id, kind, quantity_delta, previous_quantity, new_quantity, unit_code, created_by, actor_name)
      values
        (v_product.id, 'restore', 0, v_prev, v_prev, v_product.unit_code, v_actor.id, v_actor.display_name);
    end if;
  end if;

  select quantity into v_prev from public.inventory where product_id = v_product.id for update;
  v_new := v_prev + p_quantity;
  if v_new > 1000000000 then
    raise exception 'SAHI_QUANTITY_TOO_LARGE' using errcode = '22023';
  end if;

  update public.inventory
     set quantity = v_new, version = version + 1, updated_at = now(), updated_by = v_actor.id
   where product_id = v_product.id;
  update public.products
     set updated_at = now(), updated_by = v_actor.id
   where id = v_product.id;

  insert into public.stock_movements
    (product_id, kind, quantity_delta, previous_quantity, new_quantity, unit_code, reason, request_id, created_by, actor_name)
  values
    (v_product.id, case when v_created then 'create' else 'increase' end::public.movement_kind,
     p_quantity, v_prev, v_new, v_product.unit_code, v_notes, p_request_id, v_actor.id, v_actor.display_name)
  returning * into v_movement;

  return private.movement_result(v_movement, false);
end;
$$;

-- Increases (positive delta) or decreases (negative delta) a product's stock.
-- Deltas commute, so concurrent adjustments never lose updates.
create or replace function public.adjust_stock(
  p_product_id uuid,
  p_delta      numeric,
  p_reason     text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor    public.profiles;
  v_existing public.stock_movements;
  v_movement public.stock_movements;
  v_product  public.products;
  v_unit     public.units;
  v_prev     numeric;
  v_new      numeric;
  v_reason   text := private.clean_multiline(p_reason);
begin
  v_actor := private.require_member();

  if p_request_id is not null then
    select * into v_existing from public.stock_movements where request_id = p_request_id;
    if found then
      return private.movement_result(v_existing, true);
    end if;
  end if;

  if p_delta is null or p_delta = 0 then
    raise exception 'SAHI_INVALID_QUANTITY' using errcode = '22023';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'SAHI_NOTES_TOO_LONG' using errcode = '22023';
  end if;

  select * into v_product from public.products where id = p_product_id for update;
  if not found then
    raise exception 'SAHI_PRODUCT_NOT_FOUND' using errcode = '22023';
  end if;
  if not v_product.is_active then
    raise exception 'SAHI_PRODUCT_ARCHIVED' using errcode = '22023';
  end if;

  select * into v_unit from public.units where code = v_product.unit_code;
  perform private.validate_quantity(abs(p_delta), v_unit.dimension, false);

  select quantity into v_prev from public.inventory where product_id = p_product_id for update;
  v_new := v_prev + p_delta;
  if v_new < 0 then
    raise exception 'SAHI_INSUFFICIENT_STOCK' using errcode = '22023', detail = v_prev::text;
  end if;
  if v_new > 1000000000 then
    raise exception 'SAHI_QUANTITY_TOO_LARGE' using errcode = '22023';
  end if;

  update public.inventory
     set quantity = v_new, version = version + 1, updated_at = now(), updated_by = v_actor.id
   where product_id = p_product_id;
  update public.products
     set updated_at = now(), updated_by = v_actor.id
   where id = p_product_id;

  insert into public.stock_movements
    (product_id, kind, quantity_delta, previous_quantity, new_quantity, unit_code, reason, request_id, created_by, actor_name)
  values
    (p_product_id, case when p_delta > 0 then 'increase' else 'decrease' end::public.movement_kind,
     p_delta, v_prev, v_new, v_product.unit_code, v_reason, p_request_id, v_actor.id, v_actor.display_name)
  returning * into v_movement;

  return private.movement_result(v_movement, false);
end;
$$;

-- Sets an exact stock count (physical count / correction). Uses optimistic
-- concurrency: fails with SAHI_VERSION_CONFLICT if someone changed the stock
-- since the caller last saw it, so a stale screen can never overwrite a newer
-- value.
create or replace function public.set_stock(
  p_product_id       uuid,
  p_new_quantity     numeric,
  p_expected_version integer,
  p_reason           text default null,
  p_request_id       uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor    public.profiles;
  v_existing public.stock_movements;
  v_movement public.stock_movements;
  v_product  public.products;
  v_unit     public.units;
  v_stock    public.inventory;
  v_reason   text := private.clean_multiline(p_reason);
begin
  v_actor := private.require_member();

  if p_request_id is not null then
    select * into v_existing from public.stock_movements where request_id = p_request_id;
    if found then
      return private.movement_result(v_existing, true);
    end if;
  end if;

  if char_length(v_reason) > 500 then
    raise exception 'SAHI_NOTES_TOO_LONG' using errcode = '22023';
  end if;

  select * into v_product from public.products where id = p_product_id for update;
  if not found then
    raise exception 'SAHI_PRODUCT_NOT_FOUND' using errcode = '22023';
  end if;
  if not v_product.is_active then
    raise exception 'SAHI_PRODUCT_ARCHIVED' using errcode = '22023';
  end if;

  select * into v_unit from public.units where code = v_product.unit_code;
  perform private.validate_quantity(p_new_quantity, v_unit.dimension, true);

  select * into v_stock from public.inventory where product_id = p_product_id for update;
  if p_expected_version is null or v_stock.version <> p_expected_version then
    raise exception 'SAHI_VERSION_CONFLICT' using errcode = '40001';
  end if;

  if v_stock.quantity = p_new_quantity then
    return jsonb_build_object(
      'movement_id', null, 'product_id', p_product_id, 'kind', 'set',
      'quantity_delta', 0, 'previous_quantity', v_stock.quantity,
      'new_quantity', v_stock.quantity, 'replayed', false);
  end if;

  update public.inventory
     set quantity = p_new_quantity, version = version + 1, updated_at = now(), updated_by = v_actor.id
   where product_id = p_product_id;
  update public.products
     set updated_at = now(), updated_by = v_actor.id
   where id = p_product_id;

  insert into public.stock_movements
    (product_id, kind, quantity_delta, previous_quantity, new_quantity, unit_code, reason, request_id, created_by, actor_name)
  values
    (p_product_id, 'set', p_new_quantity - v_stock.quantity, v_stock.quantity, p_new_quantity,
     v_product.unit_code, v_reason, p_request_id, v_actor.id, v_actor.display_name)
  returning * into v_movement;

  return private.movement_result(v_movement, false);
end;
$$;

-- Edits product details. Unit changes are only allowed when they are safe:
-- the stock is empty, or the quantity can be converted exactly within the same
-- dimension (ק"ג ↔ גרם). Count units (boxes vs. bottles) are never converted.
create or replace function public.update_product(
  p_product_id       uuid,
  p_expected_version integer,
  p_name             text,
  p_category_id      uuid,
  p_unit_code        text,
  p_notes            text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor        public.profiles;
  v_product      public.products;
  v_stock        public.inventory;
  v_old_unit     public.units;
  v_new_unit     public.units;
  v_old_category public.categories;
  v_new_category public.categories;
  v_name         text := private.clean_text(p_name);
  v_notes        text := private.clean_multiline(p_notes);
  v_new_qty      numeric;
  v_details      jsonb := '{}'::jsonb;
  v_unit_changed boolean := false;
begin
  v_actor := private.require_member();

  select * into v_product from public.products where id = p_product_id for update;
  if not found then
    raise exception 'SAHI_PRODUCT_NOT_FOUND' using errcode = '22023';
  end if;
  if not v_product.is_active then
    raise exception 'SAHI_PRODUCT_ARCHIVED' using errcode = '22023';
  end if;
  if p_expected_version is null or v_product.version <> p_expected_version then
    raise exception 'SAHI_VERSION_CONFLICT' using errcode = '40001';
  end if;

  if v_name is null or char_length(v_name) > 120 then
    raise exception 'SAHI_INVALID_NAME' using errcode = '22023';
  end if;
  if char_length(v_notes) > 500 then
    raise exception 'SAHI_NOTES_TOO_LONG' using errcode = '22023';
  end if;

  select * into v_new_unit from public.units where code = p_unit_code and is_active;
  if not found then
    raise exception 'SAHI_INVALID_UNIT' using errcode = '22023';
  end if;
  select * into v_old_unit from public.units where code = v_product.unit_code;

  if p_category_id is null then
    select * into v_new_category from public.categories where slug = 'other';
  else
    select * into v_new_category from public.categories where id = p_category_id and is_active;
    if not found then
      raise exception 'SAHI_INVALID_CATEGORY' using errcode = '22023';
    end if;
  end if;
  select * into v_old_category from public.categories where id = v_product.category_id;

  select * into v_stock from public.inventory where product_id = p_product_id for update;

  if v_new_unit.code <> v_old_unit.code then
    v_unit_changed := true;
    if v_stock.quantity = 0 then
      v_new_qty := 0;
    elsif v_new_unit.dimension <> v_old_unit.dimension or v_new_unit.dimension = 'count' then
      raise exception 'SAHI_UNSAFE_UNIT_CHANGE' using errcode = '22023';
    else
      v_new_qty := round(v_stock.quantity * v_old_unit.base_factor / v_new_unit.base_factor, 3);
      if v_new_qty * v_new_unit.base_factor <> v_stock.quantity * v_old_unit.base_factor then
        raise exception 'SAHI_UNSAFE_UNIT_CHANGE' using errcode = '22023';
      end if;
    end if;
  end if;

  if v_name is distinct from v_product.name then
    v_details := v_details || jsonb_build_object('name', jsonb_build_object('from', v_product.name, 'to', v_name));
  end if;
  if v_new_category.id is distinct from v_product.category_id then
    v_details := v_details || jsonb_build_object('category', jsonb_build_object('from', v_old_category.name_he, 'to', v_new_category.name_he));
  end if;
  if v_notes is distinct from v_product.notes then
    v_details := v_details || jsonb_build_object('notes', jsonb_build_object('from', v_product.notes, 'to', v_notes));
  end if;

  if v_details = '{}'::jsonb and not v_unit_changed then
    return jsonb_build_object('product_id', v_product.id, 'version', v_product.version, 'changed', false);
  end if;

  begin
    update public.products
       set name = v_name,
           category_id = v_new_category.id,
           unit_code = v_new_unit.code,
           notes = v_notes,
           version = version + 1,
           updated_at = now(),
           updated_by = v_actor.id
     where id = p_product_id
    returning * into v_product;
  exception when unique_violation then
    raise exception 'SAHI_DUPLICATE_PRODUCT' using errcode = '23505';
  end;

  if v_unit_changed then
    update public.inventory
       set quantity = v_new_qty, version = version + 1, updated_at = now(), updated_by = v_actor.id
     where product_id = p_product_id;
    insert into public.stock_movements
      (product_id, kind, quantity_delta, previous_quantity, new_quantity, unit_code, details, created_by, actor_name)
    values
      (p_product_id, 'unit_change', 0, v_stock.quantity, v_new_qty, v_new_unit.code,
       jsonb_build_object('unit', jsonb_build_object('from', v_old_unit.code, 'to', v_new_unit.code)),
       v_actor.id, v_actor.display_name);
  end if;

  if v_details <> '{}'::jsonb then
    insert into public.stock_movements
      (product_id, kind, quantity_delta, previous_quantity, new_quantity, unit_code, details, created_by, actor_name)
    values
      (p_product_id, 'edit', 0, coalesce(v_new_qty, v_stock.quantity), coalesce(v_new_qty, v_stock.quantity),
       v_new_unit.code, v_details, v_actor.id, v_actor.display_name);
  end if;

  return jsonb_build_object('product_id', v_product.id, 'version', v_product.version, 'changed', true);
end;
$$;

-- Removes a product from the active inventory (admins only). The product and
-- its full history are kept; the remaining stock is written off and recorded.
create or replace function public.archive_product(p_product_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor    public.profiles;
  v_product  public.products;
  v_prev     numeric;
  v_movement public.stock_movements;
  v_reason   text := private.clean_multiline(p_reason);
begin
  v_actor := private.require_admin();

  if char_length(v_reason) > 500 then
    raise exception 'SAHI_NOTES_TOO_LONG' using errcode = '22023';
  end if;

  select * into v_product from public.products where id = p_product_id for update;
  if not found then
    raise exception 'SAHI_PRODUCT_NOT_FOUND' using errcode = '22023';
  end if;
  if not v_product.is_active then
    return jsonb_build_object('product_id', p_product_id, 'changed', false);
  end if;

  select quantity into v_prev from public.inventory where product_id = p_product_id for update;

  update public.inventory
     set quantity = 0, version = version + 1, updated_at = now(), updated_by = v_actor.id
   where product_id = p_product_id;
  update public.products
     set is_active = false, version = version + 1, updated_at = now(), updated_by = v_actor.id
   where id = p_product_id;

  insert into public.stock_movements
    (product_id, kind, quantity_delta, previous_quantity, new_quantity, unit_code, reason, created_by, actor_name)
  values
    (p_product_id, 'archive', -v_prev, v_prev, 0, v_product.unit_code, v_reason, v_actor.id, v_actor.display_name)
  returning * into v_movement;

  return private.movement_result(v_movement, false);
end;
$$;

create or replace function public.restore_product(p_product_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor   public.profiles;
  v_product public.products;
  v_qty     numeric;
begin
  v_actor := private.require_admin();

  select * into v_product from public.products where id = p_product_id for update;
  if not found then
    raise exception 'SAHI_PRODUCT_NOT_FOUND' using errcode = '22023';
  end if;
  if v_product.is_active then
    return jsonb_build_object('product_id', p_product_id, 'changed', false);
  end if;

  select quantity into v_qty from public.inventory where product_id = p_product_id;

  update public.products
     set is_active = true, version = version + 1, updated_at = now(), updated_by = v_actor.id
   where id = p_product_id;

  insert into public.stock_movements
    (product_id, kind, quantity_delta, previous_quantity, new_quantity, unit_code, created_by, actor_name)
  values
    (p_product_id, 'restore', 0, v_qty, v_qty, v_product.unit_code, v_actor.id, v_actor.display_name);

  return jsonb_build_object('product_id', p_product_id, 'changed', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC: administration
-- -----------------------------------------------------------------------------
create or replace function public.admin_list_members()
returns table (
  id               uuid,
  display_name     text,
  email            text,
  role             public.member_role,
  is_active        boolean,
  created_at       timestamptz,
  last_sign_in_at  timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin();
  return query
    select p.id, p.display_name, u.email::text, p.role, p.is_active, p.created_at, u.last_sign_in_at
      from public.profiles p
      join auth.users u on u.id = p.id
     order by p.is_active desc,
              case p.role when 'pending' then 0 when 'admin' then 1 else 2 end,
              p.display_name;
end;
$$;

create or replace function public.admin_update_member(
  p_user_id   uuid,
  p_role      public.member_role,
  p_is_active boolean
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.profiles;
begin
  perform private.require_admin();

  select * into v_target from public.profiles where id = p_user_id for update;
  if not found then
    raise exception 'SAHI_MEMBER_NOT_FOUND' using errcode = '22023';
  end if;
  if p_role is null or p_is_active is null then
    raise exception 'SAHI_INVALID_ROLE' using errcode = '22023';
  end if;

  if v_target.role = 'admin' and v_target.is_active and (p_role <> 'admin' or not p_is_active) then
    if not exists (
      select 1 from public.profiles
      where role = 'admin' and is_active and id <> v_target.id
    ) then
      raise exception 'SAHI_LAST_ADMIN' using errcode = '22023';
    end if;
  end if;

  update public.profiles
     set role = p_role, is_active = p_is_active, updated_at = now()
   where id = p_user_id
  returning * into v_target;
  return v_target;
end;
$$;

create or replace function public.admin_set_join_code(p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor public.profiles;
  v_code  text := pg_catalog.btrim(coalesce(p_code, ''));
  v_salt  text;
begin
  v_actor := private.require_admin();
  if char_length(v_code) < 6 or char_length(v_code) > 64 then
    raise exception 'SAHI_INVALID_JOIN_CODE' using errcode = '22023';
  end if;
  v_salt := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex');
  update private.app_settings
     set join_code_salt = v_salt,
         join_code_hash = private.hash_join_code(v_code, v_salt),
         updated_at = now(),
         updated_by = v_actor.id
   where id;
end;
$$;

-- One-time bootstrap, run from the Supabase SQL editor (not callable from the
-- app): promotes an existing account to admin and sets the first join code.
--   select private.bootstrap_admin('coordinator@example.org', 'YOUR-JOIN-CODE');
create or replace function private.bootstrap_admin(p_admin_email text, p_join_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid;
  v_salt text;
begin
  select id into v_uid from auth.users where lower(email) = lower(btrim(p_admin_email));
  if v_uid is null then
    raise exception 'No auth user with email %. Sign up in the app first.', p_admin_email;
  end if;
  if char_length(btrim(coalesce(p_join_code, ''))) < 6 then
    raise exception 'Join code must be at least 6 characters.';
  end if;

  insert into public.profiles (id, display_name, role)
  values (v_uid, split_part(p_admin_email, '@', 1), 'admin')
  on conflict (id) do update set role = 'admin', is_active = true, updated_at = now();

  v_salt := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex');
  update private.app_settings
     set join_code_salt = v_salt,
         join_code_hash = private.hash_join_code(p_join_code, v_salt),
         updated_at = now(),
         updated_by = v_uid
   where id;

  return 'OK: ' || p_admin_email || ' is now an admin and the join code is set.';
end;
$$;

-- -----------------------------------------------------------------------------
-- Privileges
-- -----------------------------------------------------------------------------
revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from authenticated;
grant select on all tables in schema public to authenticated;
revoke all on all tables in schema private from anon, authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;

grant execute on function private.is_member() to authenticated;
grant execute on function private.is_admin() to authenticated;
grant execute on function public.normalize_product_name(text) to authenticated;
grant execute on function public.join_with_code(text) to authenticated;
grant execute on function public.update_my_profile(text) to authenticated;
grant execute on function public.add_stock(text, text, numeric, uuid, text, text, uuid) to authenticated;
grant execute on function public.adjust_stock(uuid, numeric, text, uuid) to authenticated;
grant execute on function public.set_stock(uuid, numeric, integer, text, uuid) to authenticated;
grant execute on function public.update_product(uuid, integer, text, uuid, text, text) to authenticated;
grant execute on function public.archive_product(uuid, text) to authenticated;
grant execute on function public.restore_product(uuid) to authenticated;
grant execute on function public.admin_list_members() to authenticated;
grant execute on function public.admin_update_member(uuid, public.member_role, boolean) to authenticated;
grant execute on function public.admin_set_join_code(text) to authenticated;

-- Functions created later must not be callable by default.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Realtime: stream changes to subscribed clients (RLS is applied per user)
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table
      public.products, public.inventory, public.stock_movements, public.categories, public.profiles;
  end if;
end;
$$;
