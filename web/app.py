"""
SkyNest web · app.py — MVP web conectado a PostgreSQL (puntos extra del Hito 2).

Backend en FastAPI. No agrega lógica de negocio: usa las vistas, los
procedimientos almacenados y los triggers de sql/ (la base valida todo) y las
5 consultas de sql/07_consultas.sql.

Ejecutar desde la raíz del proyecto:
    .venv/bin/uvicorn web.app:app --reload
y abrir http://localhost:8000
"""
import os
import sys
from datetime import date, datetime, timedelta
from decimal import Decimal

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import laboratorio  # noqa: E402
from db import conexion, consultar, filas, listar_bases, mensaje_error, validar_base  # noqa: E402

app = FastAPI(title='SkyNest', description='MVP web del Proyecto Final de Base de Datos I')
ESTATICOS = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'static')


# ----------------------------------------------------------------------
# Utilidades
# ----------------------------------------------------------------------
def limpiar(x):
    """Convierte Decimal y fechas a tipos JSON."""
    if isinstance(x, list):
        return [limpiar(i) for i in x]
    if isinstance(x, dict):
        return {k: limpiar(v) for k, v in x.items()}
    if isinstance(x, Decimal):
        return float(x)
    if isinstance(x, (datetime, date)):
        return x.isoformat(sep=' ') if isinstance(x, datetime) else x.isoformat()
    return x


def error_bd(e):
    raise HTTPException(status_code=400, detail=mensaje_error(e))


def base_param(base: str = Query(..., description='skynest_1k, skynest_10k, skynest_100k o skynest_1m')):
    try:
        return validar_base(base)
    except ValueError as e:
        raise HTTPException(400, str(e))


# ----------------------------------------------------------------------
# Páginas
# ----------------------------------------------------------------------
@app.get('/', include_in_schema=False)
def pagina_panel():
    return FileResponse(os.path.join(ESTATICOS, 'index.html'))


def _pagina(nombre):
    def servir():
        return FileResponse(os.path.join(ESTATICOS, f'{nombre}.html'))
    return servir


for _pag in ('rastrear', 'despacho', 'laboratorio'):
    app.add_api_route(f'/{_pag}', _pagina(_pag), include_in_schema=False)

app.mount('/static', StaticFiles(directory=ESTATICOS), name='static')


# ----------------------------------------------------------------------
# Bases disponibles
# ----------------------------------------------------------------------
_meses_cache = {}


@app.get('/api/bases')
def api_bases():
    res = []
    for b in listar_bases():
        try:
            n = consultar(b, "SELECT count(*) AS n FROM vuelo")[0]['n']
        except Exception:  # noqa: BLE001  base sin el esquema
            continue
        if n:
            res.append({'base': b, 'vuelos': n})
    return res


def meses_de(base):
    if base not in _meses_cache:
        r = consultar(base, "SELECT min(despegue)::date AS ini, max(despegue)::date AS fin FROM vuelo")[0]
        meses, d = [], r['ini'].replace(day=1)
        while d <= r['fin']:
            meses.append(d.strftime('%Y-%m'))
            d = (d + timedelta(days=32)).replace(day=1)
        _meses_cache[base] = meses
    return _meses_cache[base]


# ----------------------------------------------------------------------
# Panel
# ----------------------------------------------------------------------
@app.get('/api/panel')
def api_panel(base: str = Query(...), mes: str | None = None):
    base = base_param(base)
    meses = meses_de(base)
    mes = mes if mes in meses else meses[-1]
    ini = datetime.strptime(mes + '-01', '%Y-%m-%d')
    fin = (ini + timedelta(days=32)).replace(day=1)
    p = {'ini': ini, 'fin': fin}
    try:
        with conexion(base) as conn:
            cur = conn.cursor()
            cur.execute("""
                SELECT count(*) AS enviados,
                       count(*) FILTER (WHERE p.estado = 'entregado') AS entregados,
                       round(100.0 * count(*) FILTER (WHERE p.estado = 'entregado') / NULLIF(count(*), 0), 1) AS tasa,
                       round(avg(EXTRACT(EPOCH FROM (p.fecha_entrega - v.despegue)) / 60)::numeric, 1) AS min_entrega
                FROM paquete p JOIN vuelo v ON v.id_vuelo = p.id_vuelo
                WHERE v.despegue >= %(ini)s AND v.despegue < %(fin)s""", p)
            kpis = filas(cur)[0]
            cur.execute("""SELECT count(*) AS vuelos FROM vuelo WHERE despegue >= %(ini)s AND despegue < %(fin)s""", p)
            kpis.update(filas(cur)[0])
            cur.execute("SELECT count(*) AS drones, count(*) FILTER (WHERE estado = 'disponible') AS disponibles FROM drone")
            kpis.update(filas(cur)[0])
            cur.execute("""
                SELECT date_trunc('week', despegue)::date AS semana, count(*) AS vuelos
                FROM vuelo WHERE despegue >= %(ini)s AND despegue < %(fin)s
                GROUP BY 1 ORDER BY 1""", p)
            semanas = filas(cur)
            cur.execute("""
                SELECT d.nombre, count(*) AS entregas
                FROM paquete p JOIN vuelo v ON v.id_vuelo = p.id_vuelo JOIN distrito d ON d.ubigeo = p.ubigeo_destino
                WHERE p.estado = 'entregado' AND v.despegue >= %(ini)s AND v.despegue < %(fin)s
                GROUP BY d.nombre ORDER BY 2 DESC LIMIT 5""", p)
            distritos = filas(cur)
            cur.execute("""
                SELECT v.id_vuelo, r.codigo AS ruta, m.fabricante || ' ' || m.nombre AS modelo, v.estado,
                       v.despegue, round(EXTRACT(EPOCH FROM (v.aterrizaje - v.despegue)) / 60) AS minutos
                FROM vuelo v JOIN ruta_vuelo r ON r.id_ruta = v.id_ruta
                JOIN drone d ON d.id_drone = v.id_drone JOIN modelo_drone m ON m.id_modelo = d.id_modelo
                WHERE v.despegue >= %(ini)s AND v.despegue < %(fin)s
                ORDER BY v.despegue DESC LIMIT 5""", p)
            vuelos = filas(cur)
            cur.execute("""SELECT count(*) AS alertas FROM telemetria_bateria
                           WHERE temperatura_c > 60 AND marca_tiempo >= %(ini)s AND marca_tiempo < %(fin)s""", p)
            atencion = filas(cur)[0]
            cur.execute("SELECT count(*) AS programados FROM vuelo WHERE estado = 'programado'")
            atencion.update(filas(cur)[0])
            cur.execute("SELECT count(*) AS licencias FROM v_licencias_por_vencer")
            atencion.update(filas(cur)[0])
            cur.execute("SELECT codigo, nombre, latitud, longitud FROM estacion_nest ORDER BY id_nest")
            nests = filas(cur)
    except Exception as e:  # noqa: BLE001
        error_bd(e)
    return limpiar({'mes': mes, 'meses': meses, 'kpis': kpis, 'semanas': semanas, 'distritos': distritos,
                    'vuelos': vuelos, 'atencion': atencion, 'nests': nests})


# ----------------------------------------------------------------------
# Rastrear paquete
# ----------------------------------------------------------------------
@app.get('/api/rastrear/{codigo}')
def api_rastrear(codigo: str, base: str = Query(...)):
    base = base_param(base)
    try:
        r = consultar(base, "SELECT * FROM fn_rastrear_paquete(%s)", (codigo.strip().upper(),))
    except Exception as e:  # noqa: BLE001
        error_bd(e)
    if not r:
        raise HTTPException(404, f'No existe el paquete {codigo}')
    extra = consultar(base, """
        SELECT p.peso_kg, p.prioridad, p.destinatario_nombre, v.id_vuelo, r.codigo AS ruta, r.duracion_est_min,
               n.nombre AS nest_origen, m.fabricante || ' ' || m.nombre AS modelo
        FROM paquete p
        LEFT JOIN vuelo v ON v.id_vuelo = p.id_vuelo
        LEFT JOIN ruta_vuelo r ON r.id_ruta = v.id_ruta
        LEFT JOIN estacion_nest n ON n.id_nest = r.id_nest_origen
        LEFT JOIN drone d ON d.id_drone = v.id_drone
        LEFT JOIN modelo_drone m ON m.id_modelo = d.id_modelo
        WHERE p.codigo_tracking = %s""", (codigo.strip().upper(),))[0]
    return limpiar({**r[0], **extra})


@app.get('/api/ejemplos')
def api_ejemplos(base: str = Query(...)):
    """Algunos códigos de tracking reales para probar el rastreo."""
    base = base_param(base)
    return consultar(base, """
        (SELECT codigo_tracking, estado FROM paquete WHERE estado = 'entregado' ORDER BY id_paquete LIMIT 1)
        UNION ALL (SELECT codigo_tracking, estado FROM paquete WHERE estado = 'asignado' ORDER BY id_paquete LIMIT 1)
        UNION ALL (SELECT codigo_tracking, estado FROM paquete WHERE estado = 'fallido' ORDER BY id_paquete LIMIT 1)
        UNION ALL (SELECT codigo_tracking, estado FROM paquete WHERE estado = 'registrado' ORDER BY id_paquete DESC LIMIT 1)""")


# ----------------------------------------------------------------------
# Despacho (procedimientos almacenados + triggers)
# ----------------------------------------------------------------------
@app.get('/api/distritos')
def api_distritos(base: str = Query(...)):
    base = base_param(base)
    return limpiar(consultar(base, """
        SELECT d.ubigeo, d.nombre, d.zona_restringida, count(r.id_ruta) AS rutas
        FROM distrito d JOIN ruta_vuelo r ON r.ubigeo_destino = d.ubigeo AND r.activa
        GROUP BY d.ubigeo, d.nombre, d.zona_restringida ORDER BY d.nombre"""))


@app.get('/api/rutas')
def api_rutas(base: str = Query(...), ubigeo: str = Query(...)):
    base = base_param(base)
    return limpiar(consultar(base, """
        SELECT r.id_ruta, r.codigo, n.nombre AS nest, r.distancia_km, r.duracion_est_min
        FROM ruta_vuelo r JOIN estacion_nest n ON n.id_nest = r.id_nest_origen
        WHERE r.ubigeo_destino = %s AND r.activa ORDER BY r.distancia_km""", (ubigeo,)))


@app.get('/api/clientes')
def api_clientes(base: str = Query(...), q: str = ''):
    base = base_param(base)
    patron = f'%{q.strip()}%'
    return consultar(base, """
        SELECT c.id_cliente, COALESCE(e.razon_social, p.nombres || ' ' || p.apellidos) AS nombre,
               CASE WHEN e.id_cliente IS NOT NULL THEN 'empresa' ELSE 'persona' END AS tipo, c.email
        FROM cliente c
        LEFT JOIN cliente_persona p ON p.id_cliente = c.id_cliente
        LEFT JOIN cliente_empresa e ON e.id_cliente = c.id_cliente
        WHERE COALESCE(e.razon_social, p.nombres || ' ' || p.apellidos) ILIKE %s OR c.email ILIKE %s
        ORDER BY c.id_cliente LIMIT 8""", (patron, patron))


class NuevoPaquete(BaseModel):
    id_cliente: int
    ubigeo_destino: str
    peso_kg: float
    largo_cm: float = 30
    ancho_cm: float = 20
    alto_cm: float = 15
    prioridad: str = 'estandar'
    es_fragil: bool = False
    destinatario: str
    telefono: str
    direccion: str


@app.post('/api/paquetes')
def api_registrar_paquete(p: NuevoPaquete, base: str = Query(...)):
    base = base_param(base)
    try:
        with conexion(base) as conn:
            cur = conn.cursor()
            cur.execute("CALL sp_registrar_paquete(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,NULL,NULL,NULL)",
                        (p.id_cliente, p.ubigeo_destino, p.peso_kg, p.largo_cm, p.ancho_cm, p.alto_cm,
                         p.prioridad, p.es_fragil, p.destinatario, p.telefono, p.direccion))
            codigo = cur.fetchone()[0]
    except Exception as e:  # noqa: BLE001
        error_bd(e)
    return {'codigo_tracking': codigo}


class NuevoVuelo(BaseModel):
    id_ruta: int
    fecha: datetime
    tipo_operacion: str = 'automatico'


@app.post('/api/vuelos')
def api_programar_vuelo(v: NuevoVuelo, base: str = Query(...)):
    base = base_param(base)
    try:
        with conexion(base) as conn:
            cur = conn.cursor()
            cur.execute("CALL sp_programar_vuelo(%s, %s, %s, NULL)", (v.id_ruta, v.fecha, v.tipo_operacion))
            id_vuelo = cur.fetchone()[0]
    except Exception as e:  # noqa: BLE001
        error_bd(e)
    return detalle_vuelo(base, id_vuelo)


def detalle_vuelo(base, id_vuelo):
    with conexion(base) as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT v.id_vuelo, v.estado, v.fecha_programada, v.despegue, v.aterrizaje, v.tipo_operacion,
                   r.codigo AS ruta, r.distancia_km, dn.nombre AS distrito, n.nombre AS nest,
                   d.id_drone, d.estado AS estado_drone, d.horas_vuelo, m.fabricante || ' ' || m.nombre AS modelo,
                   m.carga_util_max_kg, b.id_bateria, b.numero_serie AS bateria, b.estado AS estado_bateria,
                   b.ciclos_carga, b.salud_pct, o.nombres || ' ' || o.apellidos AS operador,
                   pv.nro_expediente AS permiso
            FROM vuelo v
            JOIN ruta_vuelo r     ON r.id_ruta = v.id_ruta
            JOIN distrito dn      ON dn.ubigeo = r.ubigeo_destino
            JOIN estacion_nest n  ON n.id_nest = r.id_nest_origen
            JOIN drone d          ON d.id_drone = v.id_drone
            JOIN modelo_drone m   ON m.id_modelo = d.id_modelo
            JOIN bateria b        ON b.id_bateria = v.id_bateria
            JOIN operador o       ON o.id_operador = v.id_operador
            LEFT JOIN permiso_vuelo pv ON pv.id_permiso = v.id_permiso
            WHERE v.id_vuelo = %s""", (id_vuelo,))
        r = filas(cur)
        if not r:
            raise HTTPException(404, f'No existe el vuelo {id_vuelo}')
        cur.execute("""SELECT codigo_tracking, estado, peso_kg, fecha_entrega FROM paquete
                       WHERE id_vuelo = %s ORDER BY id_paquete""", (id_vuelo,))
        r[0]['paquetes'] = filas(cur)
        cur.execute("SELECT count(*) FROM telemetria_bateria WHERE id_vuelo = %s", (id_vuelo,))
        r[0]['lecturas'] = cur.fetchone()[0]
    return limpiar(r[0])


@app.get('/api/vuelos/{id_vuelo}')
def api_vuelo(id_vuelo: int, base: str = Query(...)):
    return detalle_vuelo(base_param(base), id_vuelo)


class Asignacion(BaseModel):
    codigo_tracking: str


class Cierre(BaseModel):
    distancia_km: float
    exitoso: bool = True


def _accion(base, id_vuelo, sql, params):
    try:
        with conexion(base) as conn:
            conn.cursor().execute(sql, params)
    except Exception as e:  # noqa: BLE001
        error_bd(e)
    return detalle_vuelo(base, id_vuelo)


@app.post('/api/vuelos/{id_vuelo}/asignar')
def api_asignar(id_vuelo: int, a: Asignacion, base: str = Query(...)):
    return _accion(base_param(base), id_vuelo, "CALL sp_asignar_paquete(%s, %s)", (a.codigo_tracking, id_vuelo))


@app.post('/api/vuelos/{id_vuelo}/despegar')
def api_despegar(id_vuelo: int, base: str = Query(...)):
    return _accion(base_param(base), id_vuelo, "CALL sp_despegar_vuelo(%s)", (id_vuelo,))


@app.post('/api/vuelos/{id_vuelo}/lectura')
def api_lectura(id_vuelo: int, base: str = Query(...)):
    """Simula una lectura de telemetría en vivo (el trigger R17 la valida)."""
    return _accion(base_param(base), id_vuelo,
                   "CALL sp_registrar_lectura(%s, 44.0, 22.5, 34.0, 88.0)", (id_vuelo,))


@app.post('/api/vuelos/{id_vuelo}/cerrar')
def api_cerrar(id_vuelo: int, c: Cierre, base: str = Query(...)):
    return _accion(base_param(base), id_vuelo, "CALL sp_cerrar_vuelo(%s, %s, %s)",
                   (id_vuelo, c.distancia_km, c.exitoso))


@app.post('/api/vuelos/{id_vuelo}/cancelar')
def api_cancelar(id_vuelo: int, base: str = Query(...)):
    return _accion(base_param(base), id_vuelo, "CALL sp_cancelar_vuelo(%s)", (id_vuelo,))


# ----------------------------------------------------------------------
# Laboratorio de consultas
# ----------------------------------------------------------------------
@app.get('/api/consultas')
def api_consultas():
    consultas, planes = laboratorio.leer_consultas(), laboratorio.leer_planes()
    for c, q in consultas.items():
        q['planes'] = {x: planes[(c, x)] for x in ('A', 'B')}
    return list(consultas.values())


@app.post('/api/consultas/{cid}/ejecutar')
def api_ejecutar(cid: str, base: str = Query(...), condicion: str = 'sin', rpc: bool = False):
    base = base_param(base)
    if cid not in ('C1', 'C2', 'C3', 'C4', 'C5') or condicion not in ('sin', 'A', 'B'):
        raise HTTPException(400, 'Consulta o condición no válida')
    try:
        return limpiar(laboratorio.ejecutar(base, cid, condicion, rpc))
    except Exception as e:  # noqa: BLE001
        error_bd(e)


@app.post('/api/consultas/{cid}/comparar')
def api_comparar(cid: str, base: str = Query(...), rpc: bool = False):
    base = base_param(base)
    if cid not in ('C1', 'C2', 'C3', 'C4', 'C5'):
        raise HTTPException(400, 'Consulta no válida')
    try:
        return laboratorio.comparar(base, cid, rpc)
    except Exception as e:  # noqa: BLE001
        error_bd(e)
