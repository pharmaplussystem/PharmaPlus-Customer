-- PharmaPlus Customer Account / Online Ordering Fix
-- Run this whole script in Supabase SQL Editor.
-- It fixes customer_profiles creation when a customer signs up.

create table if not exists public.customer_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  pharmacy_id uuid not null references public.pharmacies(id) on delete cascade,
  address text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.customer_profiles enable row level security;

drop policy if exists customer_profiles_select_self on public.customer_profiles;
create policy customer_profiles_select_self on public.customer_profiles
for select to authenticated using (id = auth.uid());

drop policy if exists customer_profiles_update_self on public.customer_profiles;
create policy customer_profiles_update_self on public.customer_profiles
for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  pid uuid;
  assigned_role public.user_role := 'staff';
  inv record;
  invite_code text;
  acct text;
  cust_pharmacy uuid;
begin
  acct := lower(trim(coalesce(new.raw_user_meta_data->>'account_type','staff')));

  -- CUSTOMER ACCOUNT
  if acct = 'customer' then
    cust_pharmacy := nullif(trim(coalesce(new.raw_user_meta_data->>'pharmacy_id','')), '')::uuid;

    if cust_pharmacy is null then
      raise exception 'Please select a pharmacy';
    end if;

    if not exists (select 1 from public.pharmacies where id = cust_pharmacy) then
      raise exception 'Selected pharmacy not found';
    end if;

    insert into public.customer_profiles
      (id, full_name, phone, pharmacy_id, address)
    values
      (new.id,
       coalesce(new.raw_user_meta_data->>'full_name',''),
       nullif(new.raw_user_meta_data->>'phone',''),
       cust_pharmacy,
       nullif(new.raw_user_meta_data->>'address',''))
    on conflict (id) do update set
      full_name = excluded.full_name,
      phone = excluded.phone,
      pharmacy_id = excluded.pharmacy_id,
      address = excluded.address,
      updated_at = now();

    return new;
  end if;

  -- STAFF / ADMIN ACCOUNT
  invite_code := upper(trim(coalesce(new.raw_user_meta_data->>'invite_code','')));

  if invite_code <> '' then
    select * into inv
    from public.staff_invites
    where upper(trim(code)) = invite_code
      and used_at is null
      and expires_at > now()
    limit 1
    for update;

    if not found then
      raise exception 'Invalid or expired staff invitation code: %', invite_code;
    end if;

    pid := inv.pharmacy_id;
    assigned_role := inv.role;

    insert into public.profiles (id,email,full_name,role,pharmacy_id)
    values (
      new.id,
      new.email,
      coalesce(new.raw_user_meta_data->>'full_name',''),
      assigned_role,
      pid
    )
    on conflict (id) do update set
      email = excluded.email,
      full_name = excluded.full_name,
      role = excluded.role,
      pharmacy_id = excluded.pharmacy_id,
      updated_at = now();

    update public.staff_invites
    set used_at = now(), used_by = new.id
    where id = inv.id;
  else
    insert into public.pharmacies (name,location,contact,created_by)
    values (
      coalesce(nullif(trim(new.raw_user_meta_data->>'pharmacy_name'),''),'PharmaPlus Pharmacy'),
      nullif(trim(new.raw_user_meta_data->>'pharmacy_location'),''),
      nullif(trim(new.raw_user_meta_data->>'pharmacy_contact'),''),
      new.id
    )
    returning id into pid;

    assigned_role := 'admin';

    insert into public.profiles (id,email,full_name,role,pharmacy_id)
    values (
      new.id,
      new.email,
      coalesce(new.raw_user_meta_data->>'full_name',''),
      assigned_role,
      pid
    )
    on conflict (id) do nothing;
  end if;

  return new;
end;
$function$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Helpful index
create index if not exists customer_profiles_pharmacy_idx
on public.customer_profiles(pharmacy_id);

-- IMPORTANT: remove orphaned customer auth users before testing again.
-- Supabase Dashboard > Authentication > Users > delete the failed test customer,
-- then create the customer account again from the Customer Portal.
