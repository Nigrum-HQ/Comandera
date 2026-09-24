-- Comandera: base de datos compartida (Supabase / Postgres).
-- Las tablas no son accesibles desde la app: todo pasa por funciones que
-- validan el PIN y devuelven solo lo que cada rol puede ver.
--   admin : todo (precios, costos, ganancia, PINs)
--   caja  : vender, anular, ver pedidos y totales de caja (sin costos ni ganancia)
--   truck : solo sus pedidos y lo que tiene para cobrar

create table settings (
  id int primary key default 1 check (id = 1),
  event_name text not null default 'Comandera',
  pin_admin text,
  pin_caja text
);
insert into settings (id) values (1);

create table trucks (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  color text not null default '#3b82f6',
  pin text,
  sort int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table products (
  id uuid primary key default gen_random_uuid(),
  truck_id uuid not null references trucks (id),
  name text not null,
  price int not null default 0 check (price >= 0),
  cost int not null default 0 check (cost >= 0),
  sort int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table days (
  id uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default now(),
  closed_at timestamptz,
  next_num int not null default 1
);
create unique index days_one_open on days ((closed_at is null)) where closed_at is null;

create table orders (
  id uuid primary key default gen_random_uuid(),
  day_id uuid not null references days (id),
  num int not null,
  created_at timestamptz not null default now(),
  pay text not null check (pay in ('efectivo', 'transferencia')),
  total int not null,
  voided boolean not null default false,
  voided_at timestamptz
);
create index orders_day on orders (day_id);

create table order_items (
  id bigint generated always as identity primary key,
  order_id uuid not null references orders (id) on delete cascade,
  product_id uuid references products (id),
  truck_id uuid references trucks (id),
  truck_name text not null,
  name text not null,
  qty int not null check (qty > 0),
  price int not null,
  cost int not null
);
create index order_items_order on order_items (order_id);
create index order_items_truck on order_items (truck_id);
create index products_truck on products (truck_id);

alter table settings enable row level security;
alter table trucks enable row level security;
alter table products enable row level security;
alter table days enable row level security;
alter table orders enable row level security;
alter table order_items enable row level security;
revoke all on settings, trucks, products, days, orders, order_items from anon, authenticated;

-- ---------- helpers internos ----------

create function _auth(p_pin text, p_roles text[], out role text, out truck_id uuid)
language plpgsql security definer set search_path = public as $$
declare s settings;
begin
  select * into s from settings where id = 1;
  if p_pin is not null and length(p_pin) >= 4 then
    if p_pin = s.pin_admin then role := 'admin';
    elsif p_pin = s.pin_caja then role := 'caja';
    else
      select t.id into truck_id from trucks t where t.pin = p_pin and t.active limit 1;
      if truck_id is not null then role := 'truck'; end if;
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

create function _current_day() returns days
language plpgsql security definer set search_path = public as $$
declare d days;
begin
  select * into d from days where closed_at is null;
  if not found then
    begin
      insert into days default values returning * into d;
    exception when unique_violation then
      select * into d from days where closed_at is null;
    end;
  end if;
  return d;
end $$;

create function _check_pin(p_pin text, p_kind text, p_truck uuid) returns void
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
                and (p_kind <> 'truck' or t.id is distinct from p_truck)) then
    raise exception 'Ese PIN ya lo usa otra persona';
  end if;
end $$;

create function _summary(p_day uuid, p_role text, p_truck uuid) returns json
language sql security definer set search_path = public as $$
  with it as (
    select oi.*, o.pay from order_items oi join orders o on o.id = oi.order_id
    where o.day_id = p_day and not o.voided
      and (p_role <> 'truck' or oi.truck_id = p_truck)
  ),
  ord as (select * from orders where day_id = p_day and not voided)
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
               (select name, truck_id, max(truck_name) truck, sum(qty) qty, sum(qty * price) sold, sum(qty * cost) pay from it group by name, truck_id) p) end)
  end
$$;

-- ---------- API pública ----------

create function needs_setup() returns boolean
language sql security definer set search_path = public as $$
  select pin_admin is null from settings where id = 1
$$;

create function setup_admin(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if p_pin !~ '^[0-9]{4,8}$' then raise exception 'El PIN tiene que ser de 4 a 8 números'; end if;
  update settings set pin_admin = p_pin where id = 1 and pin_admin is null;
  if not found then raise exception 'El admin ya está configurado'; end if;
  return login(p_pin);
end $$;

create function login(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := _auth(p_pin, array['admin', 'caja', 'truck']);
  return json_build_object(
    'role', a.role,
    'truck_id', a.truck_id,
    'truck_name', (select name from trucks where id = a.truck_id),
    'event_name', (select event_name from settings where id = 1));
end $$;

create function catalog(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := _auth(p_pin, array['admin', 'caja', 'truck']);
  return json_build_object(
    'event_name', (select event_name from settings where id = 1),
    'pin_caja', case when a.role = 'admin' then (select pin_caja from settings where id = 1) end,
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

create function create_order(p_pin text, p_pay text, p_items jsonb) returns json
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
  insert into orders (day_id, num, pay, total) values (d.id, v_num, p_pay, 0) returning * into o;
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
      (select json_agg(json_build_object('name', name, 'qty', qty, 'price', price,
                                         'truck_id', truck_id, 'truck_name', truck_name) order by id)
       from order_items where order_id = o.id) items) x);
end $$;

create function void_order(p_pin text, p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _auth(p_pin, array['admin', 'caja']);
  update orders set voided = true, voided_at = now()
    where id = p_order and not voided and day_id = (_current_day()).id;
  if not found then raise exception 'No se pudo anular ese pedido'; end if;
end $$;

create function orders_today(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare a record; d days;
begin
  a := _auth(p_pin, array['admin', 'caja', 'truck']);
  d := _current_day();
  return (select coalesce(json_agg(x order by x.num desc), '[]') from (
    select o.id, o.num, o.created_at, o.voided,
      case when a.role <> 'truck' then o.pay end as pay,
      case when a.role <> 'truck' then o.total end as total,
      (select json_agg(json_build_object('name', oi.name, 'qty', oi.qty, 'truck_id', oi.truck_id,
                'truck_name', oi.truck_name,
                'price', case when a.role <> 'truck' then oi.price end,
                'cost', case when a.role = 'admin' then oi.cost end) order by oi.id)
       from order_items oi where oi.order_id = o.id and (a.role <> 'truck' or oi.truck_id = a.truck_id)) items
    from orders o
    where o.day_id = d.id
      and (a.role <> 'truck' or exists (select 1 from order_items oi where oi.order_id = o.id and oi.truck_id = a.truck_id))
  ) x);
end $$;

create function summary(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare a record; d days;
begin
  a := _auth(p_pin, array['admin', 'caja', 'truck']);
  d := _current_day();
  return json_build_object('day', json_build_object('id', d.id, 'started_at', d.started_at),
                           'summary', _summary(d.id, a.role, a.truck_id));
end $$;

create function days_list(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := _auth(p_pin, array['admin', 'truck']);
  return (select coalesce(json_agg(json_build_object(
            'id', d.id, 'started_at', d.started_at, 'closed_at', d.closed_at,
            'summary', _summary(d.id, a.role, a.truck_id)) order by d.started_at desc), '[]')
          from (select * from days where closed_at is not null order by started_at desc limit 60) d);
end $$;

create function close_day(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare d days;
begin
  perform _auth(p_pin, array['admin']);
  d := _current_day();
  update days set closed_at = now() where id = d.id;
  return json_build_object('id', d.id, 'started_at', d.started_at, 'closed_at', now(),
                           'summary', _summary(d.id, 'admin', null));
end $$;

create function save_settings(p_pin text, p_data jsonb) returns void
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

create function save_truck(p_pin text, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := (p_data ->> 'id')::uuid;
begin
  perform _auth(p_pin, array['admin']);
  if p_data ? 'pin' then perform _check_pin(p_data ->> 'pin', 'truck', v_id); end if;
  if v_id is null then
    insert into trucks (name, color, pin, sort)
      values (coalesce(nullif(trim(p_data ->> 'name'), ''), 'Food truck'),
              coalesce(p_data ->> 'color', '#3b82f6'), nullif(p_data ->> 'pin', ''),
              coalesce((p_data ->> 'sort')::int, 0))
      returning id into v_id;
  else
    update trucks set
      name = coalesce(nullif(trim(p_data ->> 'name'), ''), name),
      color = coalesce(p_data ->> 'color', color),
      pin = case when p_data ? 'pin' then nullif(p_data ->> 'pin', '') else pin end,
      sort = coalesce((p_data ->> 'sort')::int, sort)
    where id = v_id and active;
    if not found then raise exception 'Ese food truck no existe'; end if;
  end if;
  return v_id;
end $$;

create function delete_truck(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _auth(p_pin, array['admin']);
  update trucks set active = false, pin = null where id = p_id;
  update products set active = false where truck_id = p_id;
end $$;

create function save_product(p_pin text, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := (p_data ->> 'id')::uuid;
begin
  perform _auth(p_pin, array['admin']);
  if v_id is null then
    insert into products (truck_id, name, price, cost, sort)
      values ((p_data ->> 'truck_id')::uuid, coalesce(nullif(trim(p_data ->> 'name'), ''), 'Producto'),
              coalesce((p_data ->> 'price')::int, 0), coalesce((p_data ->> 'cost')::int, 0),
              coalesce((p_data ->> 'sort')::int, 0))
      returning id into v_id;
  else
    update products set
      name = coalesce(nullif(trim(p_data ->> 'name'), ''), name),
      price = coalesce((p_data ->> 'price')::int, price),
      cost = coalesce((p_data ->> 'cost')::int, cost),
      sort = coalesce((p_data ->> 'sort')::int, sort)
    where id = v_id and active;
    if not found then raise exception 'Ese producto no existe'; end if;
  end if;
  return v_id;
end $$;

create function delete_product(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _auth(p_pin, array['admin']);
  update products set active = false where id = p_id;
end $$;

-- Solo las funciones públicas se pueden llamar desde la app.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  needs_setup(), setup_admin(text), login(text), catalog(text),
  create_order(text, text, jsonb), void_order(text, uuid), orders_today(text),
  summary(text), days_list(text), close_day(text), save_settings(text, jsonb),
  save_truck(text, jsonb), delete_truck(text, uuid), save_product(text, jsonb), delete_product(text, uuid)
to anon;
