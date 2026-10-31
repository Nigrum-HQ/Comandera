-- Retiros de efectivo y medios de pago por caja. Se aplica encima de schema.sql + cajas.sql.
--   * Una caja puede aceptar solo algunos medios de pago (ej. Barra 2: solo posnet).
--   * Cuando la administración retira efectivo, la caja lo registra: se descuenta del efectivo
--     que debería haber y queda el comprobante.

alter table registers add column pays text[] not null default '{efectivo,transferencia}';

create table withdrawals (
  id uuid primary key default gen_random_uuid(),
  day_id uuid not null references days (id),
  register_id uuid references registers (id),
  amount int not null check (amount > 0),
  note text,
  created_at timestamptz not null default now(),
  voided boolean not null default false
);
create index withdrawals_day on withdrawals (day_id);
alter table withdrawals enable row level security;
revoke all on withdrawals from anon, authenticated;

create or replace function _summary(p_day uuid, p_role text, p_truck uuid, p_register uuid default null) returns json
language sql security definer set search_path = public as $$
  with ord as (select * from orders where day_id = p_day and not voided
                 and (p_register is null or register_id = p_register)),
  it as (
    select oi.*, o.pay from order_items oi join ord o on o.id = oi.order_id
    where (p_role <> 'truck' or oi.truck_id = p_truck)
  ),
  ret as (select * from withdrawals where day_id = p_day and not voided
            and (p_register is null or register_id = p_register))
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
      'retiros', (select coalesce(sum(amount), 0) from ret),
      'en_caja', (select coalesce(sum(total), 0) from ord where pay = 'efectivo') - (select coalesce(sum(amount), 0) from ret),
      'cost', case when p_role = 'admin' then (select coalesce(sum(qty * cost), 0) from it) end,
      'profit', case when p_role = 'admin' then (select coalesce(sum(qty * (price - cost)), 0) from it) end,
      'per', case when p_role = 'admin' then (select coalesce(json_agg(r order by r.name), '[]') from
               (select truck_id, max(truck_name) as name, sum(qty) units, sum(qty * price) sold, sum(qty * cost) pay
                from it group by truck_id) r) end,
      'products', case when p_role = 'admin' then (select coalesce(json_agg(p order by p.qty desc), '[]') from
               (select name, truck_id, max(truck_name) truck, sum(qty) qty, sum(qty * price) sold, sum(qty * cost) pay from it group by name, truck_id) p) end,
      'per_register', case when p_role = 'admin' then (select coalesce(json_agg(r order by r.sort, r.name), '[]') from
               (select coalesce(g.name, 'Caja general') as name, min(g.sort) as sort,
                       coalesce(sum(x.pedidos), 0) as pedidos, coalesce(sum(x.total), 0) total,
                       coalesce(sum(x.efectivo), 0) efectivo, coalesce(sum(x.transferencia), 0) transferencia,
                       coalesce(sum(x.retiros), 0) retiros,
                       coalesce(sum(x.efectivo), 0) - coalesce(sum(x.retiros), 0) en_caja
                from (
                  select register_id, count(*) pedidos, sum(total) total,
                         sum(total) filter (where pay = 'efectivo') efectivo,
                         sum(total) filter (where pay = 'transferencia') transferencia, 0 retiros
                  from ord group by register_id
                  union all
                  select register_id, 0, 0, 0, 0, sum(amount) from ret group by register_id
                ) x left join registers g on g.id = x.register_id
                group by g.name) r) end)
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
    'pays', (select pays from registers where id = a.register_id),
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
    'pays', (select pays from registers where id = a.register_id),
    'registers', case when a.role = 'admin' then (select coalesce(json_agg(json_build_object(
                 'id', r.id, 'name', r.name, 'pin', r.pin, 'sort', r.sort, 'pays', r.pays) order by r.sort, r.created_at), '[]')
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
  if a.register_id is not null and not exists (select 1 from registers where id = a.register_id and p_pay = any (pays)) then
    raise exception 'Esta caja no acepta ese medio de pago';
  end if;
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

-- Retiro de efectivo: lo registra la caja (sobre su propia caja) o el admin (indicando la caja).
create function create_withdrawal(p_pin text, p_amount int, p_note text default null, p_register uuid default null) returns json
language plpgsql security definer set search_path = public as $$
declare a record; d days; w withdrawals; v_reg uuid;
begin
  a := _auth(p_pin, array['admin', 'caja']);
  v_reg := coalesce(a.register_id, case when a.role = 'admin' then p_register end);
  if p_amount is null or p_amount <= 0 then raise exception 'Poné un monto mayor a cero'; end if;
  d := _current_day();
  insert into withdrawals (day_id, register_id, amount, note) values (d.id, v_reg, p_amount, nullif(trim(p_note), ''))
    returning * into w;
  return json_build_object('id', w.id, 'amount', w.amount, 'note', w.note, 'created_at', w.created_at,
    'register_name', (select name from registers where id = v_reg),
    'en_caja', (_summary(d.id, 'caja', null, v_reg) ->> 'en_caja')::int);
end $$;

create function void_withdrawal(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := _auth(p_pin, array['admin', 'caja']);
  update withdrawals set voided = true
    where id = p_id and not voided and day_id = (_current_day()).id
      and (a.register_id is null or register_id = a.register_id);
  if not found then raise exception 'No se pudo anular ese retiro'; end if;
end $$;

create function withdrawals_today(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := _auth(p_pin, array['admin', 'caja']);
  return (select coalesce(json_agg(json_build_object(
            'id', w.id, 'amount', w.amount, 'note', w.note, 'created_at', w.created_at, 'voided', w.voided,
            'register_name', (select name from registers where id = w.register_id)) order by w.created_at desc), '[]')
          from withdrawals w
          where w.day_id = (_current_day()).id and (a.register_id is null or w.register_id = a.register_id));
end $$;

create or replace function save_register(p_pin text, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := (p_data ->> 'id')::uuid;
begin
  perform _auth(p_pin, array['admin']);
  if p_data ? 'pin' then perform _check_pin(p_data ->> 'pin', 'register', v_id); end if;
  if p_data ? 'pays' and jsonb_array_length(p_data -> 'pays') = 0 then
    raise exception 'La caja tiene que aceptar al menos un medio de pago';
  end if;
  if v_id is null then
    insert into registers (name, pin, sort)
      values (coalesce(nullif(trim(p_data ->> 'name'), ''), 'Caja'), nullif(p_data ->> 'pin', ''),
              coalesce((p_data ->> 'sort')::int, 0))
      returning id into v_id;
  else
    update registers set
      name = coalesce(nullif(trim(p_data ->> 'name'), ''), name),
      pin = case when p_data ? 'pin' then nullif(p_data ->> 'pin', '') else pin end,
      pays = case when p_data ? 'pays' then array(select jsonb_array_elements_text(p_data -> 'pays')) else pays end
    where id = v_id and active;
    if not found then raise exception 'Esa caja no existe'; end if;
  end if;
  return v_id;
end $$;

revoke execute on function create_withdrawal(text, int, text, uuid), void_withdrawal(text, uuid),
  withdrawals_today(text) from public, authenticated;
grant execute on function create_withdrawal(text, int, text, uuid), void_withdrawal(text, uuid),
  withdrawals_today(text) to anon;
