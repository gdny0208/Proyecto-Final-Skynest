#!/usr/bin/env python3
"""
SkyNest · generar.py — generador de datos sintéticos (sección 4.2 del informe)

Genera datos coherentes con todas las reglas del modelo y los carga con COPY.

Escala:  N = número de vuelos
         paquetes   ≈ 1,5·N  (+2 % de paquetes aún sin vuelo, estado 'registrado')
         telemetría ≈ 5 lecturas por vuelo que despegó (≈ 5·N)
         clientes   ≈ paquetes / 15  (proporción del Hito 1: 900 000 / 60 000)
Fijas en todas las escalas (proporciones del Hito 1):
         300 drones (10 por nest), 900 baterías (3 por drone), 120 operadores
         (4 por nest), 600 rutas (20 por nest) con sus puntos de ruta.

Requiere que la base ya tenga 01_schema.sql y 02_datos_reales.sql.

Uso:
    python gen/generar.py --db skynest_1k --n 1000
    python gen/generar.py --db skynest_1m --n 1000000 --csv dumps/csv_1m   # además guarda los CSV

Cómo se respetan las reglas (para el informe):
  R2/R10  cada drone tiene nest base y solo vuela rutas que salen de su nest
  R11     el operador es del mismo nest, con licencia vigente y autorización
          (operador, modelo, distrito) vigente en la fecha del vuelo
  R9      los vuelos a distritos restringidos llevan un permiso vigente del distrito
  R12     cada drone tiene 3 baterías propias y sus vuelos no se solapan
          (franjas de 40 min), así que una batería nunca está en dos vuelos a la vez
  R14     el distrito del paquete es el distrito destino de la ruta
  R15     el peso de los paquetes de un vuelo no supera la carga útil del modelo
  R17     las lecturas caen entre el despegue y el aterrizaje
  R19     los estados de paquete y vuelo son coherentes con sus fechas
Datos faltantes (sección 4.3):
  - 3 % de los vuelos completados pierde una lectura intermedia (falla de señal)
  - 5 % de los paquetes no tiene coordenadas de destino (lat/lon NULL)
"""

import argparse
import csv
import shutil
import tempfile
import math
import os
import random
import time
from datetime import datetime, timedelta

import numpy as np
import psycopg2
from faker import Faker

# ----------------------------------------------------------------------
# Parámetros generales
# ----------------------------------------------------------------------
SEMILLA = 2026
INICIO = datetime(2025, 1, 1)          # ventana de operación histórica
FIN = datetime(2026, 10, 31)
HOY = datetime(2026, 11, 14)            # fecha de "hoy" para vuelos futuros
HORA_APERTURA, HORA_CIERRE = 7, 21      # operación diaria 07:00-21:00
FRANJA_MIN = 40                         # cada vuelo ocupa una franja de 40 min de su drone

DRONES_POR_NEST = 10
BATERIAS_POR_DRONE = 3
OPERADORES_POR_NEST = 4
RUTAS_POR_NEST = 20
MAX_RUTA_KM = 9.0
VELOCIDAD_REF_KMH = 60                  # para la duración estimada de la ruta

# Paquetes por vuelo: P(0)=4 %, P(1)=45 %, P(2)=39 %, P(3)=12 %  -> media 1,59 sorteada;
# los que no caben por peso (R15) se descartan, y con los pendientes queda en ≈ 1,5
PAQ_VALORES = [0, 1, 2, 3]
PAQ_PROBS = [0.04, 0.45, 0.39, 0.12]
LECTURAS_POR_VUELO = 5

# Estados de vuelo
P_CANCELADO, P_ABORTADO, P_FUTURO = 0.01, 0.01, 0.01

# Composición de la flota (300 drones) por modelo (fabricante, nombre)
FLOTA = {
    ('Wing', 'Hummingbird'): 50, ('Zipline', 'P2 Zip'): 50,
    ('Matternet', 'M2'): 40, ('Matternet', 'M3'): 40,
    ('Wingcopter', '198'): 40, ('Manna', 'Octocóptero 4 kg'): 40,
    ('DJI', 'FlyCart 30'): 25, ('DJI', 'FlyCart 100'): 15,
}
# Batería por modelo: (química, capacidad_mAh, voltaje_nominal, corriente media A)
BATERIA_MODELO = {
    'Hummingbird': ('Li-ion', 5000, 22.2, 12), 'P2 Zip': ('Li-ion', 20000, 44.4, 25),
    'M2': ('Li-ion', 10000, 22.2, 15), 'M3': ('Li-ion', 16000, 44.4, 22),
    '198': ('LiHV', 22000, 44.4, 28), 'Octocóptero 4 kg': ('LiPo', 12000, 44.4, 30),
    'FlyCart 30': ('LiPo', 38000, 52.22, 90), 'FlyCart 100': ('LiPo', 43000, 52.22, 160),
}

# Distritos destino que no tienen nest: coordenadas aproximadas (restringidos)
COORD_EXTRA = {
    '150101': ('LIM', -12.046, -77.030),   # Lima Cercado
    '070101': ('CAL', -12.055, -77.125),   # Callao
    '070102': ('BEL', -12.060, -77.105),   # Bellavista
    '070103': ('CLR', -12.042, -77.090),   # Carmen de la Legua Reynoso
}


# ----------------------------------------------------------------------
# Utilidades
# ----------------------------------------------------------------------
def haversine_km(lat1, lon1, lat2, lon2):
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def ts(d):
    """Timestamp en formato de texto para COPY (None -> vacío = NULL)."""
    return '' if d is None else d.strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]


class Tabla:
    """Escribe las filas de una tabla en un CSV (en disco) para cargarlas con COPY."""
    def __init__(self, nombre, columnas, carpeta):
        self.nombre, self.columnas = nombre, columnas
        self.ruta = os.path.join(carpeta, f'{nombre}.csv')
        self.fh = open(self.ruta, 'w', encoding='utf-8', newline='')
        self.w = csv.writer(self.fh, lineterminator='\n')
        self.n = 0

    def add(self, *fila):
        self.w.writerow(['' if v is None else v for v in fila])
        self.n += 1


# ----------------------------------------------------------------------
# Generador
# ----------------------------------------------------------------------
class Generador:
    def __init__(self, conn, n_vuelos, carpeta):
        self.conn, self.N, self.carpeta = conn, n_vuelos, carpeta
        random.seed(SEMILLA)
        np.random.seed(SEMILLA)
        self.fake = Faker(['es_MX', 'es_CO'])
        Faker.seed(SEMILLA)
        self.leer_maestras()
        self.pool_nombres = [(self.fake.first_name(), self.fake.last_name() + ' ' + self.fake.last_name())
                             for _ in range(3000)]
        self.pool_calles = [self.fake.street_name() for _ in range(800)]

    # --- datos reales ya cargados por 02_datos_reales.sql ---
    def leer_maestras(self):
        cur = self.conn.cursor()
        cur.execute("SELECT ubigeo, nombre, zona_restringida, altitud_max_m FROM distrito")
        self.distritos = {u: dict(nombre=n, restringido=r, alt_max=float(a)) for u, n, r, a in cur.fetchall()}
        cur.execute("SELECT id_nest, codigo, latitud, longitud, ubigeo FROM estacion_nest ORDER BY id_nest")
        self.nests = [dict(id=i, cod=c.split('-')[1], lat=float(la), lon=float(lo), ubigeo=u)
                      for i, c, la, lo, u in cur.fetchall()]
        cur.execute("SELECT id_modelo, fabricante, nombre, carga_util_max_kg, velocidad_crucero_kmh, alcance_km "
                    "FROM modelo_drone ORDER BY id_modelo")
        self.modelos = {(f, n): dict(id=i, nombre=n, carga=float(c), vel=float(v), alcance=float(a))
                        for i, f, n, c, v, a in cur.fetchall()}
        if len(self.nests) != 30 or len(self.modelos) != 8:
            raise SystemExit('Faltan datos reales: ejecuta antes sql/02_datos_reales.sql')
        # coordenadas de referencia de los distritos destino posibles
        self.coord_distrito = {n['ubigeo']: (n['cod'], n['lat'], n['lon']) for n in self.nests}
        self.coord_distrito.update(COORD_EXTRA)

    # --- rutas y puntos de ruta ---
    def gen_rutas(self, T):
        self.rutas_por_nest = {}
        id_ruta = 0
        for nest in self.nests:
            destinos = []
            for ub, (cod, la, lo) in self.coord_distrito.items():
                d = haversine_km(nest['lat'], nest['lon'], la, lo) * 1.1   # 10 % de desvío
                if ub == nest['ubigeo']:
                    continue
                destinos.append((d, ub, cod, la, lo))
            destinos.sort()
            # destinos a <= 9 km; los nests periféricos (Lurín, Puente Piedra) toman sus 3 más cercanos
            cercanos = [x for x in destinos if x[0] <= MAX_RUTA_KM]
            destinos = cercanos if len(cercanos) >= 3 else destinos[:3]
            # 4 corredores dentro del propio distrito (rutas cortas) + el resto a distritos cercanos
            plan = [(random.uniform(1.5, 4.0), nest['ubigeo'], nest['cod'], nest['lat'], nest['lon'])
                    for _ in range(4)]
            i = 0
            while len(plan) < RUTAS_POR_NEST:
                plan.append(destinos[i % len(destinos)])
                i += 1
            usados = {}
            rutas = []
            for dist, ub, cod, la, lo in plan:
                id_ruta += 1
                usados[cod] = usados.get(cod, 0) + 1
                codigo = f"R-{nest['cod']}-{cod}-{usados[cod]:02d}"
                dist = round(dist * random.uniform(0.98, 1.08), 2)
                alt_max = self.distritos[ub]['alt_max']
                alt = round(random.uniform(0.80, 0.95) * alt_max, 1)
                dur = math.ceil(dist / VELOCIDAD_REF_KMH * 60) + 2
                T['ruta_vuelo'].add(id_ruta, codigo, nest['id'], ub, f'{dist:.2f}', alt, dur, 'true')
                # destino concreto: dentro del propio distrito, a la distancia de la ruta;
                # en otro distrito, cerca de su punto de referencia
                if ub == nest['ubigeo']:
                    th, dk = random.uniform(0, 2 * math.pi), dist / 1.1
                    dlat = la + dk / 111.0 * math.cos(th)
                    dlon = lo + dk / (111.0 * math.cos(math.radians(la))) * math.sin(th)
                else:
                    dlat, dlon = la + random.uniform(-0.008, 0.008), lo + random.uniform(-0.008, 0.008)
                n_pts = random.randint(2, 12)
                for s in range(1, n_pts + 1):
                    f = (s - 1) / (n_pts - 1)
                    plat = nest['lat'] + f * (dlat - nest['lat']) + (random.uniform(-0.002, 0.002) if 1 < s < n_pts else 0)
                    plon = nest['lon'] + f * (dlon - nest['lon']) + (random.uniform(-0.002, 0.002) if 1 < s < n_pts else 0)
                    tipo = 'despegue' if s == 1 else ('entrega' if s == n_pts else 'paso')
                    palt = 0 if s == 1 else (round(min(30.0, alt), 1) if s == n_pts else alt)
                    T['punto_ruta'].add(id_ruta, s, f'{plat:.6f}', f'{plon:.6f}', palt, tipo)
                rutas.append(dict(id=id_ruta, ubigeo=ub, dist=dist, dur=dur, lat=dlat, lon=dlon))
            self.rutas_por_nest[nest['id']] = rutas

    # --- drones, baterías, operadores, autorizaciones ---
    def gen_flota(self, T):
        lista_modelos = [m for m, k in FLOTA.items() for _ in range(k)]
        random.shuffle(lista_modelos)
        self.drones, self.baterias = [], {}
        id_d = id_b = 0
        for nest in self.nests:
            for _ in range(DRONES_POR_NEST):
                id_d += 1
                mod = self.modelos[lista_modelos[id_d - 1]]
                qui, cap, volt, amp = BATERIA_MODELO[mod['nombre']]
                bats = []
                for _ in range(BATERIAS_POR_DRONE):
                    id_b += 1
                    bats.append(id_b)
                    self.baterias[id_b] = dict(qui=qui, cap=cap, volt=volt, usos=0)
                # rutas que este modelo puede hacer ida y vuelta con 20 % de reserva
                aptas = [r for r in self.rutas_por_nest[nest['id']] if 2 * r['dist'] <= 0.8 * mod['alcance']]
                if not aptas:
                    aptas = [min(self.rutas_por_nest[nest['id']], key=lambda r: r['dist'])]
                self.drones.append(dict(id=id_d, nest=nest['id'], modelo=mod, bats=bats, amp=amp,
                                        rutas=aptas, horas=random.uniform(5, 60)))
        # operadores (4 por nest)
        self.operadores_por_nest = {}
        dnis = random.sample(range(10_000_000, 80_000_000), OPERADORES_POR_NEST * len(self.nests))
        id_o = 0
        for nest in self.nests:
            ops = []
            for _ in range(OPERADORES_POR_NEST):
                id_o += 1
                nom, ape = random.choice(self.pool_nombres)
                # licencias vigentes durante toda la ventana; algunas vencen pronto (consulta de licencias)
                if random.random() < 0.10:
                    venc = HOY + timedelta(days=random.randint(17, 30))   # vigente para los vuelos ya programados
                else:
                    venc = datetime(2027, 1, 1) + timedelta(days=random.randint(0, 540))
                T['operador'].add(id_o, dnis[id_o - 1], nom, ape, f'op{id_o:03d}@skynest.pe',
                                  f'9{random.randint(10_000_000, 99_999_999)}', f'LIC-RPAS-{id_o:04d}',
                                  venc.date(), nest['id'])
                ops.append(id_o)
            self.operadores_por_nest[nest['id']] = ops
        # autorizaciones: cada operador, para cada modelo de su nest y cada distrito destino de sus rutas
        for nest in self.nests:
            modelos_nest = {d['modelo']['id'] for d in self.drones if d['nest'] == nest['id']}
            distritos_nest = {r['ubigeo'] for r in self.rutas_por_nest[nest['id']]}
            for op in self.operadores_por_nest[nest['id']]:
                for m in sorted(modelos_nest):
                    for ub in sorted(distritos_nest):
                        T['autorizacion'].add(op, m, ub, '2024-12-01', '2027-12-31')

    # --- permisos trimestrales para los distritos restringidos ---
    def gen_permisos(self, T):
        self.permisos = {}   # ubigeo -> lista de (id, inicio, fin)
        id_p = 0
        for ub, dat in sorted(self.distritos.items()):
            if not dat['restringido']:
                continue
            lst = []
            for anio in (2025, 2026):
                for q in range(4):
                    id_p += 1
                    ini = datetime(anio, 3 * q + 1, 1)
                    fin = datetime(anio + (q == 3), (3 * q + 3) % 12 + 1, 1) - timedelta(days=1)
                    estado = 'vigente' if ini <= HOY <= fin else ('vencido' if fin < HOY else 'vigente')
                    T['permiso_vuelo'].add(id_p, f'EXP-{anio}-{id_p:04d}', ub, ini.date(), fin.date(), estado)
                    lst.append((id_p, ini, fin + timedelta(days=1)))
            self.permisos[ub] = lst

    def permiso_para(self, ub, fecha):
        for id_p, ini, fin in self.permisos.get(ub, []):
            if ini <= fecha < fin:
                return id_p
        raise RuntimeError(f'sin permiso para {ub} en {fecha}')

    # --- clientes ---
    def gen_clientes(self, T, n_clientes):
        n_emp = n_clientes // 4
        dnis = random.sample(range(10_000_000, 99_999_999), n_clientes - n_emp)
        rucs = random.sample(range(100_000_000, 999_999_999), n_emp)
        for i in range(1, n_clientes + 1):
            alta = datetime(2024, 1, 1) + timedelta(minutes=random.randint(0, 365 * 24 * 60))
            T['cliente'].add(i, f'cliente{i:07d}@correo.pe', f'9{random.randint(10_000_000, 99_999_999)}', ts(alta))
            if i <= n_emp:
                nom, ape = random.choice(self.pool_nombres)
                razon = f'{self.fake.company()} S.A.C.'[:120]
                T['cliente_empresa'].add(i, f'20{rucs[i - 1]:09d}', razon, f'{nom} {ape.split()[0]}')
            else:
                nom, ape = random.choice(self.pool_nombres)
                T['cliente_persona'].add(i, dnis[i - n_emp - 1], nom, ape)
        # probabilidad de enviar: las empresas envían más (distribución sesgada)
        pesos = np.where(np.arange(1, n_clientes + 1) <= n_emp, 4.0, 1.0) * np.random.pareto(1.5, n_clientes) + 0.1
        self.prob_cliente = pesos / pesos.sum()
        self.n_clientes = n_clientes

    # --- vuelos, paquetes y telemetría ---
    def gen_operacion(self, T):
        N = self.N
        dias = (FIN - INICIO).days + 1
        franjas_dia = (HORA_CIERRE - HORA_APERTURA) * 60 // FRANJA_MIN
        n_franjas = dias * franjas_dia
        # reparto de los N vuelos entre los 300 drones
        por_drone = [N // len(self.drones)] * len(self.drones)
        for i in range(N % len(self.drones)):
            por_drone[i] += 1
        if max(por_drone) > n_franjas:
            raise SystemExit('N demasiado grande para la ventana de tiempo')

        # sorteo de paquetes por vuelo y clientes de antemano (vectorizado)
        n_paq_vuelo = np.random.choice(PAQ_VALORES, size=N, p=PAQ_PROBS)
        total_paq = int(n_paq_vuelo.sum())
        clientes = np.random.choice(self.n_clientes, size=total_paq + N // 50 + 1, p=self.prob_cliente) + 1
        ic = 0

        id_v = id_p = 0
        for dron, k in zip(self.drones, por_drone):
            mod = dron['modelo']
            franjas = sorted(random.sample(range(n_franjas), k))
            ops = self.operadores_por_nest[dron['nest']]
            for f in franjas:
                id_v += 1
                dia, j = divmod(f, franjas_dia)
                prog = INICIO + timedelta(days=dia, hours=HORA_APERTURA, minutes=j * FRANJA_MIN)
                ruta = random.choice(dron['rutas'])
                bat = dron['bats'][id_v % BATERIAS_POR_DRONE]
                op = random.choice(ops)
                tipo_op = 'automatico' if random.random() < 0.85 else 'manual'
                id_permiso = self.permiso_para(ruta['ubigeo'], prog) if self.distritos[ruta['ubigeo']]['restringido'] else None

                # estado del vuelo
                u = random.random()
                if u < P_FUTURO:              # programado a futuro (sin despegue)
                    estado = 'programado'
                    prog = HOY + timedelta(days=random.randint(1, 16),
                                           hours=random.randint(HORA_APERTURA, HORA_CIERRE - 1))
                    dron['futuro'] = True
                    self.baterias[bat]['futuro'] = True
                    if id_permiso is not None:
                        id_permiso = self.permiso_para(ruta['ubigeo'], prog)
                elif u < P_FUTURO + P_CANCELADO:
                    estado = 'cancelado'
                elif u < P_FUTURO + P_CANCELADO + P_ABORTADO:
                    estado = 'abortado'
                else:
                    estado = 'completado'

                despegue = aterrizaje = entrega = dist_real = None
                if estado in ('completado', 'abortado'):
                    despegue = prog + timedelta(seconds=random.randint(0, 60))
                    factor = min(1.45, max(0.8, random.gauss(1.0, 0.12)))   # cabe en la franja de 40 min
                    ida = ruta['dur'] * factor
                    if estado == 'completado':
                        total = 2 * ida + 1
                        dist_real = round(2 * ruta['dist'] * random.uniform(0.98, 1.12), 2)
                        entrega = despegue + timedelta(minutes=ida)
                    else:   # aborta a mitad de la ida y regresa
                        total = ida
                        dist_real = round(ruta['dist'] * random.uniform(0.4, 1.0), 2)
                    aterrizaje = despegue + timedelta(minutes=total)
                    dron['horas'] += total / 60
                    self.baterias[bat]['usos'] += 1
                T['vuelo'].add(id_v, dron['id'], bat, ruta['id'], op, id_permiso, ts(prog), ts(despegue),
                               ts(aterrizaje), estado, tipo_op, '' if dist_real is None else f'{dist_real:.2f}')

                # paquetes del vuelo (R14: mismo distrito; R15: peso <= carga útil)
                n_p = int(n_paq_vuelo[id_v - 1])
                restante = mod['carga']
                peso_total = 0.0
                for _ in range(n_p):
                    if restante < 0.2:
                        break
                    peso = round(min(restante, max(0.1, random.lognormvariate(0.0, 0.7)), 25.0), 2)
                    restante -= peso
                    peso_total += peso
                    id_p += 1
                    if estado == 'completado':
                        est_p = random.choices(['entregado', 'fallido', 'devuelto'], [0.97, 0.02, 0.01])[0]
                    elif estado == 'abortado':
                        est_p = random.choice(['fallido', 'devuelto'])
                    elif estado == 'programado':
                        est_p = 'asignado'
                    else:   # cancelado: el paquete vuelve a quedar sin vuelo
                        est_p = 'registrado'
                    registro = prog - timedelta(minutes=random.randint(15, 48 * 60))
                    fecha_ent = entrega if est_p == 'entregado' else None
                    self.add_paquete(T, id_p, int(clientes[ic]), None if est_p == 'registrado' else id_v,
                                     ruta, peso, est_p, registro, fecha_ent)
                    ic += 1

                # telemetría: 5 lecturas entre despegue y aterrizaje
                if despegue is not None:
                    self.add_telemetria(T, id_v, dron, bat, despegue, aterrizaje, dist_real, peso_total / mod['carga'],
                                        n=LECTURAS_POR_VUELO if estado == 'completado' else 3)
            # horas de vuelo y estado finales del drone
            dron['horas'] = round(dron['horas'], 2)

        # paquetes pendientes (sin vuelo todavía): ~2 % de N
        for _ in range(N // 50):
            id_p += 1
            nest = random.choice(self.nests)
            ruta = random.choice(self.rutas_por_nest[nest['id']])
            registro = HOY - timedelta(minutes=random.randint(10, 3 * 24 * 60))
            self.add_paquete(T, id_p, int(clientes[ic]), None, ruta,
                             round(max(0.1, random.lognormvariate(0.0, 0.7)), 2), 'registrado', registro, None)
            ic += 1

    def add_paquete(self, T, id_p, cliente, id_vuelo, ruta, peso, estado, registro, entrega):
        express = random.random() < 0.30
        dims = (round(random.uniform(10, 60), 1), round(random.uniform(10, 40), 1), round(random.uniform(5, 30), 1))
        nom, ape = random.choice(self.pool_nombres)
        direccion = f'{random.choice(self.pool_calles)} {random.randint(100, 3999)}'[:150]
        if random.random() < 0.05:            # dato faltante: sin coordenadas
            lat = lon = None
        else:
            lat = f"{ruta['lat'] + random.uniform(-0.004, 0.004):.6f}"
            lon = f"{ruta['lon'] + random.uniform(-0.004, 0.004):.6f}"
        costo = round(8 + 1.5 * ruta['dist'] + (5 if express else 0) + 1.0 * peso, 2)
        T['paquete'].add(id_p, f'SKY{id_p:09d}', cliente, id_vuelo, ruta['ubigeo'], f'{peso:.2f}', *dims,
                         'express' if express else 'estandar', 'true' if random.random() < 0.15 else 'false',
                         f'{nom} {ape}'[:100], f'9{random.randint(10_000_000, 99_999_999)}', direccion,
                         lat, lon, estado, ts(registro), ts(entrega), f'{costo:.2f}')

    def add_telemetria(self, T, id_v, dron, bat, t0, t1, dist, carga_rel, n):
        mod = dron['modelo']
        b = self.baterias[bat]
        consumo = (80 / mod['alcance']) * dist * (1 + 0.3 * carga_rel) * random.uniform(0.9, 1.1)
        soc0 = random.uniform(95, 100)
        soc1 = max(3.0, soc0 - consumo)
        temp0 = random.uniform(22, 30)
        sobrecalienta = random.random() < 0.02          # anomalía térmica (consulta de alertas)
        pierde = n == LECTURAS_POR_VUELO and random.random() < 0.03   # dato faltante: señal perdida
        hueco = random.randint(1, n - 2) if pierde else -1
        dur = (t1 - t0).total_seconds()
        for i in range(n):
            if i == hueco:
                continue
            f = i / (n - 1)
            soc = soc0 + f * (soc1 - soc0) + random.uniform(-0.3, 0.3)
            temp = temp0 + f * random.uniform(6, 14) + (random.uniform(25, 40) * math.sin(math.pi * f) if sobrecalienta else 0)
            volt = b['volt'] * (0.86 + 0.14 * soc / 100) + random.uniform(-0.15, 0.15)
            amp = dron['amp'] * random.uniform(0.8, 1.2) * (0.6 if f in (0.0, 1.0) else 1.0)
            T['telemetria_bateria'].add(id_v, ts(t0 + timedelta(seconds=f * dur)), f'{volt:.2f}', f'{amp:.2f}',
                                        f'{min(temp, 89.0):.2f}', f'{min(100.0, max(0.0, soc)):.2f}')

    # --- tablas que dependen del uso acumulado ---
    def cerrar_flota(self, T):
        for d in self.drones:
            estado = random.choices(['disponible', 'cargando', 'mantenimiento', 'baja'], [0.85, 0.08, 0.05, 0.02])[0]
            if d.get('futuro'):                 # R10: tiene vuelos programados -> disponible
                estado = 'disponible'
            fecha = (INICIO - timedelta(days=random.randint(30, 400))).date()
            mod = d['modelo']
            pref = ''.join(ch for ch in mod['nombre'] if ch.isalnum())[:6].upper()
            T['drone'].add(d['id'], f'{pref}-{d["id"]:06d}', f'RPAS-PE-{d["id"]:05d}', fecha, estado,
                           f'{d["horas"]:.2f}', mod['id'], d['nest'])
        for id_b, b in self.baterias.items():
            ciclos = b['usos'] + random.randint(0, 50)
            salud = 100 - ciclos * 0.02 - random.uniform(0, 4)
            if random.random() < 0.05:          # algunas celdas se degradan más rápido
                salud -= random.uniform(15, 35)
            if b.get('futuro'):                 # R12: asignada a un vuelo programado -> operativa
                salud = max(salud, random.uniform(75, 90))
            salud = round(max(40.0, min(100.0, salud)), 2)
            estado = 'operativa' if salud >= 70 else random.choice(['degradada', 'baja'])
            T['bateria'].add(id_b, f'BAT-{id_b:06d}', b['qui'], b['cap'], b['volt'], ciclos, f'{salud:.2f}', estado)

    # --- orquestación ---
    def generar(self):
        cols = {
            'drone': 'id_drone,numero_serie,registro_dgac,fecha_adquisicion,estado,horas_vuelo,id_modelo,id_nest_base',
            'bateria': 'id_bateria,numero_serie,quimica,capacidad_mah,voltaje_nominal_v,ciclos_carga,salud_pct,estado',
            'operador': 'id_operador,dni,nombres,apellidos,email,telefono,nro_licencia,venc_licencia,id_nest',
            'autorizacion': 'id_operador,id_modelo,ubigeo,fecha_emision,fecha_vencimiento',
            'cliente': 'id_cliente,email,telefono,fecha_registro',
            'cliente_persona': 'id_cliente,dni,nombres,apellidos',
            'cliente_empresa': 'id_cliente,ruc,razon_social,contacto',
            'ruta_vuelo': 'id_ruta,codigo,id_nest_origen,ubigeo_destino,distancia_km,altitud_crucero_m,duracion_est_min,activa',
            'punto_ruta': 'id_ruta,nro_secuencia,latitud,longitud,altitud_m,tipo',
            'permiso_vuelo': 'id_permiso,nro_expediente,ubigeo,fecha_emision,fecha_vencimiento,estado',
            'vuelo': 'id_vuelo,id_drone,id_bateria,id_ruta,id_operador,id_permiso,fecha_programada,despegue,'
                     'aterrizaje,estado,tipo_operacion,distancia_real_km',
            'paquete': 'id_paquete,codigo_tracking,id_cliente,id_vuelo,ubigeo_destino,peso_kg,largo_cm,ancho_cm,'
                       'alto_cm,prioridad,es_fragil,destinatario_nombre,destinatario_telefono,direccion_destino,'
                       'lat_destino,lon_destino,estado,fecha_registro,fecha_entrega,costo_envio',
            'telemetria_bateria': 'id_vuelo,marca_tiempo,voltaje_v,corriente_a,temperatura_c,carga_pct',
        }
        T = {t: Tabla(t, c, self.carpeta) for t, c in cols.items()}
        n_paq_esperado = int(self.N * 1.52)
        self.gen_rutas(T)
        self.gen_flota(T)
        self.gen_permisos(T)
        self.gen_clientes(T, max(50, n_paq_esperado // 15))
        self.gen_operacion(T)
        self.cerrar_flota(T)
        for t in T.values():
            t.fh.close()
        return T


# Orden de carga (padres antes que hijos)
ORDEN = ['ruta_vuelo', 'punto_ruta', 'drone', 'bateria', 'operador', 'autorizacion', 'permiso_vuelo',
         'cliente', 'cliente_persona', 'cliente_empresa', 'vuelo', 'paquete', 'telemetria_bateria']
SECUENCIAS = {'ruta_vuelo': 'id_ruta', 'drone': 'id_drone', 'bateria': 'id_bateria', 'operador': 'id_operador',
              'permiso_vuelo': 'id_permiso', 'cliente': 'id_cliente', 'vuelo': 'id_vuelo', 'paquete': 'id_paquete'}


def cargar(conn, T):
    cur = conn.cursor()
    cur.execute('TRUNCATE ' + ', '.join(reversed(ORDEN)) + ' RESTART IDENTITY CASCADE')
    # Carga masiva: se desactivan triggers y FK de la sesión (los datos ya son coherentes).
    # CHECK, UNIQUE, PK y EXCLUDE se siguen validando.
    cur.execute("SET session_replication_role = replica")
    for t in ORDEN:
        tabla = T[t]
        t0 = time.time()
        with open(tabla.ruta, encoding='utf-8') as fh:
            cur.copy_expert(f"COPY {t} ({tabla.columnas}) FROM STDIN WITH (FORMAT csv)", fh)
        print(f'  {t:<20} {tabla.n:>10,} filas   {time.time() - t0:6.1f} s')
    cur.execute("SET session_replication_role = DEFAULT")
    for t, col in SECUENCIAS.items():
        cur.execute(f"SELECT setval(pg_get_serial_sequence('{t}', '{col}'), (SELECT max({col}) FROM {t}))")
    conn.commit()
    conn.autocommit = True
    cur.execute('VACUUM ANALYZE')
    conn.autocommit = False


def main():
    ap = argparse.ArgumentParser(description='Generador de datos SkyNest')
    ap.add_argument('--db', required=True, help='nombre de la base (p. ej. skynest_1k)')
    ap.add_argument('--n', type=int, required=True, help='número de vuelos N')
    ap.add_argument('--host', default=None)
    ap.add_argument('--port', default=None)
    ap.add_argument('--user', default=None)
    ap.add_argument('--csv', default=None, help='carpeta donde guardar también los CSV (opcional)')
    a = ap.parse_args()

    conn = psycopg2.connect(dbname=a.db, host=a.host, port=a.port, user=a.user)
    t0 = time.time()
    print(f'Generando N = {a.n:,} vuelos para {a.db} ...')
    carpeta = a.csv or tempfile.mkdtemp(prefix='skynest_')
    os.makedirs(carpeta, exist_ok=True)
    T = Generador(conn, a.n, carpeta).generar()
    print(f'Generación: {time.time() - t0:.1f} s. Cargando con COPY:')
    cargar(conn, T)
    if not a.csv:
        shutil.rmtree(carpeta, ignore_errors=True)
    print(f'Listo en {time.time() - t0:.1f} s.')
    conn.close()


if __name__ == '__main__':
    main()
