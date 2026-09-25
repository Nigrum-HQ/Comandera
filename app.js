// Comandera: caja unificada para varios food trucks.
// Tres pantallas según el PIN: caja (vende), admin (precios, productos, ganancia en vivo)
// y food truck (sus pedidos y lo que tiene para cobrar). Los datos viven en Supabase.

const SESSION_KEY = 'comandera.session';
const DEVICE_KEY = 'comandera.device';
const CATALOG_KEY = 'comandera.catalog';
const COLORS = ['#ef4444', '#3b82f6', '#10b981', '#f59e0b', '#8b5cf6', '#ec4899', '#14b8a6', '#f97316'];
const POLL_MS = 5000;

const $ = s => document.querySelector(s);
const money = n => Math.round(n || 0).toLocaleString('es-AR');
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmtTime = ts => new Date(ts).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit', hour12: false });
const fmtDate = ts => new Date(ts).toLocaleDateString('es-AR');

function readJson(key, fallback) {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
}
const writeJson = (key, v) => localStorage.setItem(key, JSON.stringify(v));

let session = readJson(SESSION_KEY, null); // {pin, role, truck_id, truck_name}
let device = { mode: 'ble', width: 32, customer: true, cutter: false, ...readJson(DEVICE_KEY, {}) };
let catalog = readJson(CATALOG_KEY, { event_name: 'Comandera', trucks: [], products: [] });
let cart = {}; // productId -> cantidad
let filter = 'all';
let currentView = null;
let busy = false;

const truckById = id => catalog.trucks.find(t => t.id === id);
const truckColor = id => truckById(id)?.color || '#9ca3af';

function toast(msg, ms = 2500) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => t.classList.add('hidden'), ms);
}

// Llamada con el PIN de la sesión. Si el PIN dejó de valer (lo cambió el admin), vuelve al ingreso.
async function call(fn, args = {}) {
  try {
    return await Api.rpc(fn, { p_pin: session.pin, ...args });
  } catch (e) {
    if (e.code === '28000') { logout(); toast('Tu PIN cambió, ingresá de nuevo'); }
    throw e;
  }
}

// ---------- Ingreso ----------
const VIEWS = {
  caja: [['vender', '🍔', 'Vender'], ['pedidos', '📋', 'Pedidos'], ['ajustes', '🖨️', 'Impresora']],
  admin: [['vivo', '📈', 'En vivo'], ['vender', '🛒', 'Vender'], ['pedidos', '📋', 'Pedidos'], ['productos', '🍔', 'Productos'], ['ajustes', '⚙️', 'Ajustes']],
  truck: [['truck', '🚚', 'Mi día'], ['truckhist', '📅', 'Historial']],
};
const ROLE_LABEL = { caja: 'Caja', admin: 'Administrador' };

let pin = '';
let setupMode = false;

function renderPin() {
  $('#pin-dots').innerHTML = pin.split('').map(() => '<span class="dot"></span>').join('') || '<span class="hint">····</span>';
}

document.querySelectorAll('.keypad button').forEach(b => b.addEventListener('click', async () => {
  const k = b.dataset.k;
  if (k === 'del') pin = pin.slice(0, -1);
  else if (k === 'ok') return submitPin();
  else if (pin.length < 8) pin += k;
  renderPin();
}));

async function submitPin() {
  if (pin.length < 4) return toast('El PIN tiene al menos 4 números');
  if (busy) return;
  busy = true;
  try {
    const r = await Api.rpc(setupMode ? 'setup_admin' : 'login', { p_pin: pin });
    session = { pin, role: r.role, truck_id: r.truck_id, truck_name: r.truck_name };
    writeJson(SESSION_KEY, session);
    pin = '';
    await startApp();
  } catch (e) {
    toast(e.message);
    pin = '';
    renderPin();
  } finally {
    busy = false;
  }
}

async function showLogin() {
  $('#login').classList.remove('hidden');
  $('#app').classList.add('hidden');
  $('#nav').classList.add('hidden');
  $('#btn-logout').classList.add('hidden');
  $('#btn-printer').classList.add('hidden');
  $('#role-label').textContent = '';
  pin = '';
  renderPin();
  try {
    setupMode = await Api.rpc('needs_setup');
  } catch (e) {
    setupMode = false;
    $('#login-hint').textContent = e.message;
  }
  $('#login-title').textContent = setupMode ? 'Primera vez: elegí el PIN del admin' : 'Ingresá tu PIN';
  if (setupMode) $('#login-hint').textContent = 'De 4 a 8 números. Con este PIN vas a cargar productos, precios y ver la ganancia.';
  else if (!$('#login-hint').textContent) $('#login-hint').textContent = 'Caja, admin o food truck: cada uno tiene su PIN.';
}

function logout() {
  session = null;
  localStorage.removeItem(SESSION_KEY);
  cart = {};
  $('#cart-sheet').classList.add('hidden');
  showLogin();
}

$('#btn-logout').onclick = () => { if (confirm('¿Salir de esta pantalla?')) logout(); };

async function startApp() {
  $('#login').classList.add('hidden');
  $('#app').classList.remove('hidden');
  $('#nav').classList.remove('hidden');
  $('#btn-logout').classList.remove('hidden');
  $('#role-label').textContent = session.role === 'truck' ? session.truck_name : ROLE_LABEL[session.role];
  $('#admin-settings').classList.toggle('hidden', session.role !== 'admin');
  $('#nav').innerHTML = VIEWS[session.role].map(([v, icon, label]) =>
    `<button data-view="${v}">${icon}<span>${label}</span></button>`).join('');
  $('#nav').querySelectorAll('button').forEach(b => b.onclick = () => show(b.dataset.view));
  renderHeader();
  await loadCatalog();
  show(VIEWS[session.role][0][0]);
}

async function loadCatalog() {
  try {
    catalog = await call('catalog');
    writeJson(CATALOG_KEY, catalog);
  } catch (e) {
    if (!e.code) toast(e.message);
  }
  renderHeader();
}

function renderHeader() {
  $('#event-title').textContent = catalog.event_name || 'Comandera';
  const prints = session && session.role !== 'truck' && device.mode === 'ble';
  $('#btn-printer').classList.toggle('hidden', !prints);
}

function show(view) {
  currentView = view;
  document.querySelectorAll('.view').forEach(v => v.classList.toggle('active', v.id === 'view-' + view));
  $('#nav').querySelectorAll('button').forEach(b => b.classList.toggle('active', b.dataset.view === view));
  refresh();
}

async function refresh() {
  const fn = {
    vender: renderVender, pedidos: loadPedidos, vivo: loadVivo, productos: renderProductos,
    truck: loadTruck, truckhist: loadTruckHistory, ajustes: renderAjustes,
  }[currentView];
  if (fn) await fn();
}

// Refresco automático de las pantallas "en vivo".
setInterval(() => {
  if (!session || document.visibilityState !== 'visible') return;
  if (['vivo', 'pedidos', 'truck'].includes(currentView)) refresh();
  else if (currentView === 'vender' && !Object.keys(cart).length) loadCatalog().then(renderVender);
}, POLL_MS);
document.addEventListener('visibilitychange', () => { if (session && document.visibilityState === 'visible') refresh(); });

// ---------- Vender ----------
function renderVender() {
  $('#truck-filter').innerHTML = [{ id: 'all', name: 'Todos', color: '#374151' }, ...catalog.trucks]
    .map(t => `<button class="chip ${filter === t.id ? 'on' : ''}" data-f="${t.id}" style="--c:${t.color}">${esc(t.name)}</button>`).join('');
  $('#truck-filter').querySelectorAll('button').forEach(b => b.onclick = () => { filter = b.dataset.f; renderVender(); });

  const prods = catalog.products.filter(p => truckById(p.truck_id) && (filter === 'all' || p.truck_id === filter));
  $('#products').innerHTML = prods.length ? prods.map(p => {
    const q = cart[p.id] || 0;
    return `<button class="product" data-id="${p.id}" style="--c:${truckColor(p.truck_id)}">
      ${q ? `<span class="qty">${q}</span>` : ''}
      <span class="pname">${esc(p.name)}</span>
      <span class="ptruck">${esc(truckById(p.truck_id).name)}</span>
      <span class="pprice">$${money(p.price)}</span>
    </button>`;
  }).join('') : `<p class="hint">No hay productos cargados.${session.role === 'admin' ? ' Cargalos en 🍔 Productos.' : ' Pedile al admin que los cargue.'}</p>`;
  $('#products').querySelectorAll('.product').forEach(b => b.onclick = () => {
    cart[b.dataset.id] = (cart[b.dataset.id] || 0) + 1;
    if (navigator.vibrate) navigator.vibrate(20);
    renderVender();
  });
  renderCart();
}

function cartLines() {
  return Object.entries(cart).map(([id, qty]) => ({ p: catalog.products.find(p => p.id === id), qty }))
    .filter(l => l.p && l.qty > 0);
}

function renderCart() {
  const lines = cartLines();
  const total = lines.reduce((s, l) => s + l.qty * l.p.price, 0);
  const count = lines.reduce((s, l) => s + l.qty, 0);
  $('#cart-count').textContent = count;
  $('#cart-total').textContent = $('#cart-total2').textContent = money(total);
  $('#cart-bar').classList.toggle('empty', count === 0);
  $('#cart-items').innerHTML = lines.map(l => `
    <div class="cart-line" style="--c:${truckColor(l.p.truck_id)}">
      <div><b>${esc(l.p.name)}</b><small>${esc(truckById(l.p.truck_id)?.name)} · $${money(l.p.price)}</small></div>
      <div class="stepper">
        <button data-d="-1" data-id="${l.p.id}">−</button><span>${l.qty}</span><button data-d="1" data-id="${l.p.id}">+</button>
      </div>
    </div>`).join('') || '<p class="hint">Vacío</p>';
  $('#cart-items').querySelectorAll('button').forEach(b => b.onclick = () => {
    const n = Math.max(0, (cart[b.dataset.id] || 0) + Number(b.dataset.d));
    if (n) cart[b.dataset.id] = n; else delete cart[b.dataset.id];
    renderVender();
  });
}

$('#btn-cart').onclick = () => { if (cartLines().length) $('#cart-sheet').classList.remove('hidden'); };
$('#btn-clear').onclick = () => { cart = {}; $('#cart-sheet').classList.add('hidden'); renderVender(); };
document.querySelectorAll('[data-close]').forEach(b => b.addEventListener('click', () => $('#' + b.dataset.close).classList.add('hidden')));

$('#btn-cobrar').onclick = async () => {
  const lines = cartLines();
  if (!lines.length || busy) return;
  busy = true;
  $('#btn-cobrar').disabled = true;
  $('#btn-cobrar').textContent = 'Cobrando…';
  try {
    const order = await call('create_order', {
      p_pay: document.querySelector('input[name=pay]:checked').value,
      p_items: lines.map(l => ({ product_id: l.p.id, qty: l.qty })),
    });
    cart = {};
    $('#cart-sheet').classList.add('hidden');
    document.querySelector('input[name=pay][value=efectivo]').checked = true;
    renderVender();
    toast(`Pedido #${order.num} cobrado · $${money(order.total)}`);
    await printOrder(order);
  } catch (e) {
    toast('⚠️ No se cobró: ' + e.message, 5000);
    loadCatalog().then(renderVender);
  } finally {
    busy = false;
    $('#btn-cobrar').disabled = false;
    $('#btn-cobrar').textContent = 'Cobrar e imprimir';
  }
};

// ---------- Tickets ----------
function pad(left, right, width) {
  const w = Number(width);
  left = String(left);
  right = String(right);
  const space = w - right.length - 1;
  if (left.length > space) left = left.slice(0, space);
  return left + ' '.repeat(w - left.length - right.length) + right;
}

const groupByTruck = items => [...new Set(items.map(i => i.truck_id))];

function truckTicket(order, truckId) {
  const items = order.items.filter(i => i.truck_id === truckId);
  return [
    { text: catalog.event_name, center: true },
    { text: items[0].truck_name, big: true, center: true },
    { text: `PEDIDO #${order.num}`, big: true, center: true },
    { text: `${fmtDate(order.created_at)} ${fmtTime(order.created_at)}`, center: true },
    { sep: true },
    ...items.map(i => ({ text: `${i.qty} x ${i.name}`, big: true })),
    { sep: true },
    { text: 'ENTREGAR ESTE TICKET', bold: true, center: true },
    { text: `AL FOOD TRUCK ${items[0].truck_name.toUpperCase()}`, bold: true, center: true },
    { cut: true },
  ];
}

function customerTicket(order) {
  const w = device.width;
  return [
    { text: catalog.event_name, bold: true, center: true },
    { text: `PEDIDO #${order.num}`, big: true, center: true },
    { text: `${fmtDate(order.created_at)} ${fmtTime(order.created_at)}`, center: true },
    { sep: true },
    ...groupByTruck(order.items).flatMap(tid => {
      const items = order.items.filter(i => i.truck_id === tid);
      return [
        { text: items[0].truck_name.toUpperCase(), bold: true },
        ...items.map(i => ({ text: pad(`${i.qty} x ${i.name}`, '$' + money(i.qty * i.price), w) })),
      ];
    }),
    { sep: true },
    { text: pad('TOTAL', '$' + money(order.total), w / 2), big: true },
    { text: order.pay === 'efectivo' ? 'Pago: efectivo' : 'Pago: transferencia/QR' },
    { text: 'Retira en cada food truck con este numero', center: true },
    { text: 'No valido como factura', center: true },
    { cut: true },
  ];
}

async function doPrint(lines) {
  try {
    await Printer.print(lines, device);
  } catch (e) {
    toast('⚠️ No se pudo imprimir: ' + e.message, 5000);
  }
}

function printOrder(order) {
  const lines = [
    ...(device.customer ? customerTicket(order) : []),
    ...groupByTruck(order.items).flatMap(t => truckTicket(order, t)),
  ];
  return doPrint(lines);
}

// ---------- Pedidos del día (caja y admin) ----------
async function loadPedidos() {
  let orders, sum;
  try {
    [orders, sum] = await Promise.all([call('orders_today'), call('summary')]);
  } catch (e) { return toast(e.message); }
  const s = sum.summary;
  $('#caja-summary').innerHTML = `
    <div class="cards">
      <div class="card"><small>Pedidos</small><b>${s.count}</b></div>
      <div class="card"><small>Total cobrado</small><b>$${money(s.total)}</b></div>
      <div class="card"><small>💵 Efectivo en caja</small><b>$${money(s.efectivo)}</b></div>
      <div class="card"><small>📱 Transferencias</small><b>$${money(s.transferencia)}</b></div>
    </div>`;
  // no re-dibujar si el usuario tiene un pedido abierto
  const open = [...document.querySelectorAll('#order-list details[open]')].map(d => d.dataset.id);
  $('#order-list').innerHTML = orders.map(o => `
    <details class="order ${o.voided ? 'voided' : ''}" data-id="${o.id}" ${open.includes(o.id) ? 'open' : ''}>
      <summary><b>#${o.num}</b> ${fmtTime(o.created_at)} · $${money(o.total)} · ${o.pay === 'efectivo' ? '💵' : '📱'} ${o.voided ? '<em>ANULADO</em>' : ''}</summary>
      <ul>${o.items.map(i => `<li>${i.qty} x ${esc(i.name)} <small>(${esc(i.truck_name)})</small></li>`).join('')}</ul>
      ${o.voided ? '' : `<div class="row"><button data-reprint="${o.id}" class="secondary">Reimprimir</button><button data-void="${o.id}" class="danger">Anular</button></div>`}
    </details>`).join('') || '<p class="hint">Todavía no hay pedidos hoy.</p>';
  $('#order-list').querySelectorAll('[data-void]').forEach(b => b.onclick = async () => {
    const o = orders.find(x => x.id === b.dataset.void);
    if (!confirm(`¿Anular el pedido #${o.num}? Devolvé $${money(o.total)} al cliente.`)) return;
    try { await call('void_order', { p_order: o.id }); toast(`Pedido #${o.num} anulado`); loadPedidos(); } catch (e) { toast(e.message); }
  });
  $('#order-list').querySelectorAll('[data-reprint]').forEach(b => b.onclick = () => printOrder(orders.find(x => x.id === b.dataset.reprint)));
}

// ---------- En vivo (admin) ----------
let lastSummary = null;

function adminSummaryHtml(s) {
  const per = catalog.trucks.map(t => s.per.find(r => r.truck_id === t.id) || { truck_id: t.id, name: t.name, units: 0, sold: 0, pay: 0 });
  for (const r of s.per) if (!per.some(x => x.truck_id === r.truck_id)) per.push(r); // trucks borrados con ventas
  const max = Math.max(1, ...per.map(r => r.sold));
  return `
    <div class="cards">
      <div class="card"><small>Vendido</small><b>$${money(s.total)}</b></div>
      <div class="card profit"><small>Tu ganancia</small><b>$${money(s.profit)}</b></div>
      <div class="card"><small>A pagar a trucks</small><b>$${money(s.cost)}</b></div>
      <div class="card"><small>Pedidos</small><b>${s.count}</b></div>
      <div class="card"><small>💵 Efectivo</small><b>$${money(s.efectivo)}</b></div>
      <div class="card"><small>📱 Transferencia</small><b>$${money(s.transferencia)}</b></div>
    </div>
    <h3>Por food truck</h3>
    ${per.map(r => `
      <div class="truck-row" style="--c:${truckColor(r.truck_id)}">
        <div class="truck-row-head"><b>${esc(r.name)}</b><span>${r.units} u.</span></div>
        <div class="bar"><span style="width:${(r.sold / max) * 100}%"></span></div>
        <div class="truck-row-nums"><span>Vendió $${money(r.sold)}</span><span>Pagarle <b>$${money(r.pay)}</b></span><span>Ganancia $${money(r.sold - r.pay)}</span></div>
      </div>`).join('')}
    ${s.products.length ? `<h3>Lo más vendido</h3>
    <table>
      <tr><th>Producto</th><th>Cant.</th><th>Vendido</th></tr>
      ${s.products.slice(0, 15).map(p => `<tr><td>${esc(p.name)} <small class="hint">${esc(p.truck)}</small></td><td>${p.qty}</td><td>$${money(p.sold)}</td></tr>`).join('')}
    </table>` : ''}`;
}

async function loadVivo() {
  let sum;
  try { sum = await call('summary'); } catch (e) { return toast(e.message); }
  lastSummary = sum;
  $('#vivo-since').textContent = `desde ${fmtDate(sum.day.started_at)} ${fmtTime(sum.day.started_at)} · actualizado ${fmtTime(Date.now())}`;
  $('#vivo-summary').innerHTML = adminSummaryHtml(sum.summary);
  if (!loadVivo.historyLoaded) loadHistory();
}

async function loadHistory() {
  loadVivo.historyLoaded = true;
  try {
    const days = await call('days_list');
    $('#history').innerHTML = days.map(d => `
      <details class="order"><summary>${fmtDate(d.started_at)} ${fmtTime(d.started_at)} → ${fmtTime(d.closed_at)} · $${money(d.summary.total)} · ganancia <b>$${money(d.summary.profit)}</b></summary>
      <table>
        <tr><th>Food truck</th><th>Vendido</th><th>Pagado</th></tr>
        ${d.summary.per.map(r => `<tr><td>${esc(r.name)}</td><td>$${money(r.sold)}</td><td>$${money(r.pay)}</td></tr>`).join('')}
      </table></details>`).join('') || '<p class="hint">Sin días cerrados.</p>';
  } catch (e) { toast(e.message); }
}

function cierreTicket(sum) {
  const s = sum.summary;
  const w = device.width;
  return [
    { text: catalog.event_name, bold: true, center: true },
    { text: 'CIERRE DE CAJA', big: true, center: true },
    { text: `${fmtDate(sum.day.started_at)} ${fmtTime(sum.day.started_at)} a ${fmtTime(sum.day.closed_at || Date.now())}`, center: true },
    { sep: true },
    ...s.per.flatMap(r => [
      { text: r.name.toUpperCase(), bold: true },
      { text: pad('  Vendido', '$' + money(r.sold), w) },
      { text: pad('  A PAGAR', '$' + money(r.pay), w), bold: true },
    ]),
    { sep: true },
    { text: pad('Pedidos', s.count, w) },
    { text: pad('Total vendido', '$' + money(s.total), w) },
    { text: pad('  Efectivo', '$' + money(s.efectivo), w) },
    { text: pad('  Transferencia', '$' + money(s.transferencia), w) },
    { text: pad('Pagar a trucks', '$' + money(s.cost), w) },
    { text: pad('GANANCIA', '$' + money(s.profit), w), bold: true },
    { cut: true },
  ];
}

// Un ticket por truck con el detalle de lo que se le paga (para que firme o se lo lleve).
function liquidacionTickets(sum) {
  const s = sum.summary;
  const w = device.width;
  return s.per.flatMap(r => [
    { text: catalog.event_name, center: true },
    { text: 'LIQUIDACION', big: true, center: true },
    { text: r.name, big: true, center: true },
    { text: `${fmtDate(sum.day.started_at)} ${fmtTime(sum.day.started_at)} a ${fmtTime(sum.day.closed_at || Date.now())}`, center: true },
    { sep: true },
    ...s.products.filter(p => p.truck_id === r.truck_id).map(p => ({ text: pad(`${p.qty} x ${p.name}`, '$' + money(p.pay), w) })),
    { sep: true },
    { text: 'A COBRAR', bold: true },
    { text: '$' + money(r.pay), big: true, center: true },
    { text: '' },
    { text: '' },
    { text: 'Firma: ______________________' },
    { cut: true },
  ]);
}

$('#btn-print-cierre').onclick = async () => { await loadVivo(); if (lastSummary) doPrint(cierreTicket(lastSummary)); };
$('#btn-print-liq').onclick = async () => { await loadVivo(); if (lastSummary) doPrint(liquidacionTickets(lastSummary)); };

$('#btn-csv').onclick = async () => {
  let orders;
  try { orders = await call('orders_today'); } catch (e) { return toast(e.message); }
  const rows = [['Pedido', 'Fecha', 'Hora', 'Pago', 'Anulado', 'Food truck', 'Producto', 'Cantidad', 'Precio', 'Al truck', 'Subtotal', 'Ganancia']];
  for (const o of orders.slice().reverse()) for (const i of o.items) {
    rows.push([o.num, fmtDate(o.created_at), fmtTime(o.created_at), o.pay, o.voided ? 'SI' : '', i.truck_name, i.name, i.qty, i.price, i.cost, i.qty * i.price, i.qty * (i.price - i.cost)]);
  }
  const csv = rows.map(r => r.map(c => `"${String(c ?? '').replace(/"/g, '""')}"`).join(';')).join('\n');
  download(`ventas-${new Date().toISOString().slice(0, 10)}.csv`, '﻿' + csv, 'text/csv');
};

$('#btn-close-day').onclick = async () => {
  if (!confirm('¿Cerrar el día? Se guarda el resumen, los trucks lo ven en su historial y la numeración vuelve a #1. Imprimí el cierre y las liquidaciones antes.')) return;
  try {
    const d = await call('close_day');
    toast(`Día cerrado · ganancia $${money(d.summary.profit)}`, 4000);
    loadHistory();
    loadVivo();
  } catch (e) { toast(e.message); }
};

function download(name, content, type) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([content], { type }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

// ---------- Productos (admin) ----------
async function save(fn, args, reload = false) {
  try {
    const r = await call(fn, args);
    if (reload) { await loadCatalog(); renderProductos(); } else loadCatalog();
    toast('Guardado ✓', 1200);
    return r;
  } catch (e) {
    toast('⚠️ ' + e.message, 4000);
    await loadCatalog();
    renderProductos();
  }
}

function renderProductos() {
  $('#cfg-trucks').innerHTML = catalog.trucks.map(t => `
    <div class="truck-cfg" style="--c:${t.color}">
      <div class="truck-cfg-head">
        <input type="color" class="t-color" data-t="${t.id}" value="${t.color}">
        <input class="t-name" data-t="${t.id}" value="${esc(t.name)}" placeholder="Nombre">
        <button class="danger small" data-deltruck="${t.id}">🗑</button>
      </div>
      <label class="field inline">PIN del truck <input class="t-pin" data-t="${t.id}" value="${esc(t.pin || '')}" inputmode="numeric" maxlength="8" placeholder="sin PIN"></label>
      <div class="prod-head"><span>Producto</span><span>Precio</span><span>Al truck</span><span></span></div>
      ${catalog.products.filter(p => p.truck_id === t.id).map(p => `
        <div class="prod-row">
          <input data-p="${p.id}" data-k="name" value="${esc(p.name)}">
          <input data-p="${p.id}" data-k="price" type="number" inputmode="numeric" value="${p.price}">
          <input data-p="${p.id}" data-k="cost" type="number" inputmode="numeric" value="${p.cost}">
          <button class="danger small" data-delprod="${p.id}">✕</button>
        </div>
        <div class="margin">Ganancia por unidad: <b class="${p.price - p.cost < 0 ? 'neg' : ''}">$${money(p.price - p.cost)}</b></div>`).join('')}
      <button class="secondary small" data-addprod="${t.id}">+ Producto</button>
    </div>`).join('') + '<button id="btn-addtruck" class="secondary wide">+ Agregar food truck</button>';

  const box = $('#cfg-trucks');
  box.querySelectorAll('.t-name').forEach(i => i.onchange = () => save('save_truck', { p_data: { id: i.dataset.t, name: i.value } }));
  box.querySelectorAll('.t-color').forEach(i => i.onchange = () => save('save_truck', { p_data: { id: i.dataset.t, color: i.value } }, true));
  box.querySelectorAll('.t-pin').forEach(i => i.onchange = () => save('save_truck', { p_data: { id: i.dataset.t, pin: i.value.trim() } }));
  box.querySelectorAll('[data-p]').forEach(i => i.onchange = () => {
    const k = i.dataset.k;
    const v = k === 'name' ? i.value : Math.max(0, Math.round(Number(i.value) || 0));
    save('save_product', { p_data: { id: i.dataset.p, [k]: v } }, k !== 'name');
  });
  box.querySelectorAll('[data-addprod]').forEach(b => b.onclick = () =>
    save('save_product', { p_data: { truck_id: b.dataset.addprod, name: 'Nuevo producto', price: 0, cost: 0, sort: catalog.products.length } }, true));
  box.querySelectorAll('[data-delprod]').forEach(b => b.onclick = () => {
    if (confirm('¿Borrar este producto?')) save('delete_product', { p_id: b.dataset.delprod }, true);
  });
  box.querySelectorAll('[data-deltruck]').forEach(b => b.onclick = () => {
    if (confirm('¿Borrar este food truck y sus productos? Las ventas ya hechas quedan registradas.')) save('delete_truck', { p_id: b.dataset.deltruck }, true);
  });
  $('#btn-addtruck').onclick = () => save('save_truck', { p_data: {
    name: 'Food Truck ' + (catalog.trucks.length + 1),
    color: COLORS[catalog.trucks.length % COLORS.length],
    sort: catalog.trucks.length,
  } }, true);
}

// ---------- Food truck ----------
async function loadTruck() {
  let orders, sum;
  try { [orders, sum] = await Promise.all([call('orders_today'), call('summary')]); } catch (e) { return toast(e.message); }
  const s = sum.summary;
  $('#truck-since').textContent = `desde ${fmtDate(sum.day.started_at)} ${fmtTime(sum.day.started_at)} · actualizado ${fmtTime(Date.now())}`;
  $('#truck-summary').innerHTML = `
    <div class="cards">
      <div class="card profit wide"><small>Tenés para cobrar hoy</small><b>$${money(s.pay)}</b></div>
      <div class="card"><small>Pedidos</small><b>${s.orders}</b></div>
      <div class="card"><small>Unidades</small><b>${s.units}</b></div>
    </div>
    ${s.products.length ? `<table>
      <tr><th>Producto</th><th>Cant.</th><th>A cobrar</th></tr>
      ${s.products.map(p => `<tr><td>${esc(p.name)}</td><td>${p.qty}</td><td>$${money(p.pay)}</td></tr>`).join('')}
    </table>` : ''}`;
  $('#truck-orders').innerHTML = orders.map(o => `
    <div class="order kitchen ${o.voided ? 'voided' : ''}">
      <div class="kitchen-head"><b>#${o.num}</b><span>${fmtTime(o.created_at)}${o.voided ? ' · ANULADO' : ''}</span></div>
      ${o.items.map(i => `<div class="kitchen-item">${i.qty} x ${esc(i.name)}</div>`).join('')}
    </div>`).join('') || '<p class="hint">Todavía no hay pedidos.</p>';
}

async function loadTruckHistory() {
  try {
    const days = await call('days_list');
    $('#truck-history').innerHTML = days.map(d => `
      <details class="order"><summary>${fmtDate(d.started_at)} · ${d.summary.orders} pedidos · <b>$${money(d.summary.pay)}</b></summary>
      <table>
        <tr><th>Producto</th><th>Cant.</th><th>Cobrado</th></tr>
        ${d.summary.products.map(p => `<tr><td>${esc(p.name)}</td><td>${p.qty}</td><td>$${money(p.pay)}</td></tr>`).join('')}
      </table></details>`).join('') || '<p class="hint">Todavía no hay días cerrados.</p>';
  } catch (e) { toast(e.message); }
}

// ---------- Ajustes ----------
function renderAjustes() {
  $('#cfg-mode').value = device.mode;
  $('#cfg-width').value = String(device.width);
  $('#cfg-customer').checked = device.customer;
  $('#cfg-cut').checked = device.cutter;
  if (session.role === 'admin') {
    $('#cfg-event').value = catalog.event_name || '';
    $('#cfg-pin-caja').value = catalog.pin_caja || '';
    $('#cfg-pin-admin').value = session.pin;
  }
}

const saveDevice = () => { writeJson(DEVICE_KEY, device); renderHeader(); };
$('#cfg-mode').onchange = e => { device.mode = e.target.value; saveDevice(); };
$('#cfg-width').onchange = e => { device.width = Number(e.target.value); saveDevice(); };
$('#cfg-customer').onchange = e => { device.customer = e.target.checked; saveDevice(); };
$('#cfg-cut').onchange = e => { device.cutter = e.target.checked; saveDevice(); };

async function saveSettings(data) {
  try {
    await call('save_settings', { p_data: data });
    toast('Guardado ✓', 1200);
  } catch (e) { toast('⚠️ ' + e.message, 4000); }
  await loadCatalog();
  renderAjustes();
}
$('#cfg-event').onchange = e => saveSettings({ event_name: e.target.value });
$('#cfg-pin-caja').onchange = e => saveSettings({ pin_caja: e.target.value.trim() });
$('#cfg-pin-admin').onchange = async e => {
  const nuevo = e.target.value.trim();
  if (!confirm(`¿Cambiar tu PIN de admin a ${nuevo}? Anotalo.`)) return renderAjustes();
  try {
    await call('save_settings', { p_data: { pin_admin: nuevo } });
    session.pin = nuevo;
    writeJson(SESSION_KEY, session);
    toast('PIN de admin cambiado ✓');
  } catch (err) { toast('⚠️ ' + err.message, 4000); }
  renderAjustes();
};

$('#btn-test').onclick = () => doPrint([
  { text: catalog.event_name, center: true },
  { text: 'PRUEBA OK', big: true, center: true },
  { sep: true },
  { text: 'Si lees esto, la impresora anda.' },
  { cut: true },
]);

// ---------- Impresora ----------
Printer.onStatus(s => {
  $('#printer-status').textContent = { ok: 'Conectada', conectando: 'Conectando…', desconectada: 'Desconectada' }[s] || s;
  $('#btn-printer').classList.toggle('on', s === 'ok');
  $('#btn-printer').classList.toggle('off', s !== 'ok');
});

$('#btn-printer').onclick = async () => {
  try {
    toast('Impresora conectada: ' + await Printer.connect());
  } catch (e) {
    if (e.name !== 'NotFoundError') toast('⚠️ ' + e.message, 5000); // NotFoundError = el usuario canceló
  }
};

// ---------- Inicio ----------
if (session) startApp(); else showLogin();
if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js');
