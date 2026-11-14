-- =====================================================================
-- SkyNest · Proyecto Final CS2041 Base de Datos I · Grupo 3 · Tópico 4
-- 01_schema.sql : modelo físico en PostgreSQL 14
--
-- Traduce el diccionario de datos (sección 3.3 del Hito 1) tal cual:
-- mismos nombres, tipos, nulos y claves.
--   * Aquí van PK, FK, UNIQUE, CHECK de fila y el EXCLUDE de baterías.
--   * Las reglas que cruzan tablas (ii)-(vi), (viii)-(x), la cobertura
--     de la jerarquía de clientes (i), R5 y R6 van en 03_triggers.sql.
--   * No se crean índices adicionales: solo los automáticos de PK, UNIQUE
--     y EXCLUDE. Los índices del experimento van en 08_indices.sql.
--
-- Uso:  psql -d skynest_dev -f sql/01_schema.sql   (se puede re-ejecutar)
-- =====================================================================

\set ON_ERROR_STOP on

BEGIN;

-- Re-ejecutable: borra en orden inverso de dependencias
DROP TABLE IF EXISTS telemetria_bateria, paquete, vuelo, permiso_vuelo,
    punto_ruta, ruta_vuelo, cliente_empresa, cliente_persona, cliente,
    autorizacion, operador, bateria, drone, modelo_drone, estacion_nest,
    distrito CASCADE;

-- Necesaria para el EXCLUDE de vuelo (R12: batería sin vuelos solapados)
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------------------------------------------------------------------
-- 1. distrito
-- ---------------------------------------------------------------------
CREATE TABLE distrito (
    ubigeo            CHAR(6)       NOT NULL,
    nombre            VARCHAR(60)   NOT NULL,
    provincia         VARCHAR(30)   NOT NULL,
    zona_restringida  BOOLEAN       NOT NULL DEFAULT FALSE,
    altitud_max_m     NUMERIC(5,1)  NOT NULL DEFAULT 120,
    CONSTRAINT pk_distrito              PRIMARY KEY (ubigeo),
    CONSTRAINT ck_distrito_ubigeo       CHECK (ubigeo ~ '^[0-9]{6}$'),
    CONSTRAINT ck_distrito_provincia    CHECK (provincia IN ('Lima', 'Callao')),
    CONSTRAINT ck_distrito_altitud      CHECK (altitud_max_m > 0)
);

-- ---------------------------------------------------------------------
-- 2. estacion_nest
-- ---------------------------------------------------------------------
CREATE TABLE estacion_nest (
    id_nest           SERIAL        NOT NULL,
    codigo            VARCHAR(12)   NOT NULL,
    nombre            VARCHAR(80)   NOT NULL,
    direccion         VARCHAR(150)  NOT NULL,
    latitud           NUMERIC(9,6)  NOT NULL,
    longitud          NUMERIC(9,6)  NOT NULL,
    capacidad_drones  SMALLINT      NOT NULL,
    puertos_carga     SMALLINT      NOT NULL,
    estado            VARCHAR(15)   NOT NULL DEFAULT 'operativa',
    ubigeo            CHAR(6)       NOT NULL,
    CONSTRAINT pk_estacion_nest         PRIMARY KEY (id_nest),
    CONSTRAINT uq_estacion_nest_codigo  UNIQUE (codigo),
    CONSTRAINT fk_estacion_nest_distrito FOREIGN KEY (ubigeo) REFERENCES distrito (ubigeo),
    CONSTRAINT ck_estacion_nest_latitud  CHECK (latitud  BETWEEN -90  AND 90),
    CONSTRAINT ck_estacion_nest_longitud CHECK (longitud BETWEEN -180 AND 180),
    CONSTRAINT ck_estacion_nest_capacidad CHECK (capacidad_drones > 0),
    CONSTRAINT ck_estacion_nest_puertos  CHECK (puertos_carga >= 0),
    CONSTRAINT ck_estacion_nest_estado   CHECK (estado IN ('operativa', 'mantenimiento', 'inactiva'))
);

-- ---------------------------------------------------------------------
-- 3. modelo_drone
-- ---------------------------------------------------------------------
CREATE TABLE modelo_drone (
    id_modelo              SERIAL        NOT NULL,
    fabricante             VARCHAR(50)   NOT NULL,
    nombre                 VARCHAR(50)   NOT NULL,
    carga_util_max_kg      NUMERIC(5,2)  NOT NULL,
    autonomia_min          SMALLINT      NOT NULL,
    velocidad_crucero_kmh  NUMERIC(5,1)  NOT NULL,
    alcance_km             NUMERIC(5,1)  NOT NULL,
    CONSTRAINT pk_modelo_drone             PRIMARY KEY (id_modelo),
    CONSTRAINT uq_modelo_drone_fab_nombre  UNIQUE (fabricante, nombre),
    CONSTRAINT ck_modelo_drone_carga       CHECK (carga_util_max_kg > 0),
    CONSTRAINT ck_modelo_drone_autonomia   CHECK (autonomia_min > 0),
    CONSTRAINT ck_modelo_drone_velocidad   CHECK (velocidad_crucero_kmh > 0),
    CONSTRAINT ck_modelo_drone_alcance     CHECK (alcance_km > 0)
);

-- ---------------------------------------------------------------------
-- 4. drone
-- ---------------------------------------------------------------------
CREATE TABLE drone (
    id_drone           SERIAL        NOT NULL,
    numero_serie       VARCHAR(30)   NOT NULL,
    registro_dgac      VARCHAR(20)   NOT NULL,
    fecha_adquisicion  DATE          NOT NULL,
    estado             VARCHAR(15)   NOT NULL DEFAULT 'disponible',
    horas_vuelo        NUMERIC(8,2)  NOT NULL DEFAULT 0,
    id_modelo          INTEGER       NOT NULL,
    id_nest_base       INTEGER       NOT NULL,
    CONSTRAINT pk_drone                PRIMARY KEY (id_drone),
    CONSTRAINT uq_drone_numero_serie   UNIQUE (numero_serie),
    CONSTRAINT uq_drone_registro_dgac  UNIQUE (registro_dgac),
    CONSTRAINT fk_drone_modelo         FOREIGN KEY (id_modelo)    REFERENCES modelo_drone (id_modelo),
    CONSTRAINT fk_drone_nest_base      FOREIGN KEY (id_nest_base) REFERENCES estacion_nest (id_nest),
    CONSTRAINT ck_drone_estado         CHECK (estado IN ('disponible', 'en_vuelo', 'cargando', 'mantenimiento', 'baja')),
    CONSTRAINT ck_drone_horas          CHECK (horas_vuelo >= 0)
);

-- ---------------------------------------------------------------------
-- 5. bateria
-- ---------------------------------------------------------------------
CREATE TABLE bateria (
    id_bateria         SERIAL        NOT NULL,
    numero_serie       VARCHAR(30)   NOT NULL,
    quimica            VARCHAR(10)   NOT NULL,
    capacidad_mah      INTEGER       NOT NULL,
    voltaje_nominal_v  NUMERIC(5,2)  NOT NULL,
    ciclos_carga       INTEGER       NOT NULL DEFAULT 0,
    salud_pct          NUMERIC(5,2)  NOT NULL,
    estado             VARCHAR(12)   NOT NULL DEFAULT 'operativa',
    CONSTRAINT pk_bateria              PRIMARY KEY (id_bateria),
    CONSTRAINT uq_bateria_numero_serie UNIQUE (numero_serie),
    CONSTRAINT ck_bateria_quimica      CHECK (quimica IN ('LiPo', 'Li-ion', 'LiHV')),
    CONSTRAINT ck_bateria_capacidad    CHECK (capacidad_mah > 0),
    CONSTRAINT ck_bateria_voltaje      CHECK (voltaje_nominal_v > 0),
    CONSTRAINT ck_bateria_ciclos       CHECK (ciclos_carga >= 0),
    CONSTRAINT ck_bateria_salud        CHECK (salud_pct BETWEEN 0 AND 100),
    CONSTRAINT ck_bateria_estado       CHECK (estado IN ('operativa', 'degradada', 'baja')),
    -- R12: una batería con salud < 70 % no puede figurar como operativa
    CONSTRAINT ck_bateria_salud_estado CHECK (salud_pct >= 70 OR estado <> 'operativa')
);

-- ---------------------------------------------------------------------
-- 6. operador
-- ---------------------------------------------------------------------
CREATE TABLE operador (
    id_operador    SERIAL        NOT NULL,
    dni            CHAR(8)       NOT NULL,
    nombres        VARCHAR(60)   NOT NULL,
    apellidos      VARCHAR(60)   NOT NULL,
    email          VARCHAR(100)  NOT NULL,
    telefono       VARCHAR(15),
    nro_licencia   VARCHAR(20)   NOT NULL,
    venc_licencia  DATE          NOT NULL,
    id_nest        INTEGER       NOT NULL,
    CONSTRAINT pk_operador              PRIMARY KEY (id_operador),
    CONSTRAINT uq_operador_dni          UNIQUE (dni),
    CONSTRAINT uq_operador_email        UNIQUE (email),
    CONSTRAINT uq_operador_licencia     UNIQUE (nro_licencia),
    CONSTRAINT fk_operador_nest         FOREIGN KEY (id_nest) REFERENCES estacion_nest (id_nest),
    CONSTRAINT ck_operador_dni          CHECK (dni ~ '^[0-9]{8}$')
);

-- ---------------------------------------------------------------------
-- 7. autorizacion  (relación ternaria Operador–ModeloDrone–Distrito)
-- ---------------------------------------------------------------------
CREATE TABLE autorizacion (
    id_operador        INTEGER  NOT NULL,
    id_modelo          INTEGER  NOT NULL,
    ubigeo             CHAR(6)  NOT NULL,
    fecha_emision      DATE     NOT NULL,
    fecha_vencimiento  DATE     NOT NULL,
    CONSTRAINT pk_autorizacion          PRIMARY KEY (id_operador, id_modelo, ubigeo),
    CONSTRAINT fk_autorizacion_operador FOREIGN KEY (id_operador) REFERENCES operador (id_operador),
    CONSTRAINT fk_autorizacion_modelo   FOREIGN KEY (id_modelo)   REFERENCES modelo_drone (id_modelo),
    CONSTRAINT fk_autorizacion_distrito FOREIGN KEY (ubigeo)      REFERENCES distrito (ubigeo),
    CONSTRAINT ck_autorizacion_fechas   CHECK (fecha_vencimiento > fecha_emision)
);

-- ---------------------------------------------------------------------
-- 8-10. cliente ⊃ {cliente_persona, cliente_empresa}
-- ---------------------------------------------------------------------
CREATE TABLE cliente (
    id_cliente      SERIAL        NOT NULL,
    email           VARCHAR(100)  NOT NULL,
    telefono        VARCHAR(15),
    fecha_registro  TIMESTAMP     NOT NULL DEFAULT now(),
    CONSTRAINT pk_cliente        PRIMARY KEY (id_cliente),
    CONSTRAINT uq_cliente_email  UNIQUE (email)
);

CREATE TABLE cliente_persona (
    id_cliente  INTEGER      NOT NULL,
    dni         CHAR(8)      NOT NULL,
    nombres     VARCHAR(60)  NOT NULL,
    apellidos   VARCHAR(60)  NOT NULL,
    CONSTRAINT pk_cliente_persona          PRIMARY KEY (id_cliente),
    CONSTRAINT uq_cliente_persona_dni      UNIQUE (dni),
    CONSTRAINT fk_cliente_persona_cliente  FOREIGN KEY (id_cliente) REFERENCES cliente (id_cliente) ON DELETE CASCADE,
    CONSTRAINT ck_cliente_persona_dni      CHECK (dni ~ '^[0-9]{8}$')
);

CREATE TABLE cliente_empresa (
    id_cliente    INTEGER       NOT NULL,
    ruc           CHAR(11)      NOT NULL,
    razon_social  VARCHAR(120)  NOT NULL,
    contacto      VARCHAR(80),
    CONSTRAINT pk_cliente_empresa          PRIMARY KEY (id_cliente),
    CONSTRAINT uq_cliente_empresa_ruc      UNIQUE (ruc),
    CONSTRAINT fk_cliente_empresa_cliente  FOREIGN KEY (id_cliente) REFERENCES cliente (id_cliente) ON DELETE CASCADE,
    CONSTRAINT ck_cliente_empresa_ruc      CHECK (ruc ~ '^[0-9]{11}$')
);

-- ---------------------------------------------------------------------
-- 11. ruta_vuelo
-- ---------------------------------------------------------------------
CREATE TABLE ruta_vuelo (
    id_ruta            SERIAL        NOT NULL,
    codigo             VARCHAR(15)   NOT NULL,
    id_nest_origen     INTEGER       NOT NULL,
    ubigeo_destino     CHAR(6)       NOT NULL,
    distancia_km       NUMERIC(6,2)  NOT NULL,
    altitud_crucero_m  NUMERIC(5,1)  NOT NULL,
    duracion_est_min   SMALLINT      NOT NULL,
    activa             BOOLEAN       NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_ruta_vuelo            PRIMARY KEY (id_ruta),
    CONSTRAINT uq_ruta_vuelo_codigo     UNIQUE (codigo),
    CONSTRAINT fk_ruta_vuelo_nest       FOREIGN KEY (id_nest_origen) REFERENCES estacion_nest (id_nest),
    CONSTRAINT fk_ruta_vuelo_distrito   FOREIGN KEY (ubigeo_destino) REFERENCES distrito (ubigeo),
    CONSTRAINT ck_ruta_vuelo_distancia  CHECK (distancia_km > 0),
    CONSTRAINT ck_ruta_vuelo_altitud    CHECK (altitud_crucero_m > 0),
    CONSTRAINT ck_ruta_vuelo_duracion   CHECK (duracion_est_min > 0)
);

-- ---------------------------------------------------------------------
-- 12. punto_ruta  (entidad débil de ruta_vuelo)
-- ---------------------------------------------------------------------
CREATE TABLE punto_ruta (
    id_ruta        INTEGER       NOT NULL,
    nro_secuencia  SMALLINT      NOT NULL,
    latitud        NUMERIC(9,6)  NOT NULL,
    longitud       NUMERIC(9,6)  NOT NULL,
    altitud_m      NUMERIC(5,1)  NOT NULL,
    tipo           VARCHAR(12)   NOT NULL,
    CONSTRAINT pk_punto_ruta           PRIMARY KEY (id_ruta, nro_secuencia),
    CONSTRAINT fk_punto_ruta_ruta      FOREIGN KEY (id_ruta) REFERENCES ruta_vuelo (id_ruta) ON DELETE CASCADE,
    CONSTRAINT ck_punto_ruta_secuencia CHECK (nro_secuencia >= 1),
    CONSTRAINT ck_punto_ruta_latitud   CHECK (latitud  BETWEEN -90  AND 90),
    CONSTRAINT ck_punto_ruta_longitud  CHECK (longitud BETWEEN -180 AND 180),
    CONSTRAINT ck_punto_ruta_altitud   CHECK (altitud_m >= 0),
    CONSTRAINT ck_punto_ruta_tipo      CHECK (tipo IN ('despegue', 'paso', 'entrega', 'aterrizaje'))
);

-- ---------------------------------------------------------------------
-- 13. permiso_vuelo
-- ---------------------------------------------------------------------
CREATE TABLE permiso_vuelo (
    id_permiso         SERIAL       NOT NULL,
    nro_expediente     VARCHAR(20)  NOT NULL,
    ubigeo             CHAR(6)      NOT NULL,
    fecha_emision      DATE         NOT NULL,
    fecha_vencimiento  DATE         NOT NULL,
    estado             VARCHAR(12)  NOT NULL DEFAULT 'vigente',
    CONSTRAINT pk_permiso_vuelo            PRIMARY KEY (id_permiso),
    CONSTRAINT uq_permiso_vuelo_expediente UNIQUE (nro_expediente),
    CONSTRAINT fk_permiso_vuelo_distrito   FOREIGN KEY (ubigeo) REFERENCES distrito (ubigeo),
    CONSTRAINT ck_permiso_vuelo_fechas     CHECK (fecha_vencimiento > fecha_emision),
    CONSTRAINT ck_permiso_vuelo_estado     CHECK (estado IN ('vigente', 'vencido', 'revocado'))
);

-- ---------------------------------------------------------------------
-- 14. vuelo
-- ---------------------------------------------------------------------
CREATE TABLE vuelo (
    id_vuelo           SERIAL        NOT NULL,
    id_drone           INTEGER       NOT NULL,
    id_bateria         INTEGER       NOT NULL,
    id_ruta            INTEGER       NOT NULL,
    id_operador        INTEGER       NOT NULL,
    id_permiso         INTEGER,                      -- NULL si el distrito no es restringido
    fecha_programada   TIMESTAMP     NOT NULL,
    despegue           TIMESTAMP,
    aterrizaje         TIMESTAMP,
    estado             VARCHAR(12)   NOT NULL DEFAULT 'programado',
    tipo_operacion     VARCHAR(10)   NOT NULL,
    distancia_real_km  NUMERIC(6,2),
    CONSTRAINT pk_vuelo            PRIMARY KEY (id_vuelo),
    CONSTRAINT fk_vuelo_drone      FOREIGN KEY (id_drone)    REFERENCES drone (id_drone),
    CONSTRAINT fk_vuelo_bateria    FOREIGN KEY (id_bateria)  REFERENCES bateria (id_bateria),
    CONSTRAINT fk_vuelo_ruta       FOREIGN KEY (id_ruta)     REFERENCES ruta_vuelo (id_ruta),
    CONSTRAINT fk_vuelo_operador   FOREIGN KEY (id_operador) REFERENCES operador (id_operador),
    CONSTRAINT fk_vuelo_permiso    FOREIGN KEY (id_permiso)  REFERENCES permiso_vuelo (id_permiso),
    CONSTRAINT ck_vuelo_estado     CHECK (estado IN ('programado', 'en_curso', 'completado', 'abortado', 'cancelado')),
    CONSTRAINT ck_vuelo_tipo_op    CHECK (tipo_operacion IN ('manual', 'automatico')),
    CONSTRAINT ck_vuelo_distancia  CHECK (distancia_real_km > 0),
    -- R18: aterrizaje > despegue; no puede haber aterrizaje sin despegue
    CONSTRAINT ck_vuelo_aterrizaje_despegue
        CHECK (aterrizaje IS NULL OR (despegue IS NOT NULL AND aterrizaje > despegue)),
    -- Coherencia del estado con los horarios reales
    CONSTRAINT ck_vuelo_estado_tiempos CHECK (
        (estado IN ('programado', 'cancelado') AND despegue IS NULL AND aterrizaje IS NULL)
     OR (estado = 'en_curso'   AND despegue IS NOT NULL AND aterrizaje IS NULL)
     OR (estado = 'completado' AND despegue IS NOT NULL AND aterrizaje IS NOT NULL)
     OR (estado = 'abortado'   AND despegue IS NOT NULL)
    ),
    -- R12 / restricción (vii): una batería no vuela en dos vuelos solapados.
    -- Solo se compara cuando el vuelo ya tiene despegue y aterrizaje.
    CONSTRAINT ex_vuelo_bateria_solape EXCLUDE USING gist (
        id_bateria WITH =,
        tsrange(despegue, aterrizaje) WITH &&
    ) WHERE (despegue IS NOT NULL AND aterrizaje IS NOT NULL)
);

-- ---------------------------------------------------------------------
-- 15. paquete
-- ---------------------------------------------------------------------
CREATE TABLE paquete (
    id_paquete             SERIAL        NOT NULL,
    codigo_tracking        CHAR(12)      NOT NULL,
    id_cliente             INTEGER       NOT NULL,
    id_vuelo               INTEGER,                  -- NULL mientras no tenga vuelo
    ubigeo_destino         CHAR(6)       NOT NULL,
    peso_kg                NUMERIC(5,2)  NOT NULL,
    largo_cm               NUMERIC(5,1)  NOT NULL,
    ancho_cm               NUMERIC(5,1)  NOT NULL,
    alto_cm                NUMERIC(5,1)  NOT NULL,
    prioridad              VARCHAR(10)   NOT NULL DEFAULT 'estandar',
    es_fragil              BOOLEAN       NOT NULL DEFAULT FALSE,
    destinatario_nombre    VARCHAR(100)  NOT NULL,
    destinatario_telefono  VARCHAR(15)   NOT NULL,
    direccion_destino      VARCHAR(150)  NOT NULL,
    lat_destino            NUMERIC(9,6),
    lon_destino            NUMERIC(9,6),
    estado                 VARCHAR(12)   NOT NULL DEFAULT 'registrado',
    fecha_registro         TIMESTAMP     NOT NULL DEFAULT now(),
    fecha_entrega          TIMESTAMP,
    costo_envio            NUMERIC(8,2)  NOT NULL,
    CONSTRAINT pk_paquete              PRIMARY KEY (id_paquete),
    CONSTRAINT uq_paquete_tracking     UNIQUE (codigo_tracking),
    CONSTRAINT fk_paquete_cliente      FOREIGN KEY (id_cliente)     REFERENCES cliente (id_cliente),
    CONSTRAINT fk_paquete_vuelo        FOREIGN KEY (id_vuelo)       REFERENCES vuelo (id_vuelo),
    CONSTRAINT fk_paquete_distrito     FOREIGN KEY (ubigeo_destino) REFERENCES distrito (ubigeo),
    CONSTRAINT ck_paquete_peso         CHECK (peso_kg > 0),
    CONSTRAINT ck_paquete_dimensiones  CHECK (largo_cm > 0 AND ancho_cm > 0 AND alto_cm > 0),
    CONSTRAINT ck_paquete_prioridad    CHECK (prioridad IN ('estandar', 'express')),
    CONSTRAINT ck_paquete_lat          CHECK (lat_destino BETWEEN -90  AND 90),
    CONSTRAINT ck_paquete_lon          CHECK (lon_destino BETWEEN -180 AND 180),
    -- Las coordenadas van juntas: ambas o ninguna (dato faltante)
    CONSTRAINT ck_paquete_coordenadas  CHECK ((lat_destino IS NULL) = (lon_destino IS NULL)),
    CONSTRAINT ck_paquete_estado       CHECK (estado IN ('registrado', 'asignado', 'en_ruta', 'entregado', 'fallido', 'devuelto')),
    CONSTRAINT ck_paquete_fechas       CHECK (fecha_entrega >= fecha_registro),
    CONSTRAINT ck_paquete_costo        CHECK (costo_envio >= 0),
    -- R19: entregado => tiene fecha_entrega; asignado/en_ruta/entregado => tiene vuelo
    CONSTRAINT ck_paquete_entregado_fecha CHECK (estado <> 'entregado' OR fecha_entrega IS NOT NULL),
    CONSTRAINT ck_paquete_estado_vuelo    CHECK (estado NOT IN ('asignado', 'en_ruta', 'entregado') OR id_vuelo IS NOT NULL)
);

-- ---------------------------------------------------------------------
-- 16. telemetria_bateria  (entidad débil de vuelo)
-- ---------------------------------------------------------------------
CREATE TABLE telemetria_bateria (
    id_vuelo       INTEGER       NOT NULL,
    marca_tiempo   TIMESTAMP(3)  NOT NULL,
    voltaje_v      NUMERIC(5,2)  NOT NULL,
    corriente_a    NUMERIC(6,2)  NOT NULL,      -- negativa en regeneración
    temperatura_c  NUMERIC(5,2)  NOT NULL,
    carga_pct      NUMERIC(5,2)  NOT NULL,
    CONSTRAINT pk_telemetria_bateria  PRIMARY KEY (id_vuelo, marca_tiempo),
    CONSTRAINT fk_telemetria_vuelo    FOREIGN KEY (id_vuelo) REFERENCES vuelo (id_vuelo) ON DELETE CASCADE,
    CONSTRAINT ck_telemetria_voltaje  CHECK (voltaje_v > 0),
    CONSTRAINT ck_telemetria_temp     CHECK (temperatura_c BETWEEN -20 AND 90),
    CONSTRAINT ck_telemetria_carga    CHECK (carga_pct BETWEEN 0 AND 100)
);

COMMIT;

-- Resumen: tablas creadas y número de restricciones por tabla
SELECT c.relname AS tabla, count(k.conname) AS restricciones
FROM pg_class c
LEFT JOIN pg_constraint k ON k.conrelid = c.oid
WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace
GROUP BY c.relname
ORDER BY c.relname;
