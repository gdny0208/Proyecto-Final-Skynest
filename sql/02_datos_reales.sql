-- =====================================================================
-- SkyNest · 02_datos_reales.sql
-- Carga de las tablas maestras con datos reales (sección 4.2 del informe).
--
--   distrito       50 filas: 43 distritos de la provincia de Lima y
--                  7 de la Provincia Constitucional del Callao, con su
--                  código UBIGEO del INEI.
--   modelo_drone    8 filas: drones de reparto comerciales, con valores
--                  de sus fichas técnicas públicas (ver notas abajo).
--   estacion_nest  30 filas: nests en distritos no restringidos.
--                  Direcciones en avenidas reales y coordenadas aproximadas
--                  (ubicaciones plausibles, la empresa es ficticia).
--
-- Supuestos del proyecto (no son datos oficiales):
--   * zona_restringida = TRUE en Callao, Bellavista y Carmen de la Legua
--     Reynoso (entorno del Aeropuerto Jorge Chávez) y en Lima Cercado
--     (Palacio de Gobierno). Altitud máxima 60 m en esos distritos y
--     120 m en el resto.
--
-- Requiere: 01_schema.sql
-- Uso:  psql -d skynest_dev -f sql/02_datos_reales.sql   (re-ejecutable)
-- =====================================================================

\set ON_ERROR_STOP on

BEGIN;

-- Re-ejecutable: vacía las maestras (y lo que dependa de ellas) y reinicia los SERIAL
TRUNCATE distrito, modelo_drone, estacion_nest RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------
-- distrito  (fuente: INEI, Códigos de Ubicación Geográfica)
-- ---------------------------------------------------------------------
INSERT INTO distrito (ubigeo, nombre, provincia, zona_restringida, altitud_max_m) VALUES
  ('150101', 'Lima',                       'Lima',   TRUE,   60),
  ('150102', 'Ancón',                      'Lima',   FALSE, 120),
  ('150103', 'Ate',                        'Lima',   FALSE, 120),
  ('150104', 'Barranco',                   'Lima',   FALSE, 120),
  ('150105', 'Breña',                      'Lima',   FALSE, 120),
  ('150106', 'Carabayllo',                 'Lima',   FALSE, 120),
  ('150107', 'Chaclacayo',                 'Lima',   FALSE, 120),
  ('150108', 'Chorrillos',                 'Lima',   FALSE, 120),
  ('150109', 'Cieneguilla',                'Lima',   FALSE, 120),
  ('150110', 'Comas',                      'Lima',   FALSE, 120),
  ('150111', 'El Agustino',                'Lima',   FALSE, 120),
  ('150112', 'Independencia',              'Lima',   FALSE, 120),
  ('150113', 'Jesús María',                'Lima',   FALSE, 120),
  ('150114', 'La Molina',                  'Lima',   FALSE, 120),
  ('150115', 'La Victoria',                'Lima',   FALSE, 120),
  ('150116', 'Lince',                      'Lima',   FALSE, 120),
  ('150117', 'Los Olivos',                 'Lima',   FALSE, 120),
  ('150118', 'Lurigancho',                 'Lima',   FALSE, 120),
  ('150119', 'Lurín',                      'Lima',   FALSE, 120),
  ('150120', 'Magdalena del Mar',          'Lima',   FALSE, 120),
  ('150121', 'Pueblo Libre',               'Lima',   FALSE, 120),
  ('150122', 'Miraflores',                 'Lima',   FALSE, 120),
  ('150123', 'Pachacámac',                 'Lima',   FALSE, 120),
  ('150124', 'Pucusana',                   'Lima',   FALSE, 120),
  ('150125', 'Puente Piedra',              'Lima',   FALSE, 120),
  ('150126', 'Punta Hermosa',              'Lima',   FALSE, 120),
  ('150127', 'Punta Negra',                'Lima',   FALSE, 120),
  ('150128', 'Rímac',                      'Lima',   FALSE, 120),
  ('150129', 'San Bartolo',                'Lima',   FALSE, 120),
  ('150130', 'San Borja',                  'Lima',   FALSE, 120),
  ('150131', 'San Isidro',                 'Lima',   FALSE, 120),
  ('150132', 'San Juan de Lurigancho',     'Lima',   FALSE, 120),
  ('150133', 'San Juan de Miraflores',     'Lima',   FALSE, 120),
  ('150134', 'San Luis',                   'Lima',   FALSE, 120),
  ('150135', 'San Martín de Porres',       'Lima',   FALSE, 120),
  ('150136', 'San Miguel',                 'Lima',   FALSE, 120),
  ('150137', 'Santa Anita',                'Lima',   FALSE, 120),
  ('150138', 'Santa María del Mar',        'Lima',   FALSE, 120),
  ('150139', 'Santa Rosa',                 'Lima',   FALSE, 120),
  ('150140', 'Santiago de Surco',          'Lima',   FALSE, 120),
  ('150141', 'Surquillo',                  'Lima',   FALSE, 120),
  ('150142', 'Villa El Salvador',          'Lima',   FALSE, 120),
  ('150143', 'Villa María del Triunfo',    'Lima',   FALSE, 120),
  ('070101', 'Callao',                     'Callao', TRUE,   60),
  ('070102', 'Bellavista',                 'Callao', TRUE,   60),
  ('070103', 'Carmen de la Legua Reynoso', 'Callao', TRUE,   60),
  ('070104', 'La Perla',                   'Callao', FALSE, 120),
  ('070105', 'La Punta',                   'Callao', FALSE, 120),
  ('070106', 'Ventanilla',                 'Callao', FALSE, 120),
  ('070107', 'Mi Perú',                    'Callao', FALSE, 120);

-- ---------------------------------------------------------------------
-- modelo_drone  (fichas técnicas públicas de los fabricantes)
--   carga_util_max_kg : carga útil máxima publicada
--   velocidad_crucero : velocidad de crucero publicada
--   alcance_km        : distancia máxima publicada
--   autonomia_min     : tiempo de vuelo publicado; si el fabricante no lo
--                       publica, se estima como alcance / velocidad (*)
-- ---------------------------------------------------------------------
INSERT INTO modelo_drone (fabricante, nombre, carga_util_max_kg, autonomia_min, velocidad_crucero_kmh, alcance_km) VALUES
  -- DJI FlyCart 30: 30 kg (2 baterías), 18 min con 30 kg, crucero 15 m/s, 28 km sin carga
  ('DJI',        'FlyCart 30',       30.00, 18,  54.0,  28.0),
  -- DJI FlyCart 100: 85 kg (2 baterías), 14 min, crucero 15 m/s, 12 km
  ('DJI',        'FlyCart 100',      85.00, 14,  54.0,  12.0),
  -- Wingcopter 198: 4,7 kg, 90 km/h, 94 km  (*) 94/90 h
  ('Wingcopter', '198',               4.70, 62,  90.0,  94.0),
  -- Matternet M2: 2 kg, crucero 10 m/s, 20 km con 1 kg  (*)
  ('Matternet',  'M2',                2.00, 33,  36.0,  20.0),
  -- Matternet M3: 5 kg, 72 km/h, 32 km  (*)
  ('Matternet',  'M3',                5.00, 26,  72.0,  32.0),
  -- Zipline Platform 2 (P2 Zip): 8 lb, 70 mph, 24 mi de dock a dock  (*)
  ('Zipline',    'P2 Zip',            3.60, 21, 110.0,  38.6),
  -- Wing Hummingbird: ~2,5 lb, 65 mph, 12 mi ida y vuelta  (*)
  ('Wing',       'Hummingbird',       1.10, 11, 104.0,  19.3),
  -- Manna: 4 kg, hasta 80 km/h, alcance máx. 16 km; no publica nombre comercial  (*)
  ('Manna',      'Octocóptero 4 kg',  4.00, 12,  80.0,  16.0);

-- ---------------------------------------------------------------------
-- estacion_nest  (30 nests, ninguno en distrito restringido)
--   Capacidad total = 338 drones (el generador asigna 300).
-- ---------------------------------------------------------------------
INSERT INTO estacion_nest (codigo, nombre, direccion, latitud, longitud, capacidad_drones, puertos_carga, estado, ubigeo) VALUES
  ('NST-MIR-01', 'Nest Miraflores',              'Av. José Larco 1150',                    -12.126500, -77.029700, 14, 8, 'operativa',     '150122'),
  ('NST-SIS-01', 'Nest San Isidro',              'Av. Javier Prado Oeste 757',             -12.095000, -77.035000, 14, 8, 'operativa',     '150131'),
  ('NST-SUR-01', 'Nest Santiago de Surco',       'Av. Caminos del Inca 2580',              -12.139000, -76.993000, 14, 8, 'operativa',     '150140'),
  ('NST-SBO-01', 'Nest San Borja',               'Av. San Borja Norte 1210',               -12.100000, -76.999000, 12, 6, 'operativa',     '150130'),
  ('NST-LMO-01', 'Nest La Molina',               'Av. La Molina 3540',                     -12.085000, -76.945000, 12, 6, 'operativa',     '150114'),
  ('NST-BAR-01', 'Nest Barranco',                'Av. Miguel Grau 420',                    -12.148000, -77.020000, 10, 6, 'operativa',     '150104'),
  ('NST-JMA-01', 'Nest Jesús María',             'Av. Salaverry 1880',                     -12.078000, -77.048000, 12, 6, 'operativa',     '150113'),
  ('NST-LIN-01', 'Nest Lince',                   'Av. Arequipa 2450',                      -12.086000, -77.034000, 10, 6, 'operativa',     '150116'),
  ('NST-MAG-01', 'Nest Magdalena',               'Av. Brasil 3640',                        -12.090000, -77.067000, 10, 6, 'operativa',     '150120'),
  ('NST-PLI-01', 'Nest Pueblo Libre',            'Av. Sucre 1020',                         -12.075000, -77.064000, 10, 6, 'operativa',     '150121'),
  ('NST-SMI-01', 'Nest San Miguel',              'Av. La Marina 2355',                     -12.078000, -77.090000, 12, 6, 'operativa',     '150136'),
  ('NST-SQU-01', 'Nest Surquillo',               'Av. República de Panamá 4570',           -12.113000, -77.018000, 10, 6, 'operativa',     '150141'),
  ('NST-CHO-01', 'Nest Chorrillos',              'Av. Defensores del Morro 1340',          -12.173000, -77.015000, 12, 6, 'operativa',     '150108'),
  ('NST-SJM-01', 'Nest San Juan de Miraflores',  'Av. Los Héroes 650',                     -12.157000, -76.972000, 12, 6, 'operativa',     '150133'),
  ('NST-VMT-01', 'Nest Villa María del Triunfo', 'Av. Pachacútec 3870',                    -12.165000, -76.940000, 10, 6, 'operativa',     '150143'),
  ('NST-VES-01', 'Nest Villa El Salvador',       'Av. El Sol 1480',                        -12.210000, -76.935000, 12, 6, 'operativa',     '150142'),
  ('NST-ATE-01', 'Nest Ate',                     'Carretera Central km 3,5',               -12.026000, -76.918000, 12, 6, 'operativa',     '150103'),
  ('NST-SAN-01', 'Nest Santa Anita',             'Av. Los Ruiseñores 380',                 -12.045000, -76.970000, 10, 6, 'operativa',     '150137'),
  ('NST-SJL-01', 'Nest San Juan de Lurigancho',  'Av. Próceres de la Independencia 2150',  -12.000000, -77.000000, 14, 8, 'operativa',     '150132'),
  ('NST-OLI-01', 'Nest Los Olivos',              'Av. Antúnez de Mayolo 960',              -11.990000, -77.070000, 12, 6, 'operativa',     '150117'),
  ('NST-IND-01', 'Nest Independencia',           'Av. Túpac Amaru 1530',                   -12.000000, -77.055000, 10, 6, 'operativa',     '150112'),
  ('NST-COM-01', 'Nest Comas',                   'Av. Túpac Amaru 6200',                   -11.940000, -77.050000, 12, 6, 'operativa',     '150110'),
  ('NST-SMP-01', 'Nest San Martín de Porres',    'Av. Perú 2780',                          -12.025000, -77.075000, 12, 6, 'operativa',     '150135'),
  ('NST-PPI-01', 'Nest Puente Piedra',           'Panamericana Norte km 31',               -11.865000, -77.075000, 10, 4, 'operativa',     '150125'),
  ('NST-RIM-01', 'Nest Rímac',                   'Av. Francisco Pizarro 640',              -12.030000, -77.030000, 10, 4, 'operativa',     '150128'),
  ('NST-LVI-01', 'Nest La Victoria',             'Av. Canadá 1160',                        -12.080000, -77.015000, 10, 6, 'operativa',     '150115'),
  ('NST-BRE-01', 'Nest Breña',                   'Av. Arica 850',                          -12.058000, -77.052000, 10, 4, 'operativa',     '150105'),
  ('NST-SLU-01', 'Nest San Luis',                'Av. Nicolás Arriola 2210',               -12.075000, -76.998000, 10, 4, 'operativa',     '150134'),
  ('NST-LUR-01', 'Nest Lurín',                   'Antigua Panamericana Sur km 36',         -12.275000, -76.870000, 10, 4, 'mantenimiento', '150119'),
  ('NST-LPE-01', 'Nest La Perla',                'Av. La Paz 1350',                        -12.070000, -77.105000, 10, 4, 'operativa',     '070104');

COMMIT;

-- Verificación rápida
SELECT 'distrito' AS tabla, count(*) AS filas,
       count(*) FILTER (WHERE zona_restringida) AS restringidos
FROM distrito
UNION ALL SELECT 'modelo_drone', count(*), NULL FROM modelo_drone
UNION ALL SELECT 'estacion_nest', count(*), sum(capacidad_drones) FROM estacion_nest;
