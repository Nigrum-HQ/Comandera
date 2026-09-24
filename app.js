// Comandera: caja unificada para varios food trucks.
// Todos los datos se guardan en el celular (localStorage).

const KEY = 'comandera.v1';
const COLORS = ['#ef4444', '#3b82f6', '#10b981', '#f59e0b', '#8b5cf6', '#ec4899'];

const uid = () => Math.random().toString(36).slice(2, 10);
const $ = s => document.querySelector(s);
const money = n => Math.round(n).toLocaleString('es-AR');
const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function defaultState() {
  const trucks = [1, 2, 3, 4].map(i => ({ id: uid(), name: 'Food Truck ' + i, color: COLORS[i - 1] }));
  return {
    trucks,
    products: [
      { id: uid(), truckId: trucks[0].id, name: 'Hamburguesa', price: 8000, cost: 6000 },
      { id: uid(), truckId: trucks[1].id, name: 'Pizza porción', price: 4000, cost: 3000 },
      { id: uid(), truckId: trucks[2].id, name: 'Choripán', price: 5000, cost: 3800 },
      { id: uid(), truckId: trucks[3].id, name: 'Papas fritas', price: 4500, cost: 3300 },
    ],
    settings: { club: 'Comandera', mode: 'ble', width: 32, customer: true, cutter: false },
    orders: [],
    nextNum: 1,
    dayStart: Date.now(),
    history: [],
  };
}

function load() {
  try {
    const s = JSON.parse(localStorage.getItem(KEY));
    if (s && s.trucks) return s;
  } catch (e) { /* datos corruptos: arrancar de cero */ }
  return defaultState();
}

let state = load();
let cart = {}; // productId -> cantidad
let filter = 'all';

function save() { localStorage.setItem(KEY, JSON.stringify(state)); }

function toast(msg, ms = 2500) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => t.classList.add('hidden'), ms);
}

const truckById = id => state.trucks.find(t => t.id === id);
const fmtTime = ts => new Date(ts).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit', hour12: false });
const fmtDate = ts => new Date(ts).toLocaleDateString('es-AR');

// ---------- Navegación ----------
document.querySelectorAll('nav button').forEach(b => b.addEventListener('click', () => {
  document.querySelectorAll('nav button').forEach(x => x.classList.toggle('active', x === b));
  document.querySelectorAll('.view').forEach(v => v.classList.toggle('active', v.id === 'view-' + b.dataset.view));
  render();
}));
document.querySelectorAll('[data-close]').forEach(b => b.addEventListener('click', () => $('#' + b.dataset.close).classList.add('hidden')));

// ---------- Vender ----------
function renderVender() {
  $('#truck-filter').innerHTML = [{ id: 'all', name: 'Todos', color: '#374151' }, ...state.trucks]
    .map(t => `<button class="chip ${filter === t.id ? 'on' : ''}" data-f="${t.id}" style="--c:${t.color}">${esc(t.name)}</button>`).join('');
  $('#truck-filter').querySelectorAll('button').forEach(b => b.onclick = () => { filter = b.dataset.f; renderVender(); });

  const prods = state.products.filter(p => truckById(p.truckId) && (filter === 'all' || p.truckId === filter));
  $('#products').innerHTML = prods.length ? prods.map(p => {
    const t = truckById(p.truckId);
    const q = cart[p.id] || 0;
    return `<button class="product" data-id="${p.id}" style="--c:${t.color}">
      ${q ? `<span class="qty">${q}</span>` : ''}
      <span class="pname">${esc(p.name)}</span>
      <span class="ptruck">${esc(t.name)}</span>
      <span class="pprice">$${money(p.price)}</span>
    </button>`;
  }).join('') : '<p class="hint">No hay productos. Cargalos en ⚙️ Config.</p>';
  $('#products').querySelectorAll('.product').forEach(b => b.onclick = () => {
    cart[b.dataset.id] = (cart[b.dataset.id] || 0) + 1;
    if (navigator.vibrate) navigator.vibrate(20);
    renderVender();
  });
  renderCart();
}

function cartLines() {
  return Object.entries(cart).map(([id, qty]) => ({ p: state.products.find(p => p.id === id), qty }))
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
    <div class="cart-line" style="--c:${truckById(l.p.truckId).color}">
      <div><b>${esc(l.p.name)}</b><small>${esc(truckById(l.p.truckId).name)} · $${money(l.p.price)}</small></div>
      <div class="stepper">
        <button data-d="-1" data-id="${l.p.id}">−</button><span>${l.qty}</span><button data-d="1" data-id="${l.p.id}">+</button>
      </div>
    </div>`).join('') || '<p class="hint">Vacío</p>';
  $('#cart-items').querySelectorAll('button').forEach(b => b.onclick = () => {
    cart[b.dataset.id] = Math.max(0, (cart[b.dataset.id] || 0) + Number(b.dataset.d));
    renderVender();
  });
}

$('#btn-cart').onclick = () => { if (cartLines().length) $('#cart-sheet').classList.remove('hidden'); };
$('#btn-clear').onclick = () => { cart = {}; $('#cart-sheet').classList.add('hidden'); renderVender(); };

$('#btn-cobrar').onclick = async () => {
  const lines = cartLines();
  if (!lines.length) return;
  const order = {
    id: uid(),
    num: state.nextNum++,
    ts: Date.now(),
    pay: document.querySelector('input[name=pay]:checked').value,
    items: lines.map(l => ({ pid: l.p.id, name: l.p.name, truckId: l.p.truckId, qty: l.qty, price: l.p.price, cost: l.p.cost })),
    voided: false,
  };
  order.total = order.items.reduce((s, i) => s + i.qty * i.price, 0);
  state.orders.push(order);
  save();
  cart = {};
  $('#cart-sheet').classList.add('hidden');
  document.querySelector('input[name=pay][value=efectivo]').checked = true;
  renderVender();
  toast(`Pedido #${order.num} cobrado`);
  await printOrder(order);
};

// ---------- Tickets ----------
function truckTicket(order, truckId) {
  const t = truckById(truckId);
  const items = order.items.filter(i => i.truckId === truckId);
  return [
    { text: state.settings.club, center: true },
    { text: t ? t.name : 'Food truck', big: true, center: true },
    { text: `PEDIDO #${order.num}`, big: true, center: true },
    { text: `${fmtDate(order.ts)} ${fmtTime(order.ts)}`, center: true },
    { sep: true },
    ...items.map(i => ({ text: `${i.qty} x ${i.name}`, big: true })),
    { sep: true },
    { cut: true },
  ];
}

function pad(left, right, width) {
  const w = Number(width);
  left = String(left);
  right = String(right);
  const space = w - right.length - 1;
  if (left.length > space) left = left.slice(0, space);
  return left + ' '.repeat(w - left.length - right.length) + right;
}

function customerTicket(order) {
  const w = state.settings.width;
  const trucks = [...new Set(order.items.map(i => i.truckId))];
  return [
    { text: state.settings.club, bold: true, center: true },
    { text: `PEDIDO #${order.num}`, big: true, center: true },
    { text: `${fmtDate(order.ts)} ${fmtTime(order.ts)}`, center: true },
    { sep: true },
    ...trucks.flatMap(tid => [
      { text: (truckById(tid)?.name || '').toUpperCase(), bold: true },
      ...order.items.filter(i => i.truckId === tid).map(i => ({ text: pad(`${i.qty} x ${i.name}`, '$' + money(i.qty * i.price), w) })),
    ]),
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
    await Printer.print(lines, state.settings);
  } catch (e) {
    toast('⚠️ No se pudo imprimir: ' + e.message, 5000);
  }
}

function printOrder(order) {
  const trucks = [...new Set(order.items.map(i => i.truckId))];
  const lines = [...(state.settings.customer ? customerTicket(order) : []), ...trucks.flatMap(t => truckTicket(order, t))];
  return doPrint(lines);
}

// ---------- Día / cierre ----------
function summarize(orders) {
  const per = {};
  let total = 0, cost = 0, efectivo = 0, transfer = 0, count = 0;
  for (const o of orders) {
    if (o.voided) continue;
    count++;
    total += o.total;
    if (o.pay === 'efectivo') efectivo += o.total; else transfer += o.total;
    for (const i of o.items) {
      const name = truckById(i.truckId)?.name || 'Truck borrado';
      const r = per[i.truckId] ||= { name, sold: 0, pay: 0, units: 0 };
      r.sold += i.qty * i.price;
      r.pay += i.qty * i.cost;
      r.units += i.qty;
      cost += i.qty * i.cost;
    }
  }
  return { per: Object.values(per), total, cost, profit: total - cost, efectivo, transfer, count };
}

function summaryHtml(s) {
  return `
    <div class="cards">
      <div class="card"><small>Vendido</small><b>$${money(s.total)}</b></div>
      <div class="card profit"><small>Tu ganancia</small><b>$${money(s.profit)}</b></div>
      <div class="card"><small>Efectivo</small><b>$${money(s.efectivo)}</b></div>
      <div class="card"><small>Transferencia</small><b>$${money(s.transfer)}</b></div>
    </div>
    <table>
      <tr><th>Food truck</th><th>Vendido</th><th>A pagarle</th></tr>
      ${s.per.map(r => `<tr><td>${esc(r.name)}</td><td>$${money(r.sold)}</td><td><b>$${money(r.pay)}</b></td></tr>`).join('')}
      <tr class="tot"><td>Total</td><td>$${money(s.total)}</td><td>$${money(s.cost)}</td></tr>
    </table>
    <p class="hint">${s.count} pedidos</p>`;
}

function renderDia() {
  $('#day-summary').innerHTML = `<p class="hint">Desde ${fmtDate(state.dayStart)} ${fmtTime(state.dayStart)}</p>` + summaryHtml(summarize(state.orders));
  $('#order-list').innerHTML = state.orders.slice().reverse().map(o => `
    <details class="order ${o.voided ? 'voided' : ''}">
      <summary><b>#${o.num}</b> ${fmtTime(o.ts)} · $${money(o.total)} · ${o.pay === 'efectivo' ? '💵' : '📱'} ${o.voided ? '<em>ANULADO</em>' : ''}</summary>
      <ul>${o.items.map(i => `<li>${i.qty} x ${esc(i.name)} <small>(${esc(truckById(i.truckId)?.name || '')})</small></li>`).join('')}</ul>
      ${o.voided ? '' : `<div class="row"><button data-reprint="${o.id}" class="secondary">Reimprimir</button><button data-void="${o.id}" class="danger">Anular</button></div>`}
    </details>`).join('') || '<p class="hint">Todavía no hay pedidos.</p>';
  $('#order-list').querySelectorAll('[data-void]').forEach(b => b.onclick = () => {
    const o = state.orders.find(x => x.id === b.dataset.void);
    if (confirm(`¿Anular el pedido #${o.num}? Devolvé $${money(o.total)} al cliente.`)) { o.voided = true; save(); renderDia(); }
  });
  $('#order-list').querySelectorAll('[data-reprint]').forEach(b => b.onclick = () => printOrder(state.orders.find(x => x.id === b.dataset.reprint)));

  $('#history').innerHTML = state.history.slice().reverse().map(h => `
    <details class="order"><summary>${fmtDate(h.start)} → ${fmtDate(h.end)} · $${money(h.summary.total)} · ganancia $${money(h.summary.profit)}</summary>
    ${summaryHtml(h.summary)}</details>`).join('') || '<p class="hint">Sin días cerrados.</p>';
}

function cierreTicket(s) {
  const w = state.settings.width;
  return [
    { text: state.settings.club, bold: true, center: true },
    { text: 'CIERRE DE CAJA', big: true, center: true },
    { text: `${fmtDate(state.dayStart)} ${fmtTime(state.dayStart)} a ${fmtTime(Date.now())}`, center: true },
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
    { text: pad('  Transferencia', '$' + money(s.transfer), w) },
    { text: pad('Pagar a trucks', '$' + money(s.cost), w) },
    { text: pad('GANANCIA', '$' + money(s.profit), w), bold: true },
    { cut: true },
  ];
}

$('#btn-print-cierre').onclick = () => doPrint(cierreTicket(summarize(state.orders)));

$('#btn-csv').onclick = () => {
  const rows = [['Pedido', 'Fecha', 'Hora', 'Pago', 'Anulado', 'Food truck', 'Producto', 'Cantidad', 'Precio', 'Al truck', 'Subtotal', 'Ganancia']];
  for (const o of state.orders) for (const i of o.items) {
    rows.push([o.num, fmtDate(o.ts), fmtTime(o.ts), o.pay, o.voided ? 'SI' : '', truckById(i.truckId)?.name || '', i.name, i.qty, i.price, i.cost, i.qty * i.price, i.qty * (i.price - i.cost)]);
  }
  const csv = rows.map(r => r.map(c => `"${String(c).replace(/"/g, '""')}"`).join(';')).join('\n');
  download(`ventas-${new Date().toISOString().slice(0, 10)}.csv`, '﻿' + csv, 'text/csv');
};

$('#btn-close-day').onclick = () => {
  if (!state.orders.length) return toast('No hay pedidos en el día');
  if (!confirm('¿Cerrar el día? Se guarda el resumen y la numeración vuelve a #1. Imprimí el cierre antes.')) return;
  const summary = summarize(state.orders);
  state.history.push({ start: state.dayStart, end: Date.now(), summary });
  state.orders = [];
  state.nextNum = 1;
  state.dayStart = Date.now();
  save();
  renderDia();
  toast('Día cerrado');
};

// ---------- Config ----------
function renderConfig() {
  const s = state.settings;
  $('#cfg-club').value = s.club;
  $('#cfg-mode').value = s.mode;
  $('#cfg-width').value = String(s.width);
  $('#cfg-customer').checked = s.customer;
  $('#cfg-cut').checked = s.cutter;

  $('#cfg-trucks').innerHTML = state.trucks.map(t => `
    <div class="truck-cfg" style="--c:${t.color}">
      <div class="row">
        <input class="t-name" data-t="${t.id}" value="${esc(t.name)}">
        <button class="danger small" data-deltruck="${t.id}">🗑</button>
      </div>
      <div class="prod-head"><span>Producto</span><span>Precio</span><span>Al truck</span><span></span></div>
      ${state.products.filter(p => p.truckId === t.id).map(p => `
        <div class="prod-row">
          <input data-p="${p.id}" data-k="name" value="${esc(p.name)}">
          <input data-p="${p.id}" data-k="price" type="number" inputmode="numeric" value="${p.price}">
          <input data-p="${p.id}" data-k="cost" type="number" inputmode="numeric" value="${p.cost}">
          <button class="danger small" data-delprod="${p.id}">✕</button>
        </div>`).join('')}
      <button class="secondary small" data-addprod="${t.id}">+ Producto</button>
    </div>`).join('') + '<button id="btn-addtruck" class="secondary">+ Agregar food truck</button>';

  $('#cfg-trucks').querySelectorAll('.t-name').forEach(i => i.onchange = () => { truckById(i.dataset.t).name = i.value.trim() || 'Sin nombre'; save(); });
  $('#cfg-trucks').querySelectorAll('[data-p]').forEach(i => i.onchange = () => {
    const p = state.products.find(x => x.id === i.dataset.p);
    p[i.dataset.k] = i.dataset.k === 'name' ? i.value : Math.max(0, Number(i.value) || 0);
    if (p.cost > p.price) toast('⚠️ Ojo: le pagás al truck más de lo que cobrás');
    save();
  });
  $('#cfg-trucks').querySelectorAll('[data-addprod]').forEach(b => b.onclick = () => {
    state.products.push({ id: uid(), truckId: b.dataset.addprod, name: 'Nuevo producto', price: 0, cost: 0 });
    save(); renderConfig();
  });
  $('#cfg-trucks').querySelectorAll('[data-delprod]').forEach(b => b.onclick = () => {
    state.products = state.products.filter(p => p.id !== b.dataset.delprod);
    save(); renderConfig();
  });
  $('#cfg-trucks').querySelectorAll('[data-deltruck]').forEach(b => b.onclick = () => {
    if (state.orders.some(o => o.items.some(i => i.truckId === b.dataset.deltruck))) {
      return toast('Ese truck tiene ventas hoy. Cerrá el día antes de borrarlo.', 4000);
    }
    if (!confirm('¿Borrar este food truck y sus productos?')) return;
    state.trucks = state.trucks.filter(t => t.id !== b.dataset.deltruck);
    state.products = state.products.filter(p => p.truckId !== b.dataset.deltruck);
    save(); renderConfig();
  });
  $('#btn-addtruck').onclick = () => {
    state.trucks.push({ id: uid(), name: 'Food Truck ' + (state.trucks.length + 1), color: COLORS[state.trucks.length % COLORS.length] });
    save(); renderConfig();
  };
}

$('#cfg-club').onchange = e => { state.settings.club = e.target.value.trim() || 'Comandera'; save(); renderHeader(); };
$('#cfg-mode').onchange = e => { state.settings.mode = e.target.value; save(); renderHeader(); };
$('#cfg-width').onchange = e => { state.settings.width = Number(e.target.value); save(); };
$('#cfg-customer').onchange = e => { state.settings.customer = e.target.checked; save(); };
$('#cfg-cut').onchange = e => { state.settings.cutter = e.target.checked; save(); };
$('#btn-test').onclick = () => doPrint([
  { text: state.settings.club, center: true },
  { text: 'PRUEBA OK', big: true, center: true },
  { sep: true },
  { text: 'Si lees esto, la impresora anda.' },
  { cut: true },
]);

function download(name, content, type) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([content], { type }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

$('#btn-export').onclick = () => download(`comandera-respaldo-${new Date().toISOString().slice(0, 10)}.json`, JSON.stringify(state), 'application/json');
$('#file-import').onchange = async e => {
  const f = e.target.files[0];
  if (!f) return;
  try {
    const s = JSON.parse(await f.text());
    if (!s.trucks || !s.products) throw new Error();
    if (!confirm('Esto reemplaza todos los datos del celular. ¿Seguir?')) return;
    state = s; save(); render(); toast('Datos importados');
  } catch { toast('Archivo inválido'); }
  e.target.value = '';
};

// ---------- Impresora ----------
function renderHeader() {
  $('#club-title').textContent = state.settings.club;
  $('#btn-printer').classList.toggle('hidden', state.settings.mode !== 'ble');
}

Printer.onStatus(s => {
  const label = { ok: 'Conectada', conectando: 'Conectando…', desconectada: 'Desconectada' }[s] || s;
  $('#printer-status').textContent = label;
  $('#btn-printer').classList.toggle('on', s === 'ok');
  $('#btn-printer').classList.toggle('off', s !== 'ok');
});

$('#btn-printer').onclick = async () => {
  try {
    const name = await Printer.connect();
    toast('Impresora conectada: ' + name);
  } catch (e) {
    if (e.name !== 'NotFoundError') toast('⚠️ ' + e.message, 5000); // NotFoundError = el usuario canceló
  }
};

// ---------- Inicio ----------
function render() {
  renderHeader();
  if ($('#view-vender').classList.contains('active')) renderVender();
  if ($('#view-dia').classList.contains('active')) renderDia();
  if ($('#view-config').classList.contains('active')) renderConfig();
}

render();
if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js');
