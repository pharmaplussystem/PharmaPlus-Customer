-- PharmaPlus Customer Portal update
-- Run this AFTER the existing online-ordering schema in the SAME Supabase project.

alter table public.online_orders add column if not exists customer_type text not null default 'retail' check (customer_type in ('retail','wholesale'));
alter table public.online_orders add column if not exists payment_method text;
alter table public.online_orders add column if not exists mobile_network text;
alter table public.online_orders add column if not exists mobile_number text;
alter table public.online_orders add column if not exists transaction_message text;
alter table public.online_orders add column if not exists prescription_url text;
alter table public.online_orders add column if not exists latitude numeric(10,7);
alter table public.online_orders add column if not exists longitude numeric(10,7);
alter table public.online_orders add column if not exists rejection_reason text;
alter table public.online_orders add column if not exists delivered_at timestamptz;
alter table public.online_orders add column if not exists completed_at timestamptz;

-- Keep legacy statuses available, while adding the customer-facing lifecycle.
alter table public.online_orders drop constraint if exists online_orders_status_check;
alter table public.online_orders add constraint online_orders_status_check check(status in ('pending','sent','confirmed','preparing','ready','out_for_delivery','delivered','complete','completed','rejected','cancelled'));

-- Storage bucket for optional prescriptions.
insert into storage.buckets (id,name,public) values ('prescriptions','prescriptions',true) on conflict (id) do update set public=true;

drop policy if exists prescriptions_customer_insert on storage.objects;
create policy prescriptions_customer_insert on storage.objects for insert to authenticated
with check (bucket_id='prescriptions' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists prescriptions_customer_select on storage.objects;
create policy prescriptions_customer_select on storage.objects for select to authenticated
using (bucket_id='prescriptions' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists prescriptions_customer_delete on storage.objects;
create policy prescriptions_customer_delete on storage.objects for delete to authenticated
using (bucket_id='prescriptions' and (storage.foldername(name))[1]=auth.uid()::text);

-- Customer order placement. Payment message is required before the order is accepted.
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
language plpgsql security definer set search_path=public
as $function$
declare
  cid uuid; oid uuid; itm jsonb; pid uuid; requested_qty int; unit numeric; line numeric; total_amt numeric:=0; inserted public.online_orders;
begin
  if auth.uid() is null then raise exception 'You must be signed in'; end if;
  if lower(trim(coalesce(p_customer_type,'retail'))) not in ('retail','wholesale') then raise exception 'Invalid customer type'; end if;
  if lower(trim(coalesce(p_fulfillment,''))) not in ('delivery','pickup') then raise exception 'Invalid fulfillment option'; end if;
  if lower(trim(coalesce(p_payment_method,''))) not in ('mobile_money','bank','visa') then raise exception 'Select a payment method'; end if;
  if nullif(trim(coalesce(p_transaction_message,'')),'') is null then raise exception 'Payment transaction message/reference is required'; end if;
  if lower(trim(p_fulfillment))='delivery' and (p_latitude is null or p_longitude is null) then raise exception 'Live delivery location is required for home delivery'; end if;
  if lower(trim(coalesce(p_payment_method,'')))='mobile_money' and nullif(trim(coalesce(p_mobile_number,'')),'') is null then raise exception 'Mobile money number is required'; end if;

  select id into cid from public.customer_profiles where id=auth.uid() and pharmacy_id=p_pharmacy and active=true;
  if cid is null then raise exception 'Customer profile not found for this pharmacy'; end if;

  insert into public.online_orders(customer_id,pharmacy_id,status,fulfillment,delivery_address,phone,notes,total,customer_type,payment_method,mobile_network,mobile_number,transaction_message,prescription_url,latitude,longitude)
  values(cid,p_pharmacy,'pending',lower(trim(p_fulfillment)),nullif(trim(p_delivery_address),''),nullif(trim(p_phone),''),nullif(trim(p_notes),''),0,lower(trim(p_customer_type)),lower(trim(p_payment_method)),nullif(trim(p_mobile_network),''),nullif(trim(p_mobile_number),''),trim(p_transaction_message),p_prescription_url,p_latitude,p_longitude)
  returning id into oid;

  for itm in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    pid := (itm->>'product_id')::uuid; requested_qty := greatest(1,(itm->>'qty')::int);
    select case when lower(trim(p_customer_type))='wholesale' then wholesale_price else retail_price end into unit from public.products where id=pid and pharmacy_id=p_pharmacy and archived=false;
    if unit is null then raise exception 'One of the selected medicines is no longer available'; end if;
    if not exists(select 1 from public.products where id=pid and pharmacy_id=p_pharmacy and archived=false and qty>=requested_qty) then raise exception 'Insufficient stock for one of the selected medicines'; end if;
    line := unit*requested_qty; total_amt := total_amt+line;
    insert into public.online_order_items(order_id,product_id,product_name,brand_name,batch,qty,unit_price,line_total,pharmacy_id)
    select oid,id,name,brand_name,batch,requested_qty,unit,line,pharmacy_id from public.products where id=pid;
  end loop;
  if total_amt<=0 then raise exception 'Your cart is empty'; end if;
  update public.online_orders set total=total_amt,updated_at=now() where id=oid returning * into inserted;
  return inserted;
end;$function$;

-- Staff lifecycle. Moving to sent is the point at which stock is deducted.
create or replace function public.update_online_order_status(p_order uuid,p_status text,p_rejection_reason text default null)
returns public.online_orders
language plpgsql security definer set search_path=public
as $function$
declare o public.online_orders; it record; p public.products; new_status text:=lower(trim(p_status));
begin
  select * into o from public.online_orders where id=p_order and pharmacy_id=public.current_pharmacy() for update;
  if o.id is null then raise exception 'Order not found'; end if;
  if not public.has_role(array['admin','manager','pharmacist']::public.user_role[]) then raise exception 'You are not allowed to update online orders'; end if;
  if new_status not in ('pending','sent','confirmed','preparing','ready','out_for_delivery','delivered','complete','completed','rejected','cancelled') then raise exception 'Invalid order status'; end if;

  if new_status='rejected' then
    if nullif(trim(coalesce(p_rejection_reason,'')),'') is null then raise exception 'A rejection reason is required'; end if;
    update public.online_orders set status='rejected',rejection_reason=trim(p_rejection_reason),updated_at=now() where id=p_order returning * into o;
    return o;
  end if;

  if o.status='pending' and new_status in ('sent','confirmed') then
    for it in select * from public.online_order_items where order_id=p_order loop
      select * into p from public.products where id=it.product_id for update;
      if p.id is null or p.pharmacy_id<>o.pharmacy_id or p.archived then raise exception 'A medicine in this order is no longer available'; end if;
      if p.qty<it.qty then raise exception 'Insufficient stock for %',p.name; end if;
      update public.products set qty=qty-it.qty,updated_at=now() where id=p.id;
    end loop;
    update public.online_orders set status='sent',confirmed_at=coalesce(confirmed_at,now()),updated_at=now() where id=p_order returning * into o;
    return o;
  end if;

  update public.online_orders set status=case when new_status='completed' then 'complete' else new_status end,updated_at=now(),delivered_at=case when new_status='delivered' then now() else delivered_at end,completed_at=case when new_status in ('complete','completed') then now() else completed_at end where id=p_order returning * into o;
  return o;
end;$function$;

create or replace function public.confirm_online_delivery(p_order uuid)
returns public.online_orders
language plpgsql security definer set search_path=public
as $function$
declare o public.online_orders;
begin
  select * into o from public.online_orders where id=p_order and customer_id=auth.uid() for update;
  if o.id is null then raise exception 'Order not found'; end if;
  if o.status<>'delivered' then raise exception 'This order is not marked delivered yet'; end if;
  update public.online_orders set status='complete',completed_at=now(),updated_at=now() where id=p_order returning * into o;
  return o;
end;$function$;
