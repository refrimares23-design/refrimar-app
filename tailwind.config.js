// Config única de Tailwind para REFRIMAR (antes cada página usaba el CDN).
// Reconstruir el CSS:  npx tailwindcss@3.4.17 -c tools/tailwind.config.js -i tools/tailwind.in.css -o css/tailwind.css --minify
const v = (n) => `rgb(var(--${n}) / <alpha-value>)`;
module.exports = {
  content: ['./*.html', './*.js', './js/*.js'],
  theme: {
    extend: {
      colors: Object.fromEntries(['primary-container', 'on-primary-container', 'secondary', 'error', 'on-error', 'primary',
        'surface-container-lowest', 'surface-container-low', 'surface-container', 'surface-container-high', 'surface-container-highest',
        'surface', 'background', 'on-background', 'on-surface-variant', 'outline-variant', 'outline'].map((k) => [k, v(k)])),
      spacing: { base: '4px', xs: '4px', sm: '8px', md: '16px', lg: '24px', xl: '48px', gutter: '20px' }
    }
  },
  plugins: [require('@tailwindcss/forms'), require('@tailwindcss/container-queries')]
};
