-- Cajas con nombre (por ejemplo "Barra 1", "Barra 2"): cada una con su PIN y sus propios totales.
-- Se aplica encima de schema.sql. El PIN de caja general (settings.pin_caja) sigue funcionando.

create table registers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  pin text,
  sort int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table registers enable row level security;
revoke all on registers from anon, authenticated;

alter table orders add column register_id uuid references registers (id);
create index orders_register on orders (register_id);

drop function _auth(text, text[]);
create function _auth(p_pin text, p_roles text[], out role text, out truck_id uuid, out register_id uuid)
language plpgsql security definer set search_path = public as $$
declare s settings;
begin
  select * into s from settings where id = 1;
  if p_pin is not null and length(p_pin) >= 4 then
    if p_pin = s.pin_admin then role := 'admin';
    elsif p_pin = s.pin_caja then role := 'caja';
    else
      select r.id into register_id from registers r where r.pin = p_pin and r.active limit 1;
      if register_id is not null then
        role := 'caja';
      else
        select t.id into truck_id from trucks t where t.pin = p_pin and t.active limit 1;
        if truck_id is not null then role := 'truck'; end if;
      end if;
    end if;
  end if;
  if role is null then
    perform pg_sleep(1); -- frena a quien intente adivinar PINs
    raise exception 'PIN incorrecto' using errcode = '28000';
  end if;
  if not role = any (p_roles) then
    raise exception 'No tenés permiso para esto' using errcode = '42501';
  end if;
end $$;

create or replace function _check_pin(p_pin text, p_kind text, p_truck uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s settings;
begin
  if p_pin is null or p_pin = '' then return; end if;
  if p_pin !~ '^[0-9]{4,8}$' then
    raise exception 'El PIN tiene que ser de 4 a 8 números';
  end if;
  select * into s from settings where id = 1;
  if (p_kind <> 'admin' and p_pin = s.pin_admin)
     or (p_kind <> 'caja' and p_pin = s.pin_caja)
     or exists (select 1 from trucks t where t.pin = p_pin and t.active
                and (p_kind <> 'truck' or t.id is distinct from p_truck))
     or exists (select 1 from registers r where r.pin = p_pin and r.active
                and (p_kind <> 'register' or r.id is distinct from p_truck)) then -- p_truck = id de lo que se edita
    raise exception 'Ese PIN ya lo usa otra persona';
  end if;
end $$;

drop function _summary(uuid, text, uuid);
create function _summary(p_day uuid, p_role text, p_truck uuid, p_register uuid default null) returns json
language sql security definer set search_path = public as $$
  with ord as (select * from orders where day_id = p_day and not voided
                 and (p_register is null or register_id = p_register)),
  it as (
    select oi.*, o.pay from order_items oi join ord o on o.id = oi.order_id
    where (p_role <> 'truck' or oi.truck_id = p_truck)
  )
  select case p_role
    when 'truck' then json_build_object(
      'units', (select coalesce(sum(qty), 0) from it),
      'pay', (select coalesce(sum(qty * cost), 0) from it),
      'orders', (select count(distinct order_id) from it),
      'products', (select coalesce(json_agg(p order by p.qty desc), '[]') from
                    (select name, sum(qty) qty, sum(qty * cost) pay from it group by name) p))
    else json_build_object(
      'count', (select count(*) from ord),
      'total', (select coalesce(sum(total), 0) from ord),
      'efectivo', (select coalesce(sum(total), 0) from ord where pay = 'efectivo'),
      'transferencia', (select coalesce(sum(total), 0) from ord where pay = 'transferencia'),
      'cost', case when p_role = 'admin' then (select coalesce(sum(qty * cost), 0) from it) end,
      'profit', case when p_role = 'admin' then (select coalesce(sum(qty * (price - cost)), 0) from it) end,
      'per', case when p_role = 'admin' then (select coalesce(json_agg(r order by r.name), '[]') from
               (select truck_id, max(truck_name) as name, sum(qty) units, sum(qty * price) sold, sum(qty * cost) pay
                from it group by truck_id) r) end,
      'products', case when p_role = 'admin' then (select coalesce(json_agg(p order by p.qty desc), '[]') from
               (select name, truck_id, max(truck_name) truck, sum(qty) qty, sum(qty * price) sold, sum(qty * cost) pay from it group by name, truck_id) p) end,
      'per_register', case when p_role = 'admin' then (select coalesce(json_agg(r order by r.name), '[]') from
               (select coalesce(g.name, 'Caja general') as name, count(*) as pedidos, sum(o.total) total,
                       coalesce(sum(o.total) filter (where o.pay = 'efectivo'), 0) efectivo,
                       coalesce(sum(o.total) filter (where o.pay = 'transferencia'), 0) transferencia
                from ord o left join registers g on g.id = o.register_id group by g.name) r) end)
  end
$$;

create or replace function login(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := _auth(p_pin, array['admin', 'caja', 'truck']);
  return json_build_object(
    'role', a.role,
    'truck_id', a.truck_id,
    'truck_name', (select name from trucks where id = a.truck_id),
    'register_id', a.register_id,
    'register_name', (select name from registers where id = a.register_id),
    'event_name', (select event_name from settings where id = 1));
end $$;

create or replace function catalog(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := _auth(p_pin, array['admin', 'caja', 'truck']);
  return json_build_object(
    'event_name', (select event_name from settings where id = 1),
    'pin_caja', case when a.role = 'admin' then (select pin_caja from settings where id = 1) end,
    'registers', case when a.role = 'admin' then (select coalesce(json_agg(json_build_object(
                 'id', r.id, 'name', r.name, 'pin', r.pin, 'sort', r.sort) order by r.sort, r.created_at), '[]')
               from registers r where r.active) end,
    'trucks', (select coalesce(json_agg(json_build_object(
                 'id', t.id, 'name', t.name, 'color', t.color, 'sort', t.sort,
                 'pin', case when a.role = 'admin' then t.pin end) order by t.sort, t.created_at), '[]')
               from trucks t where t.active and (a.role <> 'truck' or t.id = a.truck_id)),
    'products', (select coalesce(json_agg(json_build_object(
                 'id', p.id, 'truck_id', p.truck_id, 'name', p.name, 'sort', p.sort,
                 'price', case when a.role <> 'truck' then p.price end,
                 'cost', case when a.role <> 'caja' then p.cost end) order by p.sort, p.created_at), '[]')
               from products p join trucks t on t.id = p.truck_id
               where p.active and t.active and (a.role <> 'truck' or p.truck_id = a.truck_id)));
end $$;

create or replace function create_order(p_pin text, p_pay text, p_items jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  a record;
  d days;
  o orders;
  it jsonb;
  p record;
  v_num int;
  v_total int := 0;
begin
  a := _auth(p_pin, array['admin', 'caja']);
  if jsonb_array_length(coalesce(p_items, '[]')) = 0 then raise exception 'El pedido está vacío'; end if;
  d := _current_day();
  update days set next_num = next_num + 1 where id = d.id returning next_num - 1 into v_num;
  insert into orders (day_id, num, pay, total, register_id) values (d.id, v_num, p_pay, 0, a.register_id) returning * into o;
  for it in select * from jsonb_array_elements(p_items) loop
    select pr.id, pr.name, pr.price, pr.cost, t.id truck_id, t.name truck_name into p
      from products pr join trucks t on t.id = pr.truck_id
      where pr.id = (it ->> 'product_id')::uuid and pr.active and t.active;
    if not found then raise exception 'Un producto ya no existe, recargá la pantalla'; end if;
    if (it ->> 'qty')::int <= 0 then continue; end if;
    insert into order_items (order_id, product_id, truck_id, truck_name, name, qty, price, cost)
      values (o.id, p.id, p.truck_id, p.truck_name, p.name, (it ->> 'qty')::int, p.price, p.cost);
    v_total := v_total + (it ->> 'qty')::int * p.price;
  end loop;
  update orders set total = v_total where id = o.id;
  return (select row_to_json(x) from (
    select o.id, o.num, o.created_at, o.pay, v_total as total,
      (select name from registers where id = a.register_id) as register_name,
      (select json_agg(json_build_object('name', name, 'qty', qty, 'price', price,
                                         'truck_id', truck_id, 'truck_name', truck_name) order by id)
       from order_items where order_id = o.id) items) x);
end $$;

create or replace function orders_today(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare a record; d days;
begin
  a := _auth(p_pin, array['admin', 'caja', 'truck']);
  d := _current_day();
  return (select coalesce(json_agg(x order by x.num desc), '[]') from (
    select o.id, o.num, o.created_at, o.voided,
      case when a.role <> 'truck' then o.pay end as pay,
      case when a.role <> 'truck' then o.total end as total,
      (select name from registers where id = o.register_id) as register_name,
      (select json_agg(json_build_object('name', oi.name, 'qty', oi.qty, 'truck_id', oi.truck_id,
                'truck_name', oi.truck_name,
                'price', case when a.role <> 'truck' then oi.price end,
                'cost', case when a.role = 'admin' then oi.cost end) order by oi.id)
       from order_items oi where oi.order_id = o.id and (a.role <> 'truck' or oi.truck_id = a.truck_id)) items
    from orders o
    where o.day_id = d.id
      and (a.register_id is null or o.register_id = a.register_id)
      and (a.role <> 'truck' or exists (select 1 from order_items oi where oi.order_id = o.id and oi.truck_id = a.truck_id))
  ) x);
end $$;

create or replace function void_order(p_pin text, p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := _auth(p_pin, array['admin', 'caja']);
  update orders set voided = true, voided_at = now()
    where id = p_order and not voided and day_id = (_current_day()).id
      and (a.register_id is null or register_id = a.register_id);
  if not found then raise exception 'No se pudo anular ese pedido'; end if;
end $$;

create or replace function summary(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare a record; d days;
begin
  a := _auth(p_pin, array['admin', 'caja', 'truck']);
  d := _current_day();
  return json_build_object('day', json_build_object('id', d.id, 'started_at', d.started_at),
                           'summary', _summary(d.id, a.role, a.truck_id, a.register_id));
end $$;

create or replace function save_settings(p_pin text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _auth(p_pin, array['admin']);
  if p_data ? 'pin_admin' then
    if coalesce(p_data ->> 'pin_admin', '') = '' then raise exception 'El admin necesita PIN'; end if;
    perform _check_pin(p_data ->> 'pin_admin', 'admin', null);
  end if;
  if p_data ? 'pin_caja' then perform _check_pin(p_data ->> 'pin_caja', 'caja', null); end if;
  update settings set
    event_name = coalesce(nullif(trim(p_data ->> 'event_name'), ''), event_name),
    pin_admin = case when p_data ? 'pin_admin' then p_data ->> 'pin_admin' else pin_admin end,
    pin_caja = case when p_data ? 'pin_caja' then nullif(p_data ->> 'pin_caja', '') else pin_caja end
  where id = 1;
end $$;

create function save_register(p_pin text, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := (p_data ->> 'id')::uuid;
begin
  perform _auth(p_pin, array['admin']);
  if p_data ? 'pin' then perform _check_pin(p_data ->> 'pin', 'register', v_id); end if;
  if v_id is null then
    insert into registers (name, pin, sort)
      values (coalesce(nullif(trim(p_data ->> 'name'), ''), 'Caja'), nullif(p_data ->> 'pin', ''),
              coalesce((p_data ->> 'sort')::int, 0))
      returning id into v_id;
  else
    update registers set
      name = coalesce(nullif(trim(p_data ->> 'name'), ''), name),
      pin = case when p_data ? 'pin' then nullif(p_data ->> 'pin', '') else pin end
    where id = v_id and active;
    if not found then raise exception 'Esa caja no existe'; end if;
  end if;
  return v_id;
end $$;

create function delete_register(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _auth(p_pin, array['admin']);
  update registers set active = false, pin = null where id = p_id;
end $$;

revoke execute on function _auth(text, text[]),
  _summary(uuid, text, uuid, uuid) from public, anon, authenticated;
grant execute on function save_register(text, jsonb), delete_register(text, uuid) to anon;
