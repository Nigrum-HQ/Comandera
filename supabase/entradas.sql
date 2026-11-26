-- Entradas: venta de entradas nominales con QR (ej. Cena de Fin de Año SMRHC).
-- Independiente de la comandera: tablas y funciones con prefijo ent_.
--
-- Circuito:
--   1. El comprador elige entradas (Adulto, Menor…), pone el nombre de cada asistente,
--      transfiere y sube el comprobante  → pedido "pendiente".
--   2. El organizador revisa el comprobante en el panel y lo marca "pagado".
--   3. Cada asistente tiene su link con su QR (personal); el panel lo manda por WhatsApp.
--   4. En la puerta se escanea el QR: marca el ingreso y avisa si ya entró.
--
-- Como en la comandera, las tablas no se pueden leer desde la página: todo pasa por funciones
-- que validan el PIN (admin / puerta) y devuelven solo lo necesario.

create table ent_settings (
  id int primary key default 1 check (id = 1),
  pin_admin text,
  pin_puerta text,
  club text not null default 'San Miguel Rugby & Hockey Club',
  titulo text not null default 'Cena de Fin de Año',
  bajada text not null default 'Fin de temporada 2026',
  fecha text not null default '19 de diciembre',
  hora text not null default '20:30 hs',
  lugar text not null default 'Rafael 100',
  vestimenta text not null default 'Elegante sport',
  prefijo text not null default 'SMR',
  cupo int check (cupo is null or cupo >= 0),      -- total de entradas (vacío = sin límite)
  alias text not null default '',
  cbu text not null default '',
  titular text not null default '',
  whatsapp text not null default '',             -- del organizador, solo dígitos (549…)
  ventas_abiertas boolean not null default true,
  next_pedido int not null default 1,
  next_entrada int not null default 1,
  check (pin_puerta is null or pin_puerta <> pin_admin)
);
insert into ent_settings (id) values (1);

create table ent_tipos (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  detalle text not null default '',
  precio int not null default 0 check (precio >= 0),
  cupo int check (cupo is null or cupo >= 0),
  sort int not null default 0,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);
insert into ent_tipos (nombre, detalle, precio, sort) values
  ('Adulto', '', 0, 0),
  ('Menor', 'Hasta 12 años', 0, 1);

create table ent_pedidos (
  id uuid primary key default gen_random_uuid(),
  num int not null unique,
  created_at timestamptz not null default now(),
  nombre text not null,
  dni text not null default '',
  tel text not null default '',
  email text not null default '',
  vinculo text not null default '',
  total int not null,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'pagado', 'rechazado')),
  estado_at timestamptz,
  enviado_at timestamptz,                         -- cuándo se le mandaron los links por WhatsApp
  origen text not null default 'web' check (origen in ('web', 'manual')),
  nota text not null default ''
);

create table ent_comprobantes (
  pedido_id uuid primary key references ent_pedidos (id) on delete cascade,
  mime text not null,
  data bytea not null
);

create table ent_entradas (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid not null references ent_pedidos (id) on delete cascade,
  num int not null unique,
  token text not null unique default replace(gen_random_uuid()::text, '-', ''),
  nombre text not null,
  dni text not null default '',
  tipo_id uuid references ent_tipos (id),
  tipo text not null,
  precio int not null,
  ingreso_at timestamptz
);
create index ent_entradas_pedido on ent_entradas (pedido_id);

alter table ent_settings enable row level security;
alter table ent_tipos enable row level security;
alter table ent_pedidos enable row level security;
alter table ent_comprobantes enable row level security;
alter table ent_entradas enable row level security;
revoke all on ent_settings, ent_tipos, ent_pedidos, ent_comprobantes, ent_entradas from anon, authenticated;

-- ---------- internas ----------

create function _ent_auth(p_pin text, p_roles text[]) returns text
language plpgsql security definer set search_path = public as $$
declare s ent_settings; r text;
begin
  select * into s from ent_settings where id = 1;
  if p_pin is not null and length(p_pin) >= 4 then
    if p_pin = s.pin_admin then r := 'admin';
    elsif p_pin = s.pin_puerta then r := 'puerta';
    end if;
  end if;
  if r is null then
    perform pg_sleep(1); -- frena a quien intente adivinar PINs
    raise exception 'PIN incorrecto' using errcode = '28000';
  end if;
  if not r = any (p_roles) then
    raise exception 'No tenés permiso para esto' using errcode = '42501';
  end if;
  return r;
end $$;

create function _ent_txt(v text, n int) returns text
language sql immutable set search_path = public as $$ select left(btrim(regexp_replace(coalesce(v, ''), '\s+', ' ', 'g')), n) $$;

create function _ent_codigo(p_num int) returns text
language sql stable security definer set search_path = public as $$
  select (select prefijo from ent_settings where id = 1) || '-' || lpad(p_num::text, 3, '0')
$$;

-- Entradas vendidas (sin contar pedidos rechazados), en total y por tipo.
create function _ent_vendidas() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'total', (select count(*) from ent_entradas e join ent_pedidos p on p.id = e.pedido_id where p.estado <> 'rechazado'),
    'tipos', (select coalesce(json_object_agg(t.id, (select count(*) from ent_entradas e join ent_pedidos p on p.id = e.pedido_id
                                                       where p.estado <> 'rechazado' and e.tipo_id = t.id)), '{}')
              from ent_tipos t))
$$;

-- Crea el pedido con sus entradas. Lo usan la página pública (pendiente, con comprobante)
-- y el panel (carga manual, ya pagado).
create function _ent_crear_pedido(p jsonb, p_manual boolean) returns json
language plpgsql security definer set search_path = public as $$
declare
  s ent_settings;
  ped ent_pedidos;
  it jsonb;
  t ent_tipos;
  v_nombre text := _ent_txt(p ->> 'nombre', 80);
  v_tel text := _ent_txt(p ->> 'tel', 25);
  v_email text := _ent_txt(p ->> 'email', 120);
  v_items jsonb := coalesce(p -> 'entradas', '[]');
  v_total int := 0;
  v_cant jsonb := '{}';
  v_vend json;
  v_libres int;
  v_bytes bytea;
  v_mime text := p -> 'file' ->> 'type';
  v_num int;
  k text;
begin
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'Elegí al menos una entrada.';
  end if;
  if jsonb_array_length(v_items) > 20 then raise exception 'Máximo 20 entradas por pedido.'; end if;
  if length(v_nombre) < 3 then raise exception 'Poné tu nombre y apellido.'; end if;
  if not p_manual then
    if length(regexp_replace(v_tel, '\D', '', 'g')) < 8 then raise exception 'Revisá tu WhatsApp.'; end if;
    if v_email <> '' and v_email !~ '^\S+@\S+\.\S+$' then raise exception 'Revisá tu email.'; end if;
  end if;

  -- Un pedido a la vez: así el cupo y los números nunca se pisan.
  perform pg_advisory_xact_lock(hashtext('ent_pedidos'));
  select * into s from ent_settings where id = 1 for update;
  if not p_manual and not s.ventas_abiertas then raise exception 'La venta de entradas está cerrada.'; end if;

  for it in select * from jsonb_array_elements(v_items) loop
    select * into t from ent_tipos where id = (it ->> 'tipo_id')::uuid and activo;
    if not found then raise exception 'Ese tipo de entrada ya no está disponible. Recargá la página.'; end if;
    if length(_ent_txt(it ->> 'nombre', 80)) < 3 then raise exception 'Poné nombre y apellido de cada asistente.'; end if;
    v_total := v_total + t.precio;
    v_cant := jsonb_set(v_cant, array[t.id::text], to_jsonb(coalesce((v_cant ->> t.id::text)::int, 0) + 1));
  end loop;

  -- Comprobante: obligatorio en la compra web salvo que el pedido sea sin cargo.
  if not p_manual and (v_total > 0 or jsonb_typeof(p -> 'file') = 'object') then
    if coalesce(v_mime, '') !~ '^(image/(jpeg|png|webp|heic|heif)|application/pdf)$' then
      raise exception 'El comprobante tiene que ser una foto o un PDF.';
    end if;
    begin
      v_bytes := decode(p -> 'file' ->> 'data', 'base64');
    exception when others then
      raise exception 'No se pudo leer el comprobante. Probá con otra foto.';
    end;
    if v_bytes is null or length(v_bytes) = 0 or length(v_bytes) > 8 * 1024 * 1024 then
      raise exception 'El comprobante está vacío o pesa más de 8 MB.';
    end if;
  end if;

  v_vend := _ent_vendidas();
  if s.cupo is not null then
    v_libres := s.cupo - (v_vend ->> 'total')::int;
    if jsonb_array_length(v_items) > v_libres then
      raise exception '%', case when v_libres <= 0 then 'Se agotaron las entradas.'
                                when v_libres = 1 then 'Queda 1 sola entrada.'
                                else format('Quedan %s entradas.', v_libres) end;
    end if;
  end if;
  for k in select jsonb_object_keys(v_cant) loop
    select * into t from ent_tipos where id = k::uuid;
    if t.cupo is not null then
      v_libres := t.cupo - coalesce((v_vend -> 'tipos' ->> k)::int, 0);
      if (v_cant ->> k)::int > v_libres then
        raise exception '%', case when v_libres <= 0 then format('Se agotaron las entradas %s.', t.nombre)
                                  else format('Quedan %s entradas %s.', v_libres, t.nombre) end;
      end if;
    end if;
  end loop;

  update ent_settings set next_pedido = next_pedido + 1 where id = 1 returning next_pedido - 1 into v_num;
  insert into ent_pedidos (num, nombre, dni, tel, email, vinculo, total, estado, estado_at, origen, nota)
  values (v_num, v_nombre, _ent_txt(p ->> 'dni', 15), v_tel, v_email, _ent_txt(p ->> 'vinculo', 40), v_total,
          case when p_manual then 'pagado' else 'pendiente' end, case when p_manual then now() end,
          case when p_manual then 'manual' else 'web' end, _ent_txt(p ->> 'nota', 300))
  returning * into ped;

  for it in select * from jsonb_array_elements(v_items) loop
    select * into t from ent_tipos where id = (it ->> 'tipo_id')::uuid;
    update ent_settings set next_entrada = next_entrada + 1 where id = 1 returning next_entrada - 1 into v_num;
    insert into ent_entradas (pedido_id, num, nombre, dni, tipo_id, tipo, precio)
    values (ped.id, v_num, _ent_txt(it ->> 'nombre', 80), _ent_txt(it ->> 'dni', 15), t.id, t.nombre, t.precio);
  end loop;

  if v_bytes is not null then
    insert into ent_comprobantes (pedido_id, mime, data) values (ped.id, v_mime, v_bytes);
  end if;

  return json_build_object('id', ped.id, 'num', ped.num, 'total', ped.total, 'estado', ped.estado);
end $$;

-- ---------- públicas (página de compra y entrada) ----------

create function ent_info() returns json
language sql stable security definer set search_path = public as $$
  with s as (select * from ent_settings where id = 1), v as (select _ent_vendidas() j)
  select json_build_object(
    'club', s.club, 'titulo', s.titulo, 'bajada', s.bajada, 'fecha', s.fecha, 'hora', s.hora,
    'lugar', s.lugar, 'vestimenta', s.vestimenta, 'alias', s.alias, 'cbu', s.cbu, 'titular', s.titular,
    'whatsapp', s.whatsapp, 'ventas_abiertas', s.ventas_abiertas,
    'quedan', case when s.cupo is not null then greatest(s.cupo - (v.j ->> 'total')::int, 0) end,
    'tipos', (select coalesce(json_agg(json_build_object('id', t.id, 'nombre', t.nombre, 'detalle', t.detalle, 'precio', t.precio,
                'quedan', case when t.cupo is not null then greatest(t.cupo - coalesce((v.j -> 'tipos' ->> t.id::text)::int, 0), 0) end)
              order by t.sort, t.created_at), '[]') from ent_tipos t where t.activo))
  from s, v
$$;

create function ent_comprar(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare r json;
begin
  if coalesce(p ->> 'hp', '') <> '' then -- campo trampa: es un bot
    return json_build_object('num', 0, 'total', 0, 'estado', 'pendiente');
  end if;
  r := _ent_crear_pedido(p, false);
  return json_build_object('num', r ->> 'num', 'total', (r ->> 'total')::int, 'estado', r ->> 'estado');
end $$;

-- La entrada personal (link con token). Solo muestra el QR si el pedido está pagado.
create function ent_entrada(p_token text) returns json
language plpgsql stable security definer set search_path = public as $$
declare e ent_entradas; ped ent_pedidos; s ent_settings;
begin
  select * into e from ent_entradas where token = p_token;
  if not found then raise exception 'Esta entrada no existe. Revisá el link.'; end if;
  select * into ped from ent_pedidos where id = e.pedido_id;
  select * into s from ent_settings where id = 1;
  return json_build_object(
    'estado', ped.estado,
    'codigo', _ent_codigo(e.num),
    'nombre', e.nombre, 'tipo', e.tipo,
    'ingreso_at', e.ingreso_at,
    'viene_con', (select coalesce(json_agg(json_build_object('nombre', o.nombre, 'tipo', o.tipo) order by o.num), '[]')
                  from ent_entradas o where o.pedido_id = e.pedido_id and o.id <> e.id),
    'club', s.club, 'titulo', s.titulo, 'bajada', s.bajada, 'fecha', s.fecha, 'hora', s.hora,
    'lugar', s.lugar, 'vestimenta', s.vestimenta, 'whatsapp', s.whatsapp);
end $$;

-- ---------- panel y puerta (con PIN) ----------

create function ent_login(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  return json_build_object('rol', _ent_auth(p_pin, array['admin', 'puerta']));
end $$;

create function ent_resumen(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare r text;
begin
  r := _ent_auth(p_pin, array['admin', 'puerta']);
  return (select json_build_object(
    'pagadas', count(*) filter (where p.estado = 'pagado'),
    'ingresaron', count(*) filter (where p.estado = 'pagado' and e.ingreso_at is not null),
    'pendientes', count(*) filter (where p.estado = 'pendiente'),
    'cupo', (select cupo from ent_settings where id = 1),
    'recaudado', case when r = 'admin' then coalesce(sum(e.precio) filter (where p.estado = 'pagado'), 0) end,
    'a_verificar', case when r = 'admin' then coalesce(sum(e.precio) filter (where p.estado = 'pendiente'), 0) end,
    'por_tipo', case when r = 'admin' then (select coalesce(json_agg(x order by x.tipo), '[]') from (
                   select e2.tipo, count(*) filter (where p2.estado = 'pagado') pagadas,
                          count(*) filter (where p2.estado = 'pendiente') pendientes,
                          count(*) filter (where p2.estado = 'pagado' and e2.ingreso_at is not null) ingresaron
                   from ent_entradas e2 join ent_pedidos p2 on p2.id = e2.pedido_id group by e2.tipo) x) end)
  from ent_entradas e join ent_pedidos p on p.id = e.pedido_id);
end $$;

-- Control de puerta: acepta el link del QR, el token o el número (SMR-009 o 9).
create function ent_ingreso(p_pin text, p_codigo text) returns json
language plpgsql security definer set search_path = public as $$
declare e ent_entradas; ped ent_pedidos; v text := btrim(coalesce(p_codigo, '')); v_num int;
begin
  perform _ent_auth(p_pin, array['admin', 'puerta']);
  if v ~ '[?&]t=' then v := substring(v from '[?&]t=([0-9a-fA-F]+)'); end if;
  select * into e from ent_entradas where token = lower(v);
  if not found and v ~ '\d' and v !~ '^[0-9a-fA-F]{32}$' then
    v_num := nullif(regexp_replace(v, '\D', '', 'g'), '')::int;
    select * into e from ent_entradas where num = v_num;
  end if;
  if e.id is null then
    return json_build_object('resultado', 'no_existe', 'mensaje', 'Esta entrada no existe.');
  end if;
  select * into ped from ent_pedidos where id = e.pedido_id;
  if ped.estado <> 'pagado' then
    return json_build_object('resultado', 'no_pagada', 'codigo', _ent_codigo(e.num), 'nombre', e.nombre, 'tipo', e.tipo,
      'mensaje', case ped.estado when 'pendiente' then 'El pago todavía no está verificado.' else 'El pedido fue rechazado.' end);
  end if;
  if e.ingreso_at is not null then
    return json_build_object('resultado', 'ya_ingreso', 'codigo', _ent_codigo(e.num), 'nombre', e.nombre, 'tipo', e.tipo,
      'ingreso_at', e.ingreso_at, 'mensaje', 'Esta entrada ya se usó.');
  end if;
  update ent_entradas set ingreso_at = now() where id = e.id and ingreso_at is null returning * into e;
  if not found then -- otro celular la marcó en el mismo instante
    return json_build_object('resultado', 'ya_ingreso', 'nombre', e.nombre, 'mensaje', 'Esta entrada ya se usó.');
  end if;
  return json_build_object('resultado', 'ok', 'codigo', _ent_codigo(e.num), 'nombre', e.nombre, 'tipo', e.tipo,
    'ingreso_at', e.ingreso_at);
end $$;

create function ent_admin_datos(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform _ent_auth(p_pin, array['admin']);
  return json_build_object(
    'settings', (select row_to_json(x) from (select pin_admin, pin_puerta, club, titulo, bajada, fecha, hora, lugar, vestimenta,
                   prefijo, cupo, alias, cbu, titular, whatsapp, ventas_abiertas from ent_settings where id = 1) x),
    'tipos', (select coalesce(json_agg(json_build_object('id', t.id, 'nombre', t.nombre, 'detalle', t.detalle, 'precio', t.precio,
                'cupo', t.cupo, 'activo', t.activo) order by t.sort, t.created_at), '[]') from ent_tipos t where t.activo),
    'pedidos', (select coalesce(json_agg(json_build_object(
                  'id', p.id, 'num', p.num, 'created_at', p.created_at, 'nombre', p.nombre, 'dni', p.dni, 'tel', p.tel,
                  'email', p.email, 'vinculo', p.vinculo, 'total', p.total, 'estado', p.estado, 'estado_at', p.estado_at,
                  'enviado_at', p.enviado_at, 'origen', p.origen, 'nota', p.nota,
                  'comprobante', exists (select 1 from ent_comprobantes c where c.pedido_id = p.id),
                  'entradas', (select json_agg(json_build_object('id', e.id, 'num', e.num, 'codigo', _ent_codigo(e.num),
                                 'token', e.token, 'nombre', e.nombre, 'dni', e.dni, 'tipo', e.tipo, 'precio', e.precio,
                                 'ingreso_at', e.ingreso_at) order by e.num)
                               from ent_entradas e where e.pedido_id = p.id))
                order by p.num desc), '[]') from ent_pedidos p));
end $$;

create function ent_admin_comprobante(p_pin text, p_pedido uuid) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform _ent_auth(p_pin, array['admin']);
  return (select json_build_object('mime', mime, 'data', encode(data, 'base64')) from ent_comprobantes where pedido_id = p_pedido);
end $$;

create function ent_admin_estado(p_pin text, p_pedido uuid, p_estado text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _ent_auth(p_pin, array['admin']);
  if p_estado not in ('pendiente', 'pagado', 'rechazado') then raise exception 'Estado inválido'; end if;
  update ent_pedidos set estado = p_estado, estado_at = now() where id = p_pedido;
  if not found then raise exception 'Ese pedido no existe'; end if;
end $$;

create function ent_admin_enviado(p_pin text, p_pedido uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _ent_auth(p_pin, array['admin']);
  update ent_pedidos set enviado_at = now() where id = p_pedido;
end $$;

create function ent_admin_nota(p_pin text, p_pedido uuid, p_nota text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _ent_auth(p_pin, array['admin']);
  update ent_pedidos set nota = _ent_txt(p_nota, 300) where id = p_pedido;
end $$;

create function ent_admin_cargar(p_pin text, p jsonb) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform _ent_auth(p_pin, array['admin']);
  return _ent_crear_pedido(p, true);
end $$;

-- Corregir el nombre o DNI de un asistente (el QR y el link no cambian).
create function ent_admin_entrada(p_pin text, p_entrada uuid, p_nombre text, p_dni text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _ent_auth(p_pin, array['admin']);
  if length(_ent_txt(p_nombre, 80)) < 3 then raise exception 'Poné nombre y apellido.'; end if;
  update ent_entradas set nombre = _ent_txt(p_nombre, 80), dni = _ent_txt(p_dni, 15) where id = p_entrada;
end $$;

create function ent_admin_deshacer_ingreso(p_pin text, p_entrada uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _ent_auth(p_pin, array['admin']);
  update ent_entradas set ingreso_at = null where id = p_entrada;
end $$;

create function ent_admin_guardar(p_pin text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _ent_auth(p_pin, array['admin']);
  if p ? 'pin_admin' and length(coalesce(p ->> 'pin_admin', '')) < 4 then raise exception 'El PIN de admin tiene que tener al menos 4 números.'; end if;
  if p ? 'pin_puerta' and p ->> 'pin_puerta' is not null and p ->> 'pin_puerta' <> '' and length(p ->> 'pin_puerta') < 4 then
    raise exception 'El PIN de puerta tiene que tener al menos 4 números.';
  end if;
  update ent_settings set
    pin_admin = coalesce(nullif(p ->> 'pin_admin', ''), pin_admin),
    pin_puerta = case when p ? 'pin_puerta' then nullif(p ->> 'pin_puerta', '') else pin_puerta end,
    club = case when p ? 'club' then _ent_txt(p ->> 'club', 80) else club end,
    titulo = case when p ? 'titulo' then _ent_txt(p ->> 'titulo', 60) else titulo end,
    bajada = case when p ? 'bajada' then _ent_txt(p ->> 'bajada', 60) else bajada end,
    fecha = case when p ? 'fecha' then _ent_txt(p ->> 'fecha', 40) else fecha end,
    hora = case when p ? 'hora' then _ent_txt(p ->> 'hora', 20) else hora end,
    lugar = case when p ? 'lugar' then _ent_txt(p ->> 'lugar', 60) else lugar end,
    vestimenta = case when p ? 'vestimenta' then _ent_txt(p ->> 'vestimenta', 40) else vestimenta end,
    prefijo = case when p ? 'prefijo' and _ent_txt(p ->> 'prefijo', 6) <> '' then upper(_ent_txt(p ->> 'prefijo', 6)) else prefijo end,
    cupo = case when p ? 'cupo' then nullif(p ->> 'cupo', '')::int else cupo end,
    alias = case when p ? 'alias' then _ent_txt(p ->> 'alias', 60) else alias end,
    cbu = case when p ? 'cbu' then _ent_txt(p ->> 'cbu', 30) else cbu end,
    titular = case when p ? 'titular' then _ent_txt(p ->> 'titular', 80) else titular end,
    whatsapp = case when p ? 'whatsapp' then regexp_replace(coalesce(p ->> 'whatsapp', ''), '\D', '', 'g') else whatsapp end,
    ventas_abiertas = coalesce((p ->> 'ventas_abiertas')::boolean, ventas_abiertas)
  where id = 1;
exception when check_violation then
  raise exception 'El PIN de puerta tiene que ser distinto al de admin.';
end $$;

create function ent_admin_tipo(p_pin text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid;
begin
  perform _ent_auth(p_pin, array['admin']);
  if v_id is null then
    insert into ent_tipos (nombre, detalle, precio, cupo, sort)
    values (coalesce(nullif(_ent_txt(p ->> 'nombre', 30), ''), 'Entrada'), _ent_txt(p ->> 'detalle', 60),
            coalesce((p ->> 'precio')::int, 0), nullif(p ->> 'cupo', '')::int,
            coalesce((select max(sort) + 1 from ent_tipos), 0))
    returning id into v_id;
  else
    update ent_tipos set
      nombre = case when p ? 'nombre' and _ent_txt(p ->> 'nombre', 30) <> '' then _ent_txt(p ->> 'nombre', 30) else nombre end,
      detalle = case when p ? 'detalle' then _ent_txt(p ->> 'detalle', 60) else detalle end,
      precio = case when p ? 'precio' then (p ->> 'precio')::int else precio end,
      cupo = case when p ? 'cupo' then nullif(p ->> 'cupo', '')::int else cupo end,
      activo = coalesce((p ->> 'activo')::boolean, activo)
    where id = v_id;
    if not found then raise exception 'Ese tipo de entrada no existe'; end if;
  end if;
  return v_id;
end $$;

-- Solo estas funciones se pueden llamar desde la página.
revoke execute on function _ent_auth(text, text[]), _ent_txt(text, int), _ent_codigo(int), _ent_vendidas(),
  _ent_crear_pedido(jsonb, boolean) from public, anon, authenticated;
revoke execute on function ent_info(), ent_comprar(jsonb), ent_entrada(text), ent_login(text), ent_resumen(text),
  ent_ingreso(text, text), ent_admin_datos(text), ent_admin_comprobante(text, uuid), ent_admin_estado(text, uuid, text),
  ent_admin_enviado(text, uuid), ent_admin_nota(text, uuid, text), ent_admin_cargar(text, jsonb),
  ent_admin_entrada(text, uuid, text, text), ent_admin_deshacer_ingreso(text, uuid), ent_admin_guardar(text, jsonb),
  ent_admin_tipo(text, jsonb) from public, authenticated;
grant execute on function ent_info(), ent_comprar(jsonb), ent_entrada(text), ent_login(text), ent_resumen(text),
  ent_ingreso(text, text), ent_admin_datos(text), ent_admin_comprobante(text, uuid), ent_admin_estado(text, uuid, text),
  ent_admin_enviado(text, uuid), ent_admin_nota(text, uuid, text), ent_admin_cargar(text, jsonb),
  ent_admin_entrada(text, uuid, text, text), ent_admin_deshacer_ingreso(text, uuid), ent_admin_guardar(text, jsonb),
  ent_admin_tipo(text, jsonb) to anon;
