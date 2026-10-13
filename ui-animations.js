/* REFRIMAR — animaciones globales */
(function () {
  if (window.__refrimarAnim) return;
  window.__refrimarAnim = true;

  // 1. Presión + ripple en TODOS los botones
  document.addEventListener('pointerdown', function (e) {
    var b = e.target.closest('button, .btn, [role="button"]');
    if (!b) return;
    b.classList.add('anim-press');
    var r = b.getBoundingClientRect();
    var rip = document.createElement('span');
    rip.className = 'anim-ripple';
    var d = Math.max(r.width, r.height);
    rip.style.cssText = 'width:' + d + 'px;height:' + d + 'px;left:' + (e.clientX - r.left - d / 2) + 'px;top:' + (e.clientY - r.top - d / 2) + 'px';
    b.appendChild(rip);
    setTimeout(function () { rip.remove(); }, 500);
  });
  document.addEventListener('pointerup', function () {
    document.querySelectorAll('.anim-press').forEach(function (b) { b.classList.remove('anim-press'); });
  });

  // 2. Animación de BORRAR: cualquier botón con delete/eliminar/borrar en el onclick o icono "delete"
  //    Si el usuario cancela el confirm() (o el borrado falla y la fila sigue), la fila se restaura.
  var ultimoConfirm = null;
  var confirmOriginal = window.confirm;
  window.confirm = function (msg) {
    var r = confirmOriginal.call(window, msg);
    ultimoConfirm = r;
    return r;
  };
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
    setTimeout(function () {
      if (ultimoConfirm === false || !fila.isConnected) return;
      fila.classList.add('anim-out');
      setTimeout(function () { if (fila.isConnected) fila.classList.remove('anim-out'); }, 1600);
    }, 0);
  }, true);

  // 3. Botón de cobrar/pagar: pulso vivo
  setInterval(function () {
    document.querySelectorAll('button').forEach(function (b) {
      if (/cobrar|pagar|guardar venta|facturar/i.test(b.textContent)) b.classList.add('anim-pulse-glow');
    });
  }, 3000);
})();
