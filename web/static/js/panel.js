// Panel: indicadores del mes a partir de vuelo, paquete, telemetría y las vistas.
const { api, fmt, fecha, esc, estado, nombreMes } = SkyNest;
const $ = (id) => document.getElementById(id);
let mesActual = null;

function dibujarMapa(nests) {
  // Proyección simple de latitud/longitud a un lienzo de 300 x 520 px
  const lat0 = -11.84, lat1 = -12.30, lon0 = -77.13, lon1 = -76.85;
  $('mapa').innerHTML = nests.map((n) => {
    const x = (n.longitud - lon0) / (lon1 - lon0) * 300;
    const y = (lat0 - n.latitud) / (lat0 - lat1) * 520;
    return `<span style="left: ${(x - 6).toFixed(0)}px; top: ${(y - 6).toFixed(0)}px" title="${esc(n.nombre)}"></span>`;
  }).join('');
  $('h-nests').textContent = `Red de ${nests.length} nests`;
}

async function cargar() {
  $('h-sobre').textContent = 'Consultando la base…';
  try {
    const d = await api('/api/panel' + (mesActual ? `?mes=${mesActual}` : ''));
    mesActual = d.mes;
    $('mes').innerHTML = d.meses.slice().reverse().map((m) =>
      `<option value="${m}" ${m === d.mes ? 'selected' : ''}>${nombreMes(m)}</option>`).join('');
    const k = d.kpis, a = d.atencion;
    $('h-sobre').textContent = 'Lima Metropolitana y Callao ·';
    $('h-entregados').textContent = fmt(k.entregados);
    $('h-detalle').textContent = `${fmt(k.tasa, 1)} % de éxito y ${fmt(k.min_entrega, 1)} minutos en promedio desde el despegue hasta la entrega, con ${fmt(k.drones)} drones en ${d.nests.length} nests.`;
    $('indicadores').innerHTML = [
      [`${fmt(k.tasa, 1)} %`, 'Tasa de éxito'], [`${fmt(k.min_entrega, 1)} min`, 'Entrega promedio'],
      [fmt(k.vuelos), `Vuelos en ${nombreMes(d.mes).split(' ')[0]}`], [fmt(k.enviados), 'Paquetes enviados'],
    ].map(([v, n]) => `<div class="indicador"><span class="valor num">${v}</span><span class="nombre">${n}</span></div>`).join('');

    $('t-vuelos').textContent = `${fmt(k.vuelos)} vuelos en ${nombreMes(d.mes)}`;
    const max = Math.max(1, ...d.semanas.map((s) => s.vuelos));
    $('semanas').innerHTML = d.semanas.map((s) => {
      const [, m, dd] = s.semana.split('-');
      return `<div class="col"><span class="num">${fmt(s.vuelos)}</span>
        <div class="barra" style="height: ${Math.round(s.vuelos / max * 130)}px"></div><span>${dd}/${m}</span></div>`;
    }).join('');
    $('distritos').innerHTML = d.distritos.map((x) =>
      `<div><span>${esc(x.nombre)}</span><span class="num" style="color: #3A3A3C">${fmt(x.entregas)}</span></div>`).join('')
      || '<p class="texto-gris">Sin entregas en este mes.</p>';
    $('vuelos').innerHTML = d.vuelos.map((v) => `<tr>
        <td class="num">${v.id_vuelo}</td><td style="font-weight: 500">${esc(v.ruta)}</td><td>${esc(v.modelo)}</td>
        <td>${fecha(v.despegue)}</td><td>${v.minutos ?? '–'} min</td><td>${estado(v.estado)}</td></tr>`).join('');
    $('a-alertas').textContent = fmt(a.alertas);
    $('a-licencias').textContent = fmt(a.licencias);
    $('a-programados').textContent = fmt(a.programados);
    $('a-drones').textContent = `${fmt(k.disponibles)} de ${fmt(k.drones)}`;
    dibujarMapa(d.nests);
  } catch (e) {
    $('h-sobre').textContent = 'Error: ' + e.message;
  }
}

$('mes').addEventListener('change', (e) => { mesActual = e.target.value; cargar(); });
SkyNest.iniciar('panel', () => { mesActual = null; cargar(); });
