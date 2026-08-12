(function () {
  function initMobileTables() {
    var tables = document.querySelectorAll('table[data-mobile-cards]');
    Array.prototype.forEach.call(tables, function (tbl) {
      var head = tbl.querySelectorAll('thead th');
      var labels = Array.prototype.map.call(head, function (th) {
        return th.textContent.trim();
      });
      function labelize() {
        var rows = tbl.querySelectorAll('tbody tr');
        Array.prototype.forEach.call(rows, function (tr) {
          var cells = tr.children;
          for (var i = 0; i < cells.length; i++) {
            cells[i].setAttribute('data-label', labels[i] || '');
            cells[i].classList.remove('tbl-card-title', 'tbl-card-badge');
          }
          if (cells.length) cells[0].classList.add('tbl-card-title');
          for (var j = 0; j < labels.length; j++) {
            if (cells[j] && (labels[j] || '').toLowerCase().indexOf('estado') !== -1) {
              cells[j].classList.add('tbl-card-badge');
            }
          }
        });
      }
      labelize();
      var tbody = tbl.querySelector('tbody');
      if (tbody && window.MutationObserver) {
        new MutationObserver(labelize).observe(tbody, { childList: true });
      }
    });
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initMobileTables);
  } else {
    initMobileTables();
  }
})();
