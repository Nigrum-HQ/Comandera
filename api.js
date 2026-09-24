// Llamadas a la base de datos (funciones de Supabase).
const Api = (() => {
  const cfg = window.COMANDERA_CONFIG || {};

  async function rpc(fn, args = {}) {
    if (!cfg.supabaseUrl || !cfg.supabaseKey) {
      throw new Error('Falta configurar Supabase en config.js');
    }
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 12000);
    let res;
    try {
      res = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: { apikey: cfg.supabaseKey, 'Content-Type': 'application/json' },
        body: JSON.stringify(args),
        signal: ctrl.signal,
      });
    } catch (e) {
      throw Object.assign(new Error('Sin conexión a internet. Probá de nuevo.'), { offline: true });
    } finally {
      clearTimeout(timer);
    }
    const text = await res.text();
    const data = text ? JSON.parse(text) : null;
    if (!res.ok) {
      const err = new Error(data?.message || 'Error del servidor');
      err.code = data?.code;
      throw err;
    }
    return data;
  }

  return { rpc };
})();
