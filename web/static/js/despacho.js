// Despacho: flujo de un envío con los procedimientos de sql/04 y los triggers de sql/03.
const { api, fmt, fecha, esc, estado } = SkyNest;
const $ = (id) => document.getElementById(id);
let distritos = [], codigoPaquete = null, idVuelo = null, vuelo = null;

function mensaje(id, texto, tipo) {
  $(id).innerHTML = texto ? `<div class="mensaje mensaje-${tipo}">${texto}</div>` : '';
}

function registrar(op, ok, detalle) {
  const caja = $('registro');
  const vacio = document.getElementById('registro-vacio');
  if (vacio) vacio.remove();
  const hora = new Date().toLocaleTimeString('es-PE');
  caja.insertAdjacentHTML('afterbegin', `<div style="display: flex; gap: 10px; align-items: baseline">
    <span class="texto-gris num">${hora}</span><code>${esc(op)}</code>
    <span style="color: ${ok ? '#1E7B45' : '#C2362F'}">${ok ? '✓' : '✗'} ${esc(detalle)}</span></div>`);
}

// ---- Paso 1: cliente, distrito y paquete ----
let temporizador = null;
$('cliente-q').addEventListener('input', () => {
  clearTimeout(temporizador);
  temporizador = setTimeout(async () => {
    const q = $('cliente-q').value.trim();
    if (q.length < 2) { $('cliente-res').innerHTML = ''; return; }
    const r = await api(`/api/clientes?q=${encodeURIComponent(q)}`);
    $('cliente-res').innerHTML = r.map((c) => `<button type="button" data-id="${c.id_cliente}" data-n="${esc(c.nombre)}">
      <strong>${esc(c.nombre)}</strong> · ${c.tipo} · ${esc(c.email)}</button>`).join('') || '<span class="texto-gris">Sin resultados</span>';
    $('cliente-res').querySelectorAll('button').forEach((b) => b.addEventListener('click', () => {
      $('id-cliente').value = b.dataset.id;
      $('cliente-q').value = b.dataset.n;
      $('cliente-res').innerHTML = '';
    }));
  }, 250);
});

async function cargarRutas() {
  const r = await api(`/api/rutas?ubigeo=${$('distrito').value}`);
  $('ruta').innerHTML = r.map((x) => `<option value="${x.id_ruta}">${esc(x.codigo)} · desde ${esc(x.nest)} · ${fmt(x.distancia_km, 1)} km</option>`).join('');
}
$('distrito').addEventListener('change', cargarRutas);

async function registrarPaquete(extra = {}) {
  const cuerpo = {
    id_cliente: Number($('id-cliente').value), ubigeo_destino: $('distrito').value,
    peso_kg: Number($('peso').value), prioridad: $('prioridad').value,
    destinatario: $('destinatario').value, telefono: $('telefono').value, direccion: $('direccion').value, ...extra,
  };
  const r = await api('/api/paquetes', { method: 'POST', body: cuerpo });
  registrar('sp_registrar_paquete', true, `${r.codigo_tracking} (${fmt(cuerpo.peso_kg, 1)} kg)`);
  return r.codigo_tracking;
}

$('f-paquete').addEventListener('submit', async (e) => {
  e.preventDefault();
  if (!$('id-cliente').value) { mensaje('m-paquete', 'Elige un cliente de la lista.', 'error'); return; }
  try {
    codigoPaquete = await registrarPaquete();
    mensaje('m-paquete', `Paquete <strong>${codigoPaquete}</strong> registrado. Estado: ${estado('registrado')}`, 'ok');
  } catch (err) {
    registrar('sp_registrar_paquete', false, err.message);
    mensaje('m-paquete', esc(err.message), 'error');
  }
});

// ---- Paso 2: programar vuelo ----
$('f-vuelo').addEventListener('submit', async (e) => {
  e.preventDefault();
  try {
    mensaje('m-vuelo', 'Buscando drone, batería y operador…', 'info');
    vuelo = await api('/api/vuelos', { method: 'POST', body: { id_ruta: Number($('ruta').value), fecha: $('fecha').value, tipo_operacion: $('tipo').value } });
    idVuelo = vuelo.id_vuelo;
    registrar('sp_programar_vuelo', true, `vuelo ${idVuelo}: drone ${vuelo.id_drone}, batería ${vuelo.bateria}`);
    mensaje('m-vuelo', `Vuelo <strong>${idVuelo}</strong> programado.`, 'ok');
    mostrarVuelo();
  } catch (err) {
    registrar('sp_programar_vuelo', false, err.message);
    mensaje('m-vuelo', esc(err.message), 'error');
  }
});

// ---- Paso 3: el vuelo ----
function mostrarVuelo() {
  $('panel-vuelo').classList.remove('oculto');
  $('v-id').textContent = vuelo.id_vuelo;
  $('v-estado').innerHTML = estado(vuelo.estado);
  const filas = [
    ['Ruta', `${esc(vuelo.ruta)} · ${esc(vuelo.nest)} → ${esc(vuelo.distrito)}`],
    ['Programado', fecha(vuelo.fecha_programada)],
    ['Drone', `${vuelo.id_drone} · ${esc(vuelo.modelo)} (carga útil ${fmt(vuelo.carga_util_max_kg, 2)} kg) · ${estado(vuelo.estado_drone)}`],
    ['Horas de vuelo del drone', fmt(vuelo.horas_vuelo, 2)],
    ['Batería', `${esc(vuelo.bateria)} · ${estado(vuelo.estado_bateria)}`],
    ['Ciclos y salud de la batería', `${fmt(vuelo.ciclos_carga)} ciclos · ${fmt(vuelo.salud_pct, 2)} %`],
    ['Operador', esc(vuelo.operador)],
    ['Permiso', vuelo.permiso ? esc(vuelo.permiso) : 'no requiere (distrito no restringido)'],
    ['Despegue / aterrizaje', `${fecha(vuelo.despegue)} / ${fecha(vuelo.aterrizaje)}`],
    ['Lecturas de telemetría', fmt(vuelo.lecturas)],
  ];
  $('v-ficha').innerHTML = filas.map(([k, v]) => `<div><span>${k}</span><span>${v}</span></div>`).join('');
  $('v-paquetes').innerHTML = vuelo.paquetes.map((p) => `<tr><td class="num">${esc(p.codigo_tracking)}</td>
    <td>${fmt(p.peso_kg, 2)} kg</td><td>${estado(p.estado)}</td><td>${fecha(p.fecha_entrega)}</td></tr>`).join('')
    || '<tr><td colspan="4" class="texto-gris">Sin paquetes todavía</td></tr>';
}

const ACCIONES = {
  asignar: async () => {
    if (!codigoPaquete) throw new Error('Primero registra un paquete en el paso 1.');
    return ['sp_asignar_paquete', `/api/vuelos/${idVuelo}/asignar`, { codigo_tracking: codigoPaquete }];
  },
  despegar: async () => ['sp_despegar_vuelo', `/api/vuelos/${idVuelo}/despegar`],
  lectura: async () => ['sp_registrar_lectura', `/api/vuelos/${idVuelo}/lectura`],
  cerrar: async () => ['sp_cerrar_vuelo', `/api/vuelos/${idVuelo}/cerrar`, { distancia_km: Number(vuelo.distancia_km) * 2, exitoso: true }],
  cancelar: async () => ['sp_cancelar_vuelo', `/api/vuelos/${idVuelo}/cancelar`],
  sobrepeso: async () => {
    const codigo = await registrarPaquete({ peso_kg: Math.min(999, Number(vuelo.carga_util_max_kg) + 5), ubigeo_destino: distritoDelVuelo() });
    return ['sp_asignar_paquete', `/api/vuelos/${idVuelo}/asignar`, { codigo_tracking: codigo }];
  },
  'otro-distrito': async () => {
    const otro = distritos.find((d) => d.ubigeo !== distritoDelVuelo());
    const codigo = await registrarPaquete({ peso_kg: 0.5, ubigeo_destino: otro.ubigeo });
    return ['sp_asignar_paquete', `/api/vuelos/${idVuelo}/asignar`, { codigo_tracking: codigo }];
  },
};
const distritoDelVuelo = () => distritos.find((d) => d.nombre === vuelo.distrito)?.ubigeo || $('distrito').value;

document.querySelectorAll('[data-a]').forEach((b) => b.addEventListener('click', async () => {
  let op = b.dataset.a;
  try {
    const [proc, ruta, cuerpo] = await ACCIONES[op]();
    op = proc;
    vuelo = await api(ruta, { method: 'POST', body: cuerpo || undefined });
    registrar(proc, true, `vuelo ${idVuelo}: ${vuelo.estado}`);
    mensaje('m-acciones', `${proc} ejecutado. Estados actualizados por los triggers.`, 'ok');
    mostrarVuelo();
  } catch (err) {
    registrar(op, false, err.message);
    mensaje('m-acciones', `<div><strong>La base rechazó la operación.</strong><br>${esc(err.message)}</div>`, 'error');
  }
}));

// ---- Inicio ----
function fechaPorDefecto() {
  const d = new Date(Date.now() + 24 * 3600 * 1000);
  d.setHours(10, 0, 0, 0);
  const p = (x) => String(x).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T10:00`;
}

SkyNest.iniciar('despacho', async () => {
  codigoPaquete = null; idVuelo = null;
  $('panel-vuelo').classList.add('oculto');
  ['m-paquete', 'm-vuelo', 'm-acciones'].forEach((m) => mensaje(m, '', ''));
  $('fecha').value = fechaPorDefecto();
  distritos = await api('/api/distritos');
  $('distrito').innerHTML = distritos.map((d) =>
    `<option value="${d.ubigeo}" ${d.nombre === 'Miraflores' ? 'selected' : ''}>${esc(d.nombre)}${d.zona_restringida ? ' · restringido (requiere permiso)' : ''}</option>`).join('');
  await cargarRutas();
  const c = await api('/api/clientes?q=a');
  if (c.length) { $('id-cliente').value = c[0].id_cliente; $('cliente-q').value = c[0].nombre; }
});
