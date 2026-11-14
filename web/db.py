"""
SkyNest web · db.py — conexión a PostgreSQL.

Los datos de conexión se toman de las variables de entorno estándar de
PostgreSQL (PGHOST, PGPORT, PGUSER, PGPASSWORD). Si existe un archivo .env en
la raíz del proyecto, se cargan desde ahí (ver .env.example).
"""
import os
import re
from contextlib import contextmanager

import psycopg2
import psycopg2.extras

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _cargar_env():
    ruta = os.path.join(RAIZ, '.env')
    if not os.path.exists(ruta):
        return
    for linea in open(ruta, encoding='utf-8'):
        linea = linea.strip()
        if linea and not linea.startswith('#') and '=' in linea:
            k, v = linea.split('=', 1)
            os.environ.setdefault(k.strip(), v.strip())


_cargar_env()

# Solo se permite conectar a las bases del proyecto
NOMBRE_VALIDO = re.compile(r'^skynest_[a-z0-9]+$')


def validar_base(base):
    if not NOMBRE_VALIDO.match(base or ''):
        raise ValueError(f'Base no válida: {base}')
    return base


@contextmanager
def conexion(base, autocommit=False):
    """Abre una conexión a la base indicada y la cierra al terminar.
    Sin autocommit: hace COMMIT si todo salió bien y ROLLBACK si hubo error."""
    conn = psycopg2.connect(dbname=validar_base(base))
    conn.autocommit = autocommit
    try:
        yield conn
        if not autocommit:
            conn.commit()
    except Exception:
        if not autocommit:
            conn.rollback()
        raise
    finally:
        conn.close()


def filas(cur):
    """Resultado de un cursor como lista de diccionarios."""
    cols = [d.name for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def consultar(base, sql, params=None):
    with conexion(base) as conn:
        cur = conn.cursor()
        cur.execute(sql, params)
        return filas(cur)


def listar_bases():
    """Bases skynest_* del servidor, ordenadas por tamaño."""
    conn = psycopg2.connect(dbname=os.environ.get('PGDATABASE', 'postgres'))
    try:
        cur = conn.cursor()
        cur.execute("SELECT datname, pg_database_size(datname) FROM pg_database "
                    "WHERE datname LIKE 'skynest\\_%' ORDER BY 2")
        return [r[0] for r in cur.fetchall() if NOMBRE_VALIDO.match(r[0])]
    finally:
        conn.close()


def mensaje_error(e):
    """Mensaje legible de un error de PostgreSQL (p. ej. el RAISE de un trigger)."""
    if isinstance(e, psycopg2.Error) and e.diag and e.diag.message_primary:
        return e.diag.message_primary
    return str(e).split('\n')[0]
