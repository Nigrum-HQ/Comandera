-- Entradas, versión "un QR por compra". Se aplica encima de entradas.sql.
--   * Cada compra tiene un solo link/QR con todas sus personas (nombre + DNI de cada una).
--   * En la puerta se escanea el QR, se ve la lista con los DNI y se marca quién entra.
--   * DNI obligatorio para cada persona.
--   * ent_planilla: lista de asistentes para la planilla de Google (Drive).

alter table ent_pedidos add column token text unique default replace(gen_random_uuid()::text, '-', '');
alter table ent_pedidos alter column token set not null;

-- Asistentes de un pedido, para la entrada y la puerta.
create function _ent_asistentes(p_pedido uuid) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', e.id, 'nombre', e.nombre, 'dni', e.dni, 'tipo', e.tipo,
           'ingreso_at', e.ingreso_at) order by e.num), '[]')
  from ent_entradas e where e.pedido_id = p_pedido
$$;

-- Busca el pedido por el link del QR, el token (de la compra o de una entrada vieja) o el número (SMR-005 o 5).
create function _ent_buscar(p_codigo text) returns ent_pedidos
language plpgsql stable security definer set search_path = public as $$
declare v text := btrim(coalesce(p_codigo, '')); ped ent_pedidos; v_num int;
begin
  if v ~ '[?&]t=' then v := substring(v from '[?&]t=([0-9a-fA-F]+)'); end if;
  v := lower(v);
  select * into ped from ent_pedidos where token = v;
  if found then return ped; end if;
  select p.* into ped from ent_pedidos p join ent_entradas e on e.pedido_id = p.id where e.token = v;
  if found then return ped; end if;
  if v ~ '\d' and v !~ '^[0-9a-f]{32}$' then
    v_num := nullif(regexp_replace(v, '\D', '', 'g'), '')::int;
    select * into ped from ent_pedidos where num = v_num;
  end if;
  return ped;
end $$;

-- DNI obligatorio por persona en la compra web (en la carga manual, opcional).
create or replace function _ent_crear_pedido(p jsonb, p_manual boolean) returns json
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
  v_dni text;
  k text;
begin
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'Elegí al menos una entrada.';
  end if;
  if jsonb_array_length(v_items) > 20 then raise exception 'Máximo 20 entradas por compra.'; end if;
  if length(v_nombre) < 3 then raise exception 'Poné tu nombre y apellido.'; end if;
  if not p_manual then
    if length(regexp_replace(v_tel, '\D', '', 'g')) < 8 then raise exception 'Revisá tu WhatsApp.'; end if;
    if v_email <> '' and v_email !~ '^\S+@\S+\.\S+$' then raise exception 'Revisá tu email.'; end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('ent_pedidos'));
  select * into s from ent_settings where id = 1 for update;
  if not p_manual and not s.ventas_abiertas then raise exception 'La venta de entradas está cerrada.'; end if;

  for it in select * from jsonb_array_elements(v_items) loop
    select * into t from ent_tipos where id = (it ->> 'tipo_id')::uuid and activo;
    if not found then raise exception 'Ese tipo de entrada ya no está disponible. Recargá la página.'; end if;
    if length(_ent_txt(it ->> 'nombre', 80)) < 3 then raise exception 'Poné nombre y apellido de cada persona.'; end if;
    v_dni := regexp_replace(coalesce(it ->> 'dni', ''), '\D', '', 'g');
    if not p_manual and length(v_dni) not between 6 and 9 then
      raise exception 'Revisá el DNI de %.', _ent_txt(it ->> 'nombre', 80);
    end if;
    v_total := v_total + t.precio;
    v_cant := jsonb_set(v_cant, array[t.id::text], to_jsonb(coalesce((v_cant ->> t.id::text)::int, 0) + 1));
  end loop;

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
  values (v_num, v_nombre, regexp_replace(coalesce(p ->> 'dni', ''), '\D', '', 'g'), v_tel, v_email, _ent_txt(p ->> 'vinculo', 40), v_total,
          case when p_manual then 'pagado' else 'pendiente' end, case when p_manual then now() end,
          case when p_manual then 'manual' else 'web' end, _ent_txt(p ->> 'nota', 300))
  returning * into ped;

  for it in select * from jsonb_array_elements(v_items) loop
    select * into t from ent_tipos where id = (it ->> 'tipo_id')::uuid;
    update ent_settings set next_entrada = next_entrada + 1 where id = 1 returning next_entrada - 1 into v_num;
    insert into ent_entradas (pedido_id, num, nombre, dni, tipo_id, tipo, precio)
    values (ped.id, v_num, _ent_txt(it ->> 'nombre', 80), left(regexp_replace(coalesce(it ->> 'dni', ''), '\D', '', 'g'), 12),
            t.id, t.nombre, t.precio);
  end loop;

  if v_bytes is not null then
    insert into ent_comprobantes (pedido_id, mime, data) values (ped.id, v_mime, v_bytes);
  end if;

  return json_build_object('id', ped.id, 'num', ped.num, 'codigo', _ent_codigo(ped.num), 'total', ped.total, 'estado', ped.estado);
end $$;

create or replace function ent_comprar(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare r json;
begin
  if coalesce(p ->> 'hp', '') <> '' then -- campo trampa: es un bot
    return json_build_object('num', 0, 'codigo', '', 'total', 0, 'estado', 'pendiente');
  end if;
  r := _ent_crear_pedido(p, false);
  return json_build_object('num', r ->> 'num', 'codigo', r ->> 'codigo', 'total', (r ->> 'total')::int, 'estado', r ->> 'estado');
end $$;

-- La entrada de la compra (un QR para todas las personas). Acepta también links viejos de una entrada.
create or replace function ent_entrada(p_token text) returns json
language plpgsql stable security definer set search_path = public as $$
declare ped ent_pedidos; s ent_settings;
begin
  ped := _ent_buscar_token(p_token);
  if ped.id is null then raise exception 'Esta entrada no existe. Revisá el link.'; end if;
  select * into s from ent_settings where id = 1;
  return json_build_object(
    'estado', ped.estado, 'token', ped.token,
    'codigo', _ent_codigo(ped.num),
    'comprador', ped.nombre,
    'asistentes', _ent_asistentes(ped.id),
    'club', s.club, 'titulo', s.titulo, 'bajada', s.bajada, 'fecha', s.fecha, 'hora', s.hora,
    'lugar', s.lugar, 'vestimenta', s.vestimenta, 'whatsapp', s.whatsapp);
end $$;

-- El link público solo acepta tokens (no números de pedido, que son fáciles de adivinar).
create function _ent_buscar_token(p_token text) returns ent_pedidos
language plpgsql stable security definer set search_path = public as $$
declare ped ent_pedidos; v text := lower(btrim(coalesce(p_token, '')));
begin
  if v !~ '^[0-9a-f]{32}$' then return ped; end if;
  select * into ped from ent_pedidos where token = v;
  if found then return ped; end if;
  select p.* into ped from ent_pedidos p join ent_entradas e on e.pedido_id = p.id where e.token = v;
  return ped;
end $$;

-- Puerta, paso 1: escanear. Devuelve la compra con sus personas (no marca nada todavía).
drop function ent_ingreso(text, text);
create function ent_ingreso(p_pin text, p_codigo text) returns json
language plpgsql security definer set search_path = public as $$
declare ped ent_pedidos;
begin
  perform _ent_auth(p_pin, array['admin', 'puerta']);
  ped := _ent_buscar(p_codigo);
  if ped.id is null then
    return json_build_object('resultado', 'no_existe', 'mensaje', 'Esta entrada no existe.');
  end if;
  return json_build_object(
    'resultado', case when ped.estado = 'pagado' then 'ok' else 'no_pagada' end,
    'mensaje', case ped.estado when 'pendiente' then 'El pago todavía no está verificado.'
                               when 'rechazado' then 'La compra fue rechazada.' end,
    'pedido_id', ped.id, 'codigo', _ent_codigo(ped.num), 'comprador', ped.nombre,
    'asistentes', _ent_asistentes(ped.id));
end $$;

-- Puerta, paso 2: marcar quién entra (null = todos los que faltan).
create function ent_marcar(p_pin text, p_pedido uuid, p_entradas uuid[] default null) returns json
language plpgsql security definer set search_path = public as $$
declare ped ent_pedidos; n int;
begin
  perform _ent_auth(p_pin, array['admin', 'puerta']);
  select * into ped from ent_pedidos where id = p_pedido;
  if ped.id is null then raise exception 'Esa compra no existe.'; end if;
  if ped.estado <> 'pagado' then raise exception 'Esta compra no está pagada.'; end if;
  update ent_entradas set ingreso_at = now()
    where pedido_id = p_pedido and ingreso_at is null and (p_entradas is null or id = any (p_entradas));
  get diagnostics n = row_count;
  return json_build_object('marcadas', n, 'asistentes', _ent_asistentes(p_pedido));
end $$;

create or replace function ent_admin_datos(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform _ent_auth(p_pin, array['admin']);
  return json_build_object(
    'settings', (select row_to_json(x) from (select pin_admin, pin_puerta, club, titulo, bajada, fecha, hora, lugar, vestimenta,
                   prefijo, cupo, alias, cbu, titular, whatsapp, ventas_abiertas from ent_settings where id = 1) x),
    'tipos', (select coalesce(json_agg(json_build_object('id', t.id, 'nombre', t.nombre, 'detalle', t.detalle, 'precio', t.precio,
                'cupo', t.cupo, 'activo', t.activo) order by t.sort, t.created_at), '[]') from ent_tipos t where t.activo),
    'pedidos', (select coalesce(json_agg(json_build_object(
                  'id', p.id, 'num', p.num, 'codigo', _ent_codigo(p.num), 'token', p.token, 'created_at', p.created_at,
                  'nombre', p.nombre, 'dni', p.dni, 'tel', p.tel,
                  'email', p.email, 'vinculo', p.vinculo, 'total', p.total, 'estado', p.estado, 'estado_at', p.estado_at,
                  'enviado_at', p.enviado_at, 'origen', p.origen, 'nota', p.nota,
                  'comprobante', exists (select 1 from ent_comprobantes c where c.pedido_id = p.id),
                  'entradas', (select json_agg(json_build_object('id', e.id, 'num', e.num, 'nombre', e.nombre, 'dni', e.dni,
                                 'tipo', e.tipo, 'precio', e.precio, 'ingreso_at', e.ingreso_at) order by e.num)
                               from ent_entradas e where e.pedido_id = p.id))
                order by p.num desc), '[]') from ent_pedidos p));
end $$;

-- Para la planilla de Google: una fila por persona.
create function ent_planilla(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform _ent_auth(p_pin, array['admin']);
  return (select coalesce(json_agg(json_build_object(
      'compra', _ent_codigo(p.num), 'fecha_compra', p.created_at, 'compro', p.nombre, 'whatsapp', p.tel,
      'nombre', e.nombre, 'dni', e.dni, 'tipo', e.tipo, 'precio', e.precio,
      'estado', case p.estado when 'pagado' then 'Pagado' when 'pendiente' then 'Por verificar' else 'Rechazado' end,
      'qr_enviado', p.enviado_at, 'ingreso', e.ingreso_at, 'token', p.token)
    order by p.num, e.num), '[]')
    from ent_pedidos p join ent_entradas e on e.pedido_id = p.id);
end $$;

revoke execute on function _ent_asistentes(uuid), _ent_buscar(text), _ent_buscar_token(text) from public, anon, authenticated;
revoke execute on function ent_ingreso(text, text), ent_marcar(text, uuid, uuid[]), ent_planilla(text) from public, authenticated;
grant execute on function ent_ingreso(text, text), ent_marcar(text, uuid, uuid[]), ent_planilla(text) to anon;
