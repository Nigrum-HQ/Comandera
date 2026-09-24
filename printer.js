// Impresión de tickets en impresoras térmicas ESC/POS.
// Un ticket es una lista de líneas: {text, big, bold, center} o {sep: true} o {cut: true}.

const Printer = (() => {
  // Servicios BLE que usan las impresoras térmicas chinas más comunes.
  const SERVICES = [
    '000018f0-0000-1000-8000-00805f9b34fb',
    'e7810a71-73ae-499d-8c15-faa9aef0c3f2',
    '49535343-fe7d-4ae5-8fa9-9fafd205e455',
    '0000ff00-0000-1000-8000-00805f9b34fb',
    '0000ffe0-0000-1000-8000-00805f9b34fb',
    '0000fee7-0000-1000-8000-00805f9b34fb',
    '0000ae30-0000-1000-8000-00805f9b34fb',
  ];
  const CHUNK = 100;

  let device = null;
  let characteristic = null;
  let onStatus = () => {};

  function setStatus(s) { onStatus(s); }

  // Las térmicas baratas no traen acentos confiables: los sacamos.
  function clean(s) {
    return String(s).normalize('NFD').replace(/[̀-ͯ]/g, '')
      .replace(/[¡¿]/g, '').replace(/[^\x20-\x7e]/g, '?');
  }

  function toEscPos(lines, width, hasCutter) {
    const out = [0x1b, 0x40]; // inicializar
    const push = s => { for (const ch of clean(s)) out.push(ch.charCodeAt(0)); };
    for (const l of lines) {
      if (l.cut) {
        out.push(0x0a, 0x0a, 0x0a);
        if (hasCutter) out.push(0x1d, 0x56, 0x42, 0x00);
        else {
          // sin cortador: una marca bien visible para arrancar cada papelito por separado
          const mark = ' CORTAR AQUI ';
          const side = '-'.repeat(Math.max(0, Math.floor((width - mark.length) / 2)));
          out.push(0x1b, 0x61, 0, 0x1b, 0x45, 1, 0x1d, 0x21, 0);
          push(side + mark + side);
          out.push(0x0a, 0x1b, 0x45, 0, 0x0a, 0x0a, 0x0a);
        }
        out.push(0x1b, 0x40);
        continue;
      }
      if (l.sep) { push('-'.repeat(width)); out.push(0x0a); continue; }
      out.push(0x1b, 0x61, l.center ? 1 : 0);
      out.push(0x1b, 0x45, l.bold || l.big ? 1 : 0);
      out.push(0x1d, 0x21, l.big ? 0x11 : 0x00);
      push(l.text || '');
      out.push(0x0a);
    }
    out.push(0x1b, 0x61, 0, 0x1b, 0x45, 0, 0x1d, 0x21, 0);
    return new Uint8Array(out);
  }

  async function findWritable(server) {
    const services = await server.getPrimaryServices();
    for (const s of services) {
      const chars = await s.getCharacteristics();
      for (const c of chars) {
        if (c.properties.write || c.properties.writeWithoutResponse) return c;
      }
    }
    throw new Error('La impresora no tiene un canal de escritura compatible');
  }

  async function connectGatt() {
    setStatus('conectando');
    const server = await device.gatt.connect();
    characteristic = await findWritable(server);
    setStatus('ok');
  }

  async function connect() {
    if (!navigator.bluetooth) {
      throw new Error('Este navegador no soporta Bluetooth. Usá Chrome en Android, o elegí "App RawBT" en Config.');
    }
    device = await navigator.bluetooth.requestDevice({ acceptAllDevices: true, optionalServices: SERVICES });
    device.addEventListener('gattserverdisconnected', () => {
      characteristic = null;
      setStatus('desconectada');
    });
    await connectGatt();
    return device.name || 'Impresora';
  }

  async function ensureConnected() {
    if (characteristic && device?.gatt.connected) return;
    if (!device) throw new Error('No hay impresora conectada. Tocá el botón 🖨️ arriba.');
    await connectGatt(); // reconectar no requiere volver a elegir el dispositivo
  }

  async function writeBle(bytes) {
    await ensureConnected();
    for (let i = 0; i < bytes.length; i += CHUNK) {
      const part = bytes.slice(i, i + CHUNK);
      if (characteristic.properties.write) await characteristic.writeValueWithResponse(part);
      else {
        await characteristic.writeValueWithoutResponse(part);
        await new Promise(r => setTimeout(r, 30));
      }
    }
  }

  function sendRawbt(bytes) {
    let bin = '';
    for (const b of bytes) bin += String.fromCharCode(b);
    location.href = 'intent:base64,' + btoa(bin) + '#Intent;scheme=rawbt;package=ru.a402d.rawbtprinter;end;';
  }

  function printSystem(lines, width) {
    const area = document.getElementById('print-area');
    area.innerHTML = '';
    area.style.setProperty('--cols', width);
    let ticket = document.createElement('div');
    ticket.className = 'ticket';
    area.appendChild(ticket);
    for (const l of lines) {
      if (l.cut) {
        ticket = document.createElement('div');
        ticket.className = 'ticket';
        area.appendChild(ticket);
        continue;
      }
      const d = document.createElement('div');
      d.textContent = l.sep ? '-'.repeat(width) : (l.text || ' ');
      if (l.big) d.className = 'big';
      if (l.bold) d.style.fontWeight = 'bold';
      if (l.center) d.style.textAlign = 'center';
      ticket.appendChild(d);
    }
    window.print();
  }

  async function print(lines, { mode, width, cutter }) {
    if (mode === 'none') return;
    if (mode === 'system') return printSystem(lines, width);
    const bytes = toEscPos(lines, width, cutter);
    if (mode === 'rawbt') return sendRawbt(bytes);
    return writeBle(bytes);
  }

  return {
    connect,
    print,
    isConnected: () => !!(characteristic && device?.gatt.connected),
    onStatus: fn => { onStatus = fn; },
  };
})();
