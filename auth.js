/* ============================================================
   REFRIMAR AUTH SYSTEM - Fase 1
   ============================================================ */
const AUTH_KEY = 'refrimar_session';

const refrimarAuth = {
  setSession(user) {
    sessionStorage.setItem(AUTH_KEY, JSON.stringify(user));
  },
  
  getSession() {
    try {
      const s = sessionStorage.getItem(AUTH_KEY);
      return s ? JSON.parse(s) : null;
    } catch { return null; }
  },
  
  clearSession() {
    sessionStorage.removeItem(AUTH_KEY);
  },
  
  requireAuth(allowedRoles = []) {
    const user = this.getSession();
    if (!user) {
      window.location.replace('login.html');
      throw new Error('No autenticado');
    }
    if (allowedRoles.length > 0 && !allowedRoles.includes(user.rol)) {
      showToast('No tienes permiso para acceder aquí', 'error');
      setTimeout(() => window.location.replace('facturacion.html'), 1500);
      throw new Error('Sin permisos');
    }
    // Mostrar nombre de usuario en sidebar si existe el elemento
    const userBadge = document.getElementById('user-badge');
    if (userBadge) userBadge.textContent = `${user.nombre} • ${user.rol.toUpperCase()}`;
    return user;
  },
  
  logout() {
    this.clearSession();
    window.location.replace('login.html');
  }
};

window.refrimarAuth = refrimarAuth;

/* ============================================================
   TOAST NOTIFICATIONS
   ============================================================ */
function showToast(message, type = 'success', duration = 3000) {
  const colors = {
    success: 'bg-secondary text-white',
    error: 'bg-error text-white',
    warning: 'bg-amber-500 text-white',
    info: 'bg-primary text-white'
  };
  
  const toast = document.createElement('div');
  toast.className = `fixed top-4 right-4 z-[9999] px-4 py-3 rounded-lg shadow-xl font-mono-data text-sm flex items-center gap-2 transform translate-x-full transition-transform duration-300 ${colors[type] || colors.success}`;
  toast.innerHTML = `<span class="material-symbols-outlined text-base">${type === 'error' ? 'error' : type === 'warning' ? 'warning' : 'check_circle'}</span><span>${message}</span>`;
  
  document.body.appendChild(toast);
  requestAnimationFrame(() => toast.classList.remove('translate-x-full'));
  
  setTimeout(() => {
    toast.classList.add('translate-x-full');
    setTimeout(() => toast.remove(), 300);
  }, duration);
}

window.showToast = showToast;
