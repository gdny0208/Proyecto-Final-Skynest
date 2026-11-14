// SkyNest · utilidades comunes: barra superior, selector de base, llamadas a la API y formatos.
const SkyNest = (() => {
  const LOGO = `<svg width="30" height="30" viewBox="0 0 34 34" fill="none" aria-hidden="true">
    <circle cx="17" cy="17" r="6" stroke="#1C1C1E" stroke-width="2.2"/>
    <circle cx="6" cy="6" r="3.5" stroke="#1C1C1E" stroke-width="2.2"/>
    <circle cx="28" cy="6" r="3.5" stroke="#1C1C1E" stroke-width="2.2"/>
    <circle cx="6" cy="28" r="3.5" stroke="#1C1C1E" stroke-width="2.2"/>
    <circle cx="28" cy="28" r="3.5" stroke="#1C1C1E" stroke-width="2.2"/>
    <path d="M9 9l4 4M25 9l-4 4M9 25l4-4M25 25l-4-4" stroke="#1C1C1E" stroke-width="2.2"/></svg>`;
  const PAGINAS = [['panel', '/', 'Panel'], ['rastrear', '/rastrear', 'Rastrear'],
                   ['despacho', '/despacho', 'Despacho'], ['laboratorio', '/laboratorio', 'Laboratorio de consultas']];
  let base = null;

  // localStorage puede no estar disponible: se usa con try/catch
  const guardar = (k, v) => { try { localStorage.setItem(k, v); } catch (e) { /* sin almacenamiento */ } };
  const leer = (k) => { try { return localStorage.getItem(k); } catch (e) { return null; } };

  function fmt(n, dec = 0) {
    if (n === null || n === undefined || Number.isNaN(Number(n))) return '–';
    const [ent, frac] = Number(n).toFixed(dec).split('.');
    const conGrupos = ent.replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
    return frac ? `${conGrupos},${frac}` : conGrupos;
  }
  function fecha(s) {
    if (!s) return '–';
    const d = new Date(s.replace(' ', 'T'));
    const p = (x) => String(x).padStart(2, '0');
    return `${p(d.getDate())}/${p(d.getMonth() + 1)}/${d.getFullYear()} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }
  const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const estado = (e) => `<span class="estado e-${esc(e)}">${esc(String(e).replace('_', ' '))}</span>`;
  const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  const nombreMes = (m) => { const [a, n] = m.split('-'); return `${MESES[Number(n) - 1]} ${a}`; };

  async function api(ruta, opciones = {}) {
    const sep = ruta.includes('?') ? '&' : '?';
    const url = ruta.startsWith('/api/bases') || ruta.startsWith('/api/consultas') && !opciones.conBase
      ? ruta : `${ruta}${sep}base=${encodeURIComponent(base)}`;
    const resp = await fetch(url, {
      method: opciones.method || 'GET',
      headers: opciones.body ? { 'Content-Type': 'application/json' } : {},
      body: opciones.body ? JSON.stringify(opciones.body) : undefined,
    });
    const datos = await resp.json().catch(() => ({}));
    if (!resp.ok) throw new Error(datos.detail || `Error ${resp.status}`);
    return datos;
  }

  async function iniciar(pagina, alCambiarBase) {
    const menu = PAGINAS.map(([id, href, txt]) =>
      `<a href="${href}" class="${id === pagina ? 'activo' : ''}" ${id === pagina ? 'aria-current="page"' : ''}>${txt}</a>`).join('');
    document.getElementById('cabecera').innerHTML = `
      <div class="contenedor">
        <a class="marca" href="/">${LOGO}<span>SKYNEST</span></a>
        <nav class="menu" aria-label="Secciones">${menu}</nav>
        <div class="selector-base">
          <label for="base" style="flex-direction: row; align-items: center">Base</label>
          <select id="base" class="pildora"><option>Cargando…</option></select>
        </div>
      </div>`;
    const sel = document.getElementById('base');
    try {
      const bases = await api('/api/bases');
      if (!bases.length) throw new Error('No hay bases skynest_* con datos. Ejecuta gen/construir_bases.sh');
      const guardada = leer('skynest_base');
      base = bases.some((b) => b.base === guardada) ? guardada : bases[bases.length - 1].base;
      sel.innerHTML = bases.map((b) =>
        `<option value="${b.base}" ${b.base === base ? 'selected' : ''}>${fmt(b.vuelos)} vuelos</option>`).join('');
      sel.addEventListener('change', () => { base = sel.value; guardar('skynest_base', base); alCambiarBase(base); });
      alCambiarBase(base);
    } catch (e) {
      sel.innerHTML = '<option>sin conexión</option>';
      const main = document.querySelector('main');
      if (main) main.insertAdjacentHTML('afterbegin',
        `<div class="contenedor" style="padding-top: 24px"><div class="mensaje mensaje-error">${esc(e.message)}</div></div>`);
    }
  }

  return { iniciar, api, fmt, fecha, esc, estado, nombreMes, obtenerBase: () => base };
})();
