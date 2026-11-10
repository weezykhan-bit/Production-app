# Tests

| What | Run |
|---|---|
| Database rules (every migration, 430+ checks) | `PGHOST=/var/run/postgresql PGUSER=postgres bash tests/db.sh` |
| Live app end to end against the real schema in the browser | `PGLITE=<pglite dist/index.js> XLSX=<xlsx.full.min.js> node tests/live-e2e.mjs` |
| Agreement templates and clause questions in the demo (desktop + phone) | `MAMMOTH=<mammoth.browser.min.js> node tests/demo-agreements.cjs` |

`tests/db.sh` also runs on GitHub for every change under `supabase/`.
After changing `central/` or `src/`, rebuild the live bundle with `python3 tools/build-live.py`.
