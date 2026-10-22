/* REFRIMAR · Datos públicos del negocio (UN SOLO SITIO PARA CAMBIARLOS).
 * Los usan la portada, el aviso legal, el botón de WhatsApp, los datos para Google (JSON-LD),
 * el aviso de cookies, la analítica y la protección anti-spam del login.
 * Deja en '' lo que todavía no tengas: esa parte simplemente no se muestra.
 */
window.REF_SITIO = {
    razonSocial: 'Comercial Refrimar 2023, C.A.',
    nombreComercial: 'Ferretería REFRIMAR',
    rif: 'J-50357586-7',
    correo: 'refrimar.es23@gmail.com',
    dominio: 'https://refrimar-app.refrimar-es23.workers.dev',

    // WhatsApp con código de país, solo números. Ej: '584121234567'
    whatsapp: '',
    whatsappMensaje: 'Hola REFRIMAR, quiero información.',
    telefono: '',              // Ej: '+58 212 000 0000'

    tiendas: [
        { nombre: 'Casa Matriz', direccion: '', ciudad: 'Caracas', estado: 'Distrito Capital', mapa: '' },
        { nombre: 'Sucursal',    direccion: '', ciudad: 'Caracas', estado: 'Distrito Capital', mapa: '' }
    ],
    // Horario: días en formato de Google (Mo Tu We Th Fr Sa Su)
    // Ejemplo: { dias: ['Mo','Tu','We','Th','Fr'], abre: '08:00', cierra: '17:00', texto: 'Lunes a viernes, 8:00 a. m. – 5:00 p. m.' }
    horario: [],
    redes: { instagram: '', facebook: '' },

    // Cloudflare Web Analytics (sin cookies). Pega aquí el "token" del panel de Cloudflare.
    analyticsToken: '',
    // Cloudflare Turnstile (anti-spam). La "site key" va aquí; la "secret key" va como
    // secreto del Worker:  npx wrangler secret put TURNSTILE_SECRET
    turnstileSiteKey: ''
};

/* Producto que se vende a otras empresas (multiempresa). Es SEPARADO de la marca REFRIMAR.
 * El nombre real se cambia en el panel del superadministrador (superadmin.html → Producto);
 * esto es solo lo que se ve mientras carga o sin internet.
 */
window.REF_PRODUCTO = {
    nombre: 'Cuadra',
    lema: 'Factura, controla el inventario y cuadra la caja',
    whatsapp: '',          // número de ventas del producto, solo dígitos con código de país
    correo: 'refrimar.es23@gmail.com'
};
