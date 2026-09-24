# Comandera

Caja unificada para un patio de comidas con varios food trucks. Anda en el **celular**, sin instalar nada raro, y funciona **sin internet** una vez abierta.

- Una sola caja cobra los pedidos de todos los food trucks.
- Al cobrar imprime un **ticket para el cliente** con el número de pedido y **una comanda para cada food truck** con solo lo suyo.
- Cada persona entra con su **PIN** a su pantalla, desde su propio celular:

| Pantalla | Quién | Qué ve / hace |
|---|---|---|
| **Admin** | El organizador | Carga food trucks, productos, precios y PINs. Ve **en vivo** lo vendido, la **ganancia**, cuánto pagarle a cada truck, efectivo vs. transferencia y lo más vendido. Imprime el cierre y la liquidación de cada truck, baja el Excel y cierra el día. También puede vender. |
| **Caja** | La gente del club | Vende e imprime. Ve los pedidos del día (anular / reimprimir) y cuánto efectivo debería haber en la caja. **No ve costos ni ganancia.** |
| **Food truck** | Cada truck | Ve en vivo sus pedidos (con número, como pantalla de cocina) y **cuánto tiene para cobrar**, con el detalle por producto. En "Historial" ve cómo le fue cada día. **No ve lo de los otros trucks ni tu margen.** |

Las pantallas "en vivo" se actualizan solas cada 5 segundos.

## Cómo se usa

1. La primera vez que se abre, pide **elegir el PIN del admin**.
2. **Admin → 🍔 Productos**: agregá los food trucks, poné un PIN a cada uno y cargá sus productos. Cada producto tiene:
   - **Precio**: lo que paga el cliente.
   - **Al truck**: lo que le pagás al food truck por cada unidad.
   - Debajo se ve la ganancia por unidad.
3. **Admin → ⚙️ Ajustes**: nombre del evento y **PIN de la caja**.
4. En el celular de la caja: entrar con el PIN de caja, tocar 🖨️ para conectar la impresora y vender.
5. Cada food truck entra con su PIN en su celular.
6. Al terminar, el admin en **📈 En vivo**: *Imprimir cierre* → *Liquidación por truck* (un ticket por truck con lo que cobra y lugar para firmar) → pagar → **Cerrar el día**. La numeración vuelve a #1 y el día queda en el historial de todos.

> La caja necesita internet (datos del celular o WiFi del club) para cobrar: si se corta, avisa y no registra el pedido.

## Impresora (inalámbrica, desde el celular)

Sirve cualquier impresora térmica **ESC/POS** de 58 mm u 80 mm (las típicas "impresora térmica bluetooth portátil"). Hay tres formas de imprimir, se elige en Config:

| Modo | Celular | Qué hace falta |
|---|---|---|
| **Bluetooth directo** (recomendado) | Android con Chrome | Que la impresora sea **Bluetooth 4.0 / BLE**. Tocás 🖨️ arriba, elegís la impresora, listo. |
| **App RawBT** | Android | Instalar la app gratuita *RawBT* y conectar ahí la impresora. Sirve para impresoras Bluetooth clásicas o **WiFi**. |
| **Diálogo del sistema** | Cualquiera (iPhone incluido) | Una impresora que el teléfono ya sepa usar. Es más lento. |

Consejos:
- Al comprar la impresora, buscá que diga **BLE** o **Bluetooth 4.0** y **ESC/POS** (ej.: modelos genéricos de 58 mm tipo "MTP-II", "PT-210", Xprinter con BLE).
- Si se reinicia la app, hay que tocar 🖨️ de nuevo para reconectar (lo exige Chrome por seguridad).
- Usá **Imprimir prueba** en Config antes de arrancar.
- iPhone no permite Bluetooth desde el navegador; para la caja conviene un Android.

## Instalación (una sola vez)

### 1. Base de datos (Supabase, gratis)

1. Entrá a [supabase.com](https://supabase.com) → **New project** (nombre "Comandera", región *South America (São Paulo)*).
2. En el proyecto: **SQL Editor** → pegá todo el contenido de [`supabase/schema.sql`](supabase/schema.sql) → **Run**.
3. En **Project Settings → API** copiá la **Project URL** y la **Publishable key** (o *anon key*) y pegalas en [`config.js`](config.js).

La key es pública a propósito: las tablas están cerradas y todo pasa por funciones que validan el PIN, así cada rol solo ve lo suyo. Usá PINs que no sean obvios (nada de 1234).

### 2. Publicar la app (GitHub Pages)

1. En GitHub: **Settings → Pages → Source: GitHub Actions**.
2. Mergear a `main`. El workflow `.github/workflows/pages.yml` la publica en `https://<usuario>.github.io/<repo>/`.
3. En cada celular: abrir esa dirección en Chrome → menú ⋮ → **Agregar a pantalla principal**.

Para probarla en la compu: `python3 -m http.server` y abrir `http://localhost:8000`.
