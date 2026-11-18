# Guía maestra para grabar el video del Hito 2

Requisito del enunciado (sección 7, Anexos): *"Debe anexar un vídeo de la experimentación con 1 millón de
registros con y sin índices"*. Este guion lo cumple y además muestra el MVP web (+2 puntos).

**Videos de referencia** (en esta carpeta; sin audio, con subtítulos que dicen qué hacer y qué decir):
- `ejemplo_pgadmin_1m.mp4`: Parte A (pgAdmin), unos 3,5 min.
- `ejemplo_experimento_1m.mp4`: Parte B (web, Laboratorio), unos 4,5 min.

Duración total sugerida: **8 a 10 minutos**.

---

## 0. Antes de grabar (5 min)

1. **Cierra lo que no uses** (Chrome con muchas pestañas, Docker, Zoom…). Con 8 GB de RAM, la grabación y
   otras apps hacen que las consultas tarden más y los tiempos salgan "raros".
2. **No dejes índices del experimento creados.** En una terminal, desde la carpeta del proyecto:
   ```bash
   psql -d skynest_1m -Atc "select indexname from pg_indexes where indexname like 'ix_%'"
   ```
   Debe no imprimir nada. Si aparece alguno, bórralo con `DROP INDEX nombre;`.
3. **Levanta la web** (para la Parte B), en una terminal aparte:
   ```bash
   .venv/bin/uvicorn web.app:app --port 8000
   ```
4. **Abre pgAdmin 4** y conéctate al servidor. Si pide contraseña, es la de tu usuario de PostgreSQL
   (en esta Mac está vacía: deja el campo en blanco y pulsa OK).
5. Ten a mano el archivo `video_ejemplo/demo_pgadmin.sql`.
6. **Ensayo opcional:** corre una vez el bloque 4 (ver abajo) antes de grabar, para que los datos queden en
   memoria y la primera ejecución no sea tan lenta.
7. Inicia la grabación: `Cmd + Shift + 5` → **Grabar toda la pantalla** → Opciones → Micrófono: el de la Mac
   → **Grabar**. Para detener: el botón ⏹ de la barra de menú.

---

## Parte A · pgAdmin: la base real y C3 sin/con índice (≈4 min)

| # | Qué haces en pgAdmin | Qué dices (idea) |
|---|---|---|
| A1 | Presentación con pgAdmin en pantalla. | "Somos el Grupo 3, proyecto SkyNest. Vamos a mostrar el experimento con un millón de registros, sin índices y con índices." |
| A2 | Panel izquierdo (**Object Explorer**): despliega **Servers → PostgreSQL local → Databases**. Señala `skynest_1k`, `skynest_10k`, `skynest_100k` y `skynest_1m`. | "Estas son las cuatro bases del experimento, una por escala: mil, diez mil, cien mil y un millón de vuelos. Cada una tiene su dump." |
| A3 | Despliega **skynest_1m → Schemas**. Señala los dos esquemas: abre **skynest → Tables** (16 tablas) y luego **reportes → Views** (9 vistas). | "La base tiene dos esquemas: skynest, con las 16 tablas del modelo relacional, y reportes, con las vistas. El analista solo tiene acceso a reportes." |
| A4 | Haz clic en **skynest_1m** y luego menú **Tools → Query Tool** (o `Alt+Shift+Q`). En el Query Tool: ícono de carpeta (**Open File**) → `demo_pgadmin.sql`. | "Abrimos el editor SQL conectado a skynest_1m. Vamos a ejecutar el script bloque por bloque." |

Para cada bloque: **selecciona el bloque con el mouse** (desde el comentario `-- N.` hasta su `;`) y pulsa
**F5**. Si no seleccionas nada, F5 ejecuta todo el archivo.

| Bloque | Resultado que debe salir | Qué señalar / decir |
|---|---|---|
| **1** · Conteos | `skynest_1m · 1000000 · 1502865 · 4851512 · ~1139 MB` | "Un millón de vuelos, un millón y medio de paquetes y casi cinco millones de lecturas de telemetría. La base pesa más de 1 GB." |
| **2** · Tablas y filas | 16 filas del esquema `skynest`, `telemetria_bateria` arriba con ~4,85 M | "Estas son las filas por tabla; la telemetría es la más grande." |
| **3** · Índices actuales | Solo `pk_telemetria_bateria` | "Partimos sin los índices del experimento: solo la llave primaria." |
| **4** · C3 **sin** índice | En **Data Output**, el plan en texto. Busca `Parallel Seq Scan on telemetria_bateria` y `Rows Removed by Filter: ~1 600 000`. Baja hasta la última fila: `Execution Time: …` | "La consulta C3 busca baterías que pasaron 60 °C en octubre. Sin índice, PostgreSQL recorre toda la tabla de telemetría y descarta casi todas las filas. Tarda X milisegundos." **Pulsa F5 otra vez** y di: "En la segunda ejecución los datos ya están en memoria y baja a Y ms." |
| **5** · Crear índice | `tamano_indice = 424 kB` | "Creamos el índice parcial del Plan B: solo indexa las lecturas sobre 60 °C. Ocupa apenas 424 kB." |
| **6** · C3 **con** índice | El plan ahora tiene `Bitmap Index Scan on ix_c3b_telemetria_alertas` y un `Execution Time` mucho menor | "Es la misma consulta. Ahora el plan entra por el índice y solo visita unas 800 lecturas. Pasa de X a Z ms, unas N veces más rápido." Pulsa F5 otra vez si quieres el tiempo con caché caliente. |
| *(bonus)* | Borra la primera línea `EXPLAIN (ANALYZE, BUFFERS)` del bloque 6, selecciona la consulta y pulsa **Shift+F7** (Explain Analyze) → pestaña **Explain → Graphical**. Luego vuelve a escribir esa primera línea. | "pgAdmin también muestra el plan como diagrama." |
| **7** · Mismo resultado | `baterias_con_alerta = 466` | "El resultado es el mismo con o sin índice: 466 baterías. Solo cambia el tiempo." |
| **8** · Limpiar | `DROP INDEX` / *Query returned successfully* | "Borramos el índice para dejar la base como estaba." |

> **Sobre los tiempos:** no tienen que coincidir con el informe. Dependen de la caché y de qué más esté
> abierto en la Mac. En nuestras pruebas, C3 sin índice tardó entre 120 ms (caché caliente) y 2 s (Mac
> cargada), y con índice entre 3 y 60 ms. Lo importante es que se vea el cambio de plan y la diferencia de
> tiempo. Si quieres, dilo en el video: "el informe usa la media de 5 corridas".

---

## Parte B · Web: las 5 consultas en las 3 condiciones (≈4 min)

Abre `http://localhost:8000/laboratorio` y elige **1 000 000 vuelos** en el selector de arriba a la derecha.

| # | Qué haces | Qué dices (idea) |
|---|---|---|
| B1 | Muestra el selector con **1 000 000 vuelos**. | "Lo que hicimos en pgAdmin para C3, la web lo hace para las cinco consultas y las tres condiciones." |
| B2 | Para **C1, C2, C3, C4 y C5**: clic en la consulta → **Ver el SQL de la consulta** → clic en **Plan A** y **Plan B** para mostrar sus índices → **Comparar las tres condiciones** (espera ~15 s). | Una frase sobre qué responde la consulta y luego leer las barras: "sin índices tarda X; el plan A, N veces más rápido; el plan B, M veces." |
| B3 | Al terminar, resume. | "Plan B gana en C1, C3 y C5; Plan A en C2 y C4. El BRIN de C4 no sirve porque los vuelos no están ordenados por fecha. Los índices encarecen las escrituras, por eso conviene un conjunto pequeño." |

> "Comparar" crea y borra índices en skynest_1m. No corras `bench/experimento.py` mientras grabas.

---

## Parte C · MVP web (opcional, ≈1 min; refuerza los +2 puntos)

| # | Qué haces | Qué dices |
|---|---|---|
| C1 | **Panel** (`/`): indicadores del mes con la base de 1 M. | "El panel calcula los indicadores directamente desde la base." |
| C2 | **Rastrear**: clic en un código de ejemplo. | "La vista del cliente usa la función fn_rastrear_paquete." |
| C3 | **Despacho** con la base **1 000 vuelos**: Registrar paquete → Programar vuelo → **Paquete con sobrepeso (R15)** (sale el mensaje rojo). | "Si una operación rompe una regla, el trigger la rechaza y la web muestra su mensaje." |

> Despacho **escribe** en la base que elijas. Úsalo con `skynest_1k` o `skynest_dev`, no con las bases del
> experimento que ya están medidas, o restáurala después desde su dump.

---

## Cierre (≈20 s)

"Con un millón de registros, el índice correcto para cada consulta reduce el tiempo decenas de veces, y el
tipo de índice importa tanto como la columna. Gracias."

Detén la grabación, súbela a YouTube (**no listado**) o a Drive (cualquiera con el enlace) y pega el enlace
en `informe/hito2_secciones.tex`, en la línea que dice `\url{PEGAR-ENLACE-DEL-VIDEO}`.
