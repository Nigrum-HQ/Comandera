# Comandera

Caja unificada para un patio de comidas con varios food trucks. Anda en el **celular**, sin instalar nada raro, y funciona **sin internet** una vez abierta.

- Una sola caja cobra los pedidos de todos los food trucks.
- Al cobrar imprime un **ticket para el cliente** con el número de pedido y **una comanda para cada food truck** con solo lo suyo.
- A fin del día muestra (e imprime) **cuánto hay que pagarle a cada food truck** y **cuánto te queda de ganancia**, separado en efectivo y transferencia.

## Cómo se usa

1. **Config ⚙️**: poné el nombre del evento, los food trucks y sus productos. Cada producto tiene:
   - **Precio**: lo que paga el cliente.
   - **Al truck**: lo que le pagás al food truck por cada unidad.
   - La diferencia es tu ganancia.
2. **Vender 🍔**: tocá los productos, después el botón verde, elegí efectivo o transferencia y **Cobrar e imprimir**.
3. **Día 📋**: ves el total, la ganancia y cuánto pagarle a cada truck. Podés anular o reimprimir pedidos, imprimir el cierre y bajar un Excel (CSV).
4. Al terminar: **Imprimir cierre** → pagarle a cada truck → **Cerrar el día** (la numeración vuelve a #1 y el resumen queda en "Días anteriores").

> Los datos se guardan en el celular que se usa como caja. Usá siempre el mismo celular, y cada tanto tocá **Exportar datos** para tener un respaldo.

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

## Publicarla (una sola vez)

La app es solo HTML/JS, se publica gratis con GitHub Pages:

1. En GitHub: **Settings → Pages → Source: GitHub Actions**.
2. Mergear a `main`. El workflow `.github/workflows/pages.yml` la publica en `https://<usuario>.github.io/<repo>/`.
3. Abrir esa dirección en Chrome del celular → menú ⋮ → **Agregar a pantalla principal**. Queda como una app.

Para probarla en la compu: `python3 -m http.server` y abrir `http://localhost:8000`.
