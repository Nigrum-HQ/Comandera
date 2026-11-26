// Entradas: lo que comparten la página de compra, la entrada, el panel y la puerta.
// Usa la misma base de Supabase que la comandera (funciones ent_*). La "publishable key" es pública.
const ENT = {
  supabaseUrl: 'https://yeldyycgkeorrlkxmayz.supabase.co',
  supabaseKey: 'sb_publishable_qa1Jc7v1OzXCX19xRryMNQ_vHSNHibW',
};

async function rpc(fn, args = {}, timeout = 15000) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeout);
  let res;
  try {
    res = await fetch(`${ENT.supabaseUrl}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: ENT.supabaseKey, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
      signal: ctrl.signal,
    });
  } catch (e) {
    throw Object.assign(new Error('Sin conexión. Revisá tu internet e intentá de nuevo.'), { offline: true });
  } finally {
    clearTimeout(timer);
  }
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (e) { /* respuesta rara */ }
  if (!res.ok) {
    const err = new Error((data && data.message) || 'Algo falló. Intentá de nuevo.');
    err.code = data && data.code;
    throw err;
  }
  return data;
}

const money = n => '$ ' + Number(n || 0).toLocaleString('es-AR');
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const TZ = { timeZone: 'America/Argentina/Buenos_Aires', hourCycle: 'h23' };
const hora = iso => new Date(iso).toLocaleTimeString('es-AR', { ...TZ, hour: '2-digit', minute: '2-digit' });
const fechaHora = iso => new Date(iso).toLocaleString('es-AR', { ...TZ, day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });

// Link personal de cada entrada (el mismo que va dentro del QR).
const linkEntrada = token => new URL('e.html?t=' + token, document.baseURI).href;

// Teléfono argentino → número para wa.me (549 + área + número, sin 0 ni 15).
function waNumero(tel) {
  let d = String(tel || '').replace(/\D/g, '');
  if (d.startsWith('00')) d = d.slice(2);
  if (d.startsWith('54')) {
    d = d.slice(2);
    if (d.startsWith('9')) d = d.slice(1);
  }
  if (d.startsWith('0')) d = d.slice(1);
  // 11 15 5555 5555 → 11 5555 5555 (el 15 va después del código de área de 2 a 4 cifras)
  if (d.length === 12) {
    for (const n of [2, 3, 4]) if (d.slice(n, n + 2) === '15') { d = d.slice(0, n) + d.slice(n + 2); break; }
  }
  return d.length === 10 ? '549' + d : '';
}

function guardado(k, v) {
  try {
    if (v === undefined) return localStorage.getItem('ent.' + k);
    if (v === null) localStorage.removeItem('ent.' + k); else localStorage.setItem('ent.' + k, v);
  } catch (e) { return null; }
}
