// Datos del proyecto de Supabase (Project Settings → API).
// La "publishable key" es pública: está pensada para ir en la app.
window.COMANDERA_CONFIG = {
  supabaseUrl: 'https://yeldyycgkeorrlkxmayz.supabase.co',
  supabaseKey: 'sb_publishable_qa1Jc7v1OzXCX19xRryMNQ_vHSNHibW',
  prefix: '',            // prefijo de las funciones en la base (cada evento aparte tiene el suyo)
  storage: 'comandera.', // prefijo de lo que se guarda en el celular
};

// Eventos aparte: misma app, otra base de datos (tablas y funciones con prefijo; ver supabase/evento.py).
// Se abren con ?evento=<nombre>, o con la carpeta del mismo nombre (ej. /halloween/).
const EVENTOS = {
  halloween: {
    prefix: 'hw_',
    storage: 'hw.',
    theme: 'halloween',
    manifest: 'manifest-halloween.webmanifest',
    labels: {
      truck: 'sector', trucks: 'sectores', alTruck: 'Costo', pagar: 'Costo de mercadería', pagarle: 'Costo',
      caja: 'Barra', retira: ['Retira tu pedido en la barra', 'con este ticket'],
      entregar: ['ENTREGAR EN LA BARRA'],
    },
    comandas: false, // en la barra no hace falta un ticket por sector
  },
};
(() => {
  const ev = new URLSearchParams(location.search).get('evento');
  if (!EVENTOS[ev]) return;
  Object.assign(window.COMANDERA_CONFIG, EVENTOS[ev], { evento: ev });
  if (EVENTOS[ev].theme) document.body.classList.add('tema-' + EVENTOS[ev].theme);
  const link = document.querySelector('link[rel=manifest]');
  if (link && EVENTOS[ev].manifest) link.href = EVENTOS[ev].manifest;
})();
