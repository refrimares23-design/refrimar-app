/* REFRIMAR — animaciones globales */
(function () {
  if (window.__refrimarAnim) return;
  window.__refrimarAnim = true;

  // v3.9.20: sin ripple ni pulso. El botón solo se hunde un poco al presionarlo (respuesta inmediata,
  // sin efectos que se repiten cientos de veces al día en la caja). :where() no le gana a ningún estilo propio.
  (function () {
    if (document.getElementById('ref-anim-css')) return;
    var st = document.createElement('style');
    st.id = 'ref-anim-css';
    st.textContent =
      ':where(button,.btn,[role="button"]){transition:transform 160ms cubic-bezier(.23,1,.32,1),background-color .15s ease,border-color .15s ease,color .15s ease}' +
      ':where(button,.btn,[role="button"]):where(:not(:disabled):active){transform:scale(.97)}' +
      '@keyframes refRowOut{to{opacity:0;transform:translateX(16px) scale(.98)}}' +
      '.anim-out{animation:refRowOut .2s cubic-bezier(.23,1,.32,1) forwards;pointer-events:none}' +
      '@media (prefers-reduced-motion: reduce){:where(button,.btn,[role="button"]):active{transform:none}.anim-out{animation-duration:.01ms}}';
    (document.head || document.documentElement).appendChild(st);
  })();

  // 2. Animación de BORRAR: cualquier botón con delete/eliminar/borrar en el onclick o icono "delete"
  //    Si el usuario cancela el confirm() (o el borrado falla y la fila sigue), la fila se restaura.
  var ultimoConfirm = null;
  var confirmOriginal = window.confirm;
  window.confirm = function (msg) {
    var r = confirmOriginal.call(window, msg);
    ultimoConfirm = r;
    return r;
  };
  window.__refSetConfirm = function (v) { ultimoConfirm = v; };
  document.addEventListener('click', function (e) {
    var b = e.target.closest('button, a');
    if (!b) return;
    var onclick = b.getAttribute('onclick') || '';
    var icono = b.querySelector('.material-symbols-outlined');
    var esBorrar = /delete|eliminar|borrar|remove/i.test(onclick) ||
                   (icono && icono.textContent.trim() === 'delete');
    if (!esBorrar) return;
    var fila = b.closest('tr, li, [data-codigo], .card, .group');
    if (!fila || fila.classList.contains('anim-out')) return;
    ultimoConfirm = null;
    setTimeout(function revisar() {
      if (document.querySelector('.ref-dlg-ov')) { setTimeout(revisar, 120); return; } // aviso propio abierto: esperar respuesta
      if (ultimoConfirm === false || !fila.isConnected) return;
      fila.classList.add('anim-out');
      setTimeout(function () { if (fila.isConnected) fila.classList.remove('anim-out'); }, 1600);
    }, 0);
  }, true);

})();
