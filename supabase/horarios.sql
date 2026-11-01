-- Turnos por horario: una caja (usuario) solo puede usarse dentro de su franja, con tolerancia.
-- Se aplica encima de schema.sql + cajas.sql + retiros.sql.

alter table registers add column valid_from timestamptz;
alter table registers add column valid_until timestamptz;
alter table registers add column grace interval not null default interval '10 minutes';

create or replace function _auth(p_pin text, p_roles text[], out role text, out truck_id uuid, out register_id uuid)
language plpgsql security definer set search_path = public as $$
declare s settings; r registers;
begin
  select * into s from settings where id = 1;
  if p_pin is not null and length(p_pin) >= 4 then
    if p_pin = s.pin_admin then role := 'admin';
    elsif p_pin = s.pin_caja then role := 'caja';
    else
      select * into r from registers where pin = p_pin and active limit 1;
      if r.id is not null then
        -- fuera de su turno (más la tolerancia) el usuario no entra, y si estaba adentro lo saca
        if (r.valid_from is not null and now() < r.valid_from - r.grace)
           or (r.valid_until is not null and now() > r.valid_until + r.grace) then
          raise exception 'Tu turno es de % a %. %',
            to_char(r.valid_from at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI'),
            to_char(r.valid_until at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI'),
            case when now() > r.valid_until then 'Ya terminó: pasale la caja al equipo siguiente.'
                 else 'Todavía no empezó.' end
            using errcode = '28000';
        end if;
        register_id := r.id;
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
    'valid_until', (select valid_until from registers where id = a.register_id),
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
    'valid_until', (select valid_until from registers where id = a.register_id),
    'registers', case when a.role = 'admin' then (select coalesce(json_agg(json_build_object(
                 'id', r.id, 'name', r.name, 'pin', r.pin, 'sort', r.sort, 'pays', r.pays,
                 'valid_from', r.valid_from, 'valid_until', r.valid_until) order by r.sort, r.created_at), '[]')
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
