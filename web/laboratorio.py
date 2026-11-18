"""
SkyNest web · laboratorio.py — ejecuta las 5 consultas del experimento con
distintos planes de índices (misma lógica que bench/experimento.py).

Lee las consultas de sql/07_consultas.sql y los planes de sql/08_indices.sql,
así la web siempre usa exactamente lo mismo que el informe.
"""
import os
import re
import statistics
import time

from db import RAIZ, conexion, filas

CORRIDAS = 3
TITULOS = {
    'C1': 'Tasa de entregas por nest y distrito',
    'C2': 'Consumo de batería por modelo y ruta',
    'C3': 'Baterías con temperatura anómala',
    'C4': 'Utilización de la flota vs su modelo',
    'C5': 'Paquetes express con retraso',
}


def _comentarios_y_cuerpo(bloque):
    lineas = bloque.strip().splitlines()
    coment = [l[2:].strip() for l in lineas if l.strip().startswith('--')]
    cuerpo = '\n'.join(l for l in lineas if not l.strip().startswith('--')).strip()
    return coment, cuerpo


def leer_consultas():
    """{'C1': {'titulo', 'descripcion', 'sql'}, ...}"""
    txt = open(os.path.join(RAIZ, 'sql', '07_consultas.sql'), encoding='utf-8').read()
    res = {}
    for m in re.finditer(r'-- @consulta (C\d)\n(.*?;)', txt, re.S):
        coment, sql = _comentarios_y_cuerpo(m.group(2))
        texto = ' '.join(coment)
        texto = re.sub(r'^C\d\.\s*', '', texto)
        partes = texto.split(' Tablas:')[0]
        res[m.group(1)] = {'id': m.group(1), 'titulo': TITULOS[m.group(1)], 'descripcion': partes,
                           'sql': sql.rstrip(';')}
    return res


def leer_planes():
    """{('C1','A'): {'descripcion', 'sentencias': [...]}, ...}"""
    txt = open(os.path.join(RAIZ, 'sql', '08_indices.sql'), encoding='utf-8').read()
    planes = {}
    for b in re.split(r'^-- @plan ', txt, flags=re.M)[1:]:
        cab, cuerpo = b.split('\n', 1)
        c, x = cab.split()[:2]
        coment, sql = _comentarios_y_cuerpo(cuerpo)
        sentencias = [s.strip() + ';' for s in sql.split(';') if s.strip().upper().startswith('CREATE')]
        planes[(c, x)] = {'descripcion': ' '.join(coment), 'sentencias': sentencias}
    return planes


def _nombre(stmt):
    return re.search(r'INDEX\s+(?:IF NOT EXISTS\s+)?(\w+)', stmt, re.I).group(1)


def _indices_extra(cur):
    cur.execute("""
        SELECT i.indexrelid::regclass::text
        FROM pg_index i JOIN pg_class t ON t.oid = i.indrelid
        WHERE t.relnamespace = 'skynest'::regnamespace
          AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid)""")
    return {r[0] for r in cur.fetchall()}


def preparar(cur, sentencias):
    """Deja en la base exactamente los índices de la condición pedida.
    Devuelve los segundos que tomó crear índices (0 si ya estaban)."""
    deseados = {_nombre(s) for s in sentencias}
    actuales = _indices_extra(cur)
    if actuales == deseados:
        return 0.0
    for ix in actuales - deseados:
        cur.execute(f'DROP INDEX IF EXISTS {ix}')
    t0 = time.perf_counter()
    for s in sentencias:
        cur.execute(s)
    seg = time.perf_counter() - t0
    for t in ('vuelo', 'paquete', 'telemetria_bateria'):
        cur.execute(f'ANALYZE {t}')
    return seg


def _tiempo(cur, sql):
    cur.execute('EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) ' + sql)
    return cur.fetchone()[0][0]['Execution Time']


def ejecutar(base, cid, condicion, rpc=False, limite=100):
    consultas, planes = leer_consultas(), leer_planes()
    q = consultas[cid]
    sentencias = planes[(cid, condicion)]['sentencias'] if condicion in ('A', 'B') else []
    with conexion(base, autocommit=True) as conn:
        cur = conn.cursor()
        seg_indices = preparar(cur, sentencias)
        if rpc:
            cur.execute('SET random_page_cost = 1.1')
        _tiempo(cur, q['sql'])                                   # calentamiento
        tiempos = [_tiempo(cur, q['sql']) for _ in range(CORRIDAS)]
        cur.execute('EXPLAIN (ANALYZE, BUFFERS) ' + q['sql'])
        plan = '\n'.join(r[0] for r in cur.fetchall())
        cur.execute(f"SELECT * FROM ({q['sql']}) t LIMIT {int(limite)}")
        resultado = filas(cur)
        cur.execute(f"SELECT count(*) FROM ({q['sql']}) t")
        total = cur.fetchone()[0]
        usados = sorted(set(re.findall(r'(?:Index Scan|Index Only Scan|Bitmap Index Scan)(?: Backward)? (?:using|on) (\w+)', plan)))
    return {
        'consulta': cid, 'condicion': condicion, 'rpc': rpc,
        'ms': statistics.median(tiempos), 'tiempos': tiempos,
        'indices_creados': [_nombre(s) for s in sentencias], 'seg_creacion': seg_indices,
        'indices_usados': usados, 'plan': plan,
        'columnas': list(resultado[0].keys()) if resultado else [], 'filas': resultado, 'total_filas': total,
    }


def comparar(base, cid, rpc=False):
    """Sin índices, plan A y plan B de la misma consulta (mediana de 3 corridas)."""
    consultas, planes = leer_consultas(), leer_planes()
    sql = consultas[cid]['sql']
    res = {}
    with conexion(base, autocommit=True) as conn:
        cur = conn.cursor()
        if rpc:
            cur.execute('SET random_page_cost = 1.1')
        for cond in ('sin', 'A', 'B'):
            sentencias = planes[(cid, cond)]['sentencias'] if cond != 'sin' else []
            preparar(cur, sentencias)
            _tiempo(cur, sql)
            res[cond] = statistics.median(_tiempo(cur, sql) for _ in range(CORRIDAS))
    return res


def estado_indices(base):
    with conexion(base, autocommit=True) as conn:
        return sorted(_indices_extra(conn.cursor()))
