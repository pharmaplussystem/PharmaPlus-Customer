-- PharmaPlus MASTER UPDATE
-- Run once in Supabase SQL Editor AFTER the existing Management schema and Customer Portal update.
-- This migration is idempotent and upgrades both apps to the same order/sales/settings rules.

alter table public.pharmacies add column if not exists mtn_number text;
alter table public.pharmacies add column if not exists mtn_merchant_code text;
alter table public.pharmacies add column if not exists mtn_registration_name text;
alter table public.pharmacies add column if not exists airtel_number text;
alter table public.pharmacies add column if not exists airtel_merchant_code text;
alter table public.pharmacies add column if not exists airtel_registration_name text;
alter table public.pharmacies add column if not exists pickup_latitude numeric(10,7);
alter table public.pharmacies add column if not exists pickup_longitude numeric(10,7);
alter table public.pharmacies add column if not exists delivery_fee_per_km numeric(14,2) not null default 0 check(delivery_fee_per_km>=0);

alter table public.online_orders add column if not exists customer_name text;
alter table public.online_orders add column if not exists delivery_fee numeric(14,2) not null default 0;
alter table public.online_orders add column if not exists distance_km numeric(12,3) not null default 0;
alter table public.online_orders add column if not exists payment_verified boolean not null default false;
update public.online_orders set status='ready',updated_at=now() where status in ('sent','preparing');
update public.online_orders set status='complete',updated_at=now() where status='completed';
alter table public.online_orders drop constraint if exists online_orders_status_check;
alter table public.online_orders add constraint online_orders_status_check check(status in ('pending','ready','confirmed','out_for_delivery','delivered','complete','completed','rejected','cancelled'));

alter table public.online_order_items add column if not exists unit_buy numeric(14,2) not null default 0;
alter table public.online_order_items add column if not exists line_profit numeric(14,2) not null default 0;

-- Customer portal can read the public pharmacy payment/pickup settings through this function.
drop function if exists public.get_online_pharmacies();
create or replace function public.get_online_pharmacies()
returns table(
  id uuid,name text,location text,contact text,email text,logo_url text,currency text,
  mtn_number text,mtn_merchant_code text,mtn_registration_name text,
  airtel_number text,airtel_merchant_code text,airtel_registration_name text,
  pickup_latitude numeric,pickup_longitude numeric,delivery_fee_per_km numeric
)
language sql security definer set search_path=public as $$
  select p.id,p.name,p.location,p.contact,p.email,p.logo_url,p.currency,
         p.mtn_number,p.mtn_merchant_code,p.mtn_registration_name,
         p.airtel_number,p.airtel_merchant_code,p.airtel_registration_name,
         p.pickup_latitude,p.pickup_longitude,p.delivery_fee_per_km
  from public.pharmacies p order by p.name;
$$;
grant execute on function public.get_online_pharmacies() to anon,authenticated;

-- Recreate order placement. Delivery distance/fee is calculated server-side from the two coordinates.
create or replace function public.place_online_order(
  p_pharmacy uuid,
  p_fulfillment text,
  p_delivery_address text,
  p_phone text,
  p_notes text,
  p_items jsonb,
  p_customer_type text default 'retail',
  p_payment_method text default null,
  p_mobile_network text default null,
  p_mobile_number text default null,
  p_transaction_message text default null,
  p_prescription_url text default null,
  p_latitude numeric default null,
  p_longitude numeric default null
)
returns public.online_orders
language plpgsql security definer set search_path=public as $function$
declare
  cid uuid; oid uuid; itm jsonb; pid uuid; requested_qty int; unit numeric; line numeric;
  total_items numeric:=0; total_amt numeric:=0; dist numeric:=0; fee numeric:=0;
  inserted public.online_orders; cp record; ph record;
begin
  if auth.uid() is null then raise exception 'You must be signed in'; end if;
  if lower(trim(coalesce(p_customer_type,'retail'))) not in ('retail','wholesale') then raise exception 'Invalid customer type'; end if;
  if lower(trim(coalesce(p_fulfillment,''))) not in ('delivery','pickup') then raise exception 'Invalid fulfillment option'; end if;
  if lower(trim(coalesce(p_payment_method,''))) not in ('mobile_money','bank','visa') then raise exception 'Select a payment method'; end if;
  if nullif(trim(coalesce(p_transaction_message,'')),'') is null then raise exception 'Payment transaction message/reference is required'; end if;
  if lower(trim(p_fulfillment))='delivery' and (p_latitude is null or p_longitude is null) then raise exception 'Live delivery location is required for home delivery'; end if;
  if lower(trim(coalesce(p_payment_method,'')))='mobile_money' and nullif(trim(coalesce(p_mobile_number,'')),'') is null then raise exception 'Mobile money number is required'; end if;
  select id,full_name,phone into cp from public.customer_profiles where id=auth.uid() and pharmacy_id=p_pharmacy and active=true;
  if cp.id is null then raise exception 'Customer profile not found for this pharmacy'; end if;
  select * into ph from public.pharmacies where id=p_pharmacy;
  if ph.id is null then raise exception 'Selected pharmacy not found'; end if;
  if lower(trim(p_fulfillment))='delivery' then
    if ph.pickup_latitude is null or ph.pickup_longitude is null then raise exception 'This pharmacy has not set its live pickup/facility location yet'; end if;
    dist := 6371 * 2 * asin(sqrt(
      power(sin(radians(p_latitude-ph.pickup_latitude)/2),2) +
      cos(radians(ph.pickup_latitude))*cos(radians(p_latitude))*power(sin(radians(p_longitude-ph.pickup_longitude)/2),2)
    ));
    fee := round(dist * coalesce(ph.delivery_fee_per_km,0),2);
  end if;
  insert into public.online_orders(customer_id,pharmacy_id,status,fulfillment,delivery_address,phone,notes,total,customer_type,payment_method,mobile_network,mobile_number,transaction_message,prescription_url,latitude,longitude,customer_name,delivery_fee,distance_km)
  values(cp.id,p_pharmacy,'pending',lower(trim(p_fulfillment)),nullif(trim(p_delivery_address),''),coalesce(nullif(trim(p_phone),''),cp.phone),nullif(trim(p_notes),''),0,lower(trim(p_customer_type)),lower(trim(p_payment_method)),nullif(trim(p_mobile_network),''),nullif(trim(p_mobile_number),''),trim(p_transaction_message),p_prescription_url,p_latitude,p_longitude,coalesce(nullif(trim(cp.full_name),''),'Customer'),fee,dist)
  returning id into oid;
  for itm in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    pid := (itm->>'product_id')::uuid; requested_qty := greatest(1,(itm->>'qty')::int);
    select case when lower(trim(p_customer_type))='wholesale' then wholesale_price else retail_price end into unit from public.products where id=pid and pharmacy_id=p_pharmacy and archived=false and expiry>=current_date;
    if unit is null then raise exception 'One of the selected items is no longer available'; end if;
    if not exists(select 1 from public.products where id=pid and pharmacy_id=p_pharmacy and archived=false and expiry>=current_date and qty>=requested_qty) then raise exception 'Insufficient stock for one of the selected items'; end if;
    line := unit*requested_qty; total_items:=total_items+line;
    insert into public.online_order_items(order_id,product_id,product_name,brand_name,batch,qty,unit_price,line_total,pharmacy_id,unit_buy,line_profit)
    select oid,id,name,brand_name,batch,requested_qty,unit,line,p_pharmacy,buy,(unit-buy)*requested_qty from public.products where id=pid and pharmacy_id=p_pharmacy;
  end loop;
  if total_items<=0 then raise exception 'Your cart is empty'; end if;
  total_amt := total_items + fee;
  update public.online_orders set total=total_amt,updated_at=now() where id=oid returning * into inserted;
  return inserted;
end;$function$;

-- Staff lifecycle: READY is the processing/stock-deduction/revenue point.
create or replace function public.update_online_order_status(p_order uuid,p_status text,p_rejection_reason text default null)
returns public.online_orders
language plpgsql security definer set search_path=public as $function$
declare o public.online_orders; it record; p public.products; new_status text:=lower(trim(p_status));
begin
  select * into o from public.online_orders where id=p_order and pharmacy_id=public.current_pharmacy() for update;
  if o.id is null then raise exception 'Order not found'; end if;
  if not public.has_role(array['admin','manager','pharmacist']::public.user_role[]) then raise exception 'You are not allowed to update online orders'; end if;
  if new_status not in ('pending','ready','confirmed','out_for_delivery','delivered','complete','completed','rejected','cancelled') then raise exception 'Invalid order status'; end if;
  if new_status='rejected' then
    if nullif(trim(coalesce(p_rejection_reason,'')),'') is null then raise exception 'A rejection reason is required'; end if;
    update public.online_orders set status='rejected',rejection_reason=trim(p_rejection_reason),updated_at=now() where id=p_order returning * into o;
    return o;
  end if;
  if o.status='pending' and new_status='ready' then
    for it in select * from public.online_order_items where order_id=p_order loop
      select * into p from public.products where id=it.product_id and pharmacy_id=o.pharmacy_id and not archived for update;
      if p.id is null then raise exception 'An item in this order is no longer available'; end if;
      if p.qty<it.qty then raise exception 'Insufficient stock for %',p.name; end if;
      update public.online_order_items set unit_buy=p.buy,line_profit=(unit_price-p.buy)*qty where id=it.id;
    end loop;
    for it in select * from public.online_order_items where order_id=p_order loop
      update public.products set qty=qty-it.qty where id=it.product_id and pharmacy_id=o.pharmacy_id;
    end loop;
    update public.online_orders set status='ready',updated_at=now() where id=p_order returning * into o;
    return o;
  end if;
  if o.status in ('rejected','cancelled','complete','completed') then raise exception 'This order can no longer be changed'; end if;
  if new_status='confirmed' then
    update public.online_orders set status='confirmed',confirmed_at=now(),updated_at=now() where id=p_order returning * into o;
  else
    update public.online_orders set status=case when new_status='completed' then 'complete' else new_status end,updated_at=now(),delivered_at=case when new_status='delivered' then now() else delivered_at end,completed_at=case when new_status in ('complete','completed') then now() else completed_at end where id=p_order returning * into o;
  end if;
  return o;
end;$function$;

create or replace function public.confirm_online_delivery(p_order uuid)
returns public.online_orders
language plpgsql security definer set search_path=public as $function$
declare o public.online_orders;
begin
  select * into o from public.online_orders where id=p_order and customer_id=auth.uid() for update;
  if o.id is null then raise exception 'Order not found'; end if;
  if o.status not in ('ready','out_for_delivery','delivered') then raise exception 'This order is not ready for customer confirmation'; end if;
  update public.online_orders set status='confirmed',confirmed_at=now(),updated_at=now() where id=p_order returning * into o;
  return o;
end;$function$;

-- Customer can only confirm their own order; management then sees CONFIRMED.
grant execute on function public.confirm_online_delivery(uuid) to authenticated;

-- Customer catalog now exposes both retail and wholesale prices.
drop function if exists public.get_online_catalog(uuid);
create or replace function public.get_online_catalog(p_pharmacy uuid)
returns table(id uuid,name text,brand_name text,category text,batch text,expiry date,qty integer,retail_price numeric,wholesale_price numeric)
language sql security definer set search_path=public as $$
  select p.id,p.name,coalesce(p.brand_name,''),p.category,p.batch,p.expiry,p.qty,
         coalesce(nullif(p.retail_price,0),p.sell),coalesce(nullif(p.wholesale_price,0),p.retail_price,p.sell)
  from public.products p where p.pharmacy_id=p_pharmacy and p.qty>0 and coalesce(p.archived,false)=false and p.expiry>=current_date order by p.name;
$$;
grant execute on function public.get_online_catalog(uuid) to anon,authenticated;

