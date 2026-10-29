# CrewDesk

Production management for film, series, web, ad and music-video shoots in India: crew onboarding with one-time KYC, contracts with e-signature, invoices with GST/TDS, a head-of-department → accounts approval chain, payment runs with a bank file, Tally export, call sheets with read receipts, day reports, QR ID cards with check-in/out, and a live budget-vs-spend report.

The app is mobile-first and installable to a phone's home screen. Without configuration it runs as a **self-contained demo**: the real database schema runs in the browser, seeded with a sample series, so anyone can try every role.

## How it is built

| Part | What it is |
|---|---|
| `index.html`, `app.js` | The whole interface: plain JavaScript, no build step |
| `backend.js` | One data interface with two engines: **live** (Supabase) or **demo** (PGlite, Postgres compiled to WebAssembly, in the browser) |
| `supabase/migrations/…_crewdesk.sql` | Tables, business rules, row-level security. The same file runs in Supabase and in the demo |
| `demo/seed.sql` | Sample production, created by calling the real functions as each sample person. All names, PAN, GSTIN and bank numbers are fictional |
| `config.js` | Supabase URL and anon key (empty means demo) |
| `vercel.json` / `netlify.toml` | Security headers: CSP, no framing, camera only for this site |

### Rules the database enforces (not just the screens)

- **Roles per production:** producer, production manager, accounts, head of department, crew, vendor. Only the producer can grant producer, manager or accounts access, and a production always keeps at least one producer.
- **Privacy:** people see only the productions they're on. PAN, GSTIN, address and bank details are visible to the person and to the producer, manager and accounts of their productions, never to other crew. Crew see only their own contracts and invoices; a head of department sees their department's invoices.
- **Contracts:**
  - Each contract is pre-filled from the person's deal and profile.
  - It can only be edited before it is signed, and signing requires a complete profile plus a typed name and a drawn signature.
  - Signing stores the exact signed text and a SHA-256 fingerprint. Only the producer countersigns.
  - Every step goes into an audit trail.
- **Invoices:**
  - Amount and GST are calculated by the database, and GST is only possible with a valid GSTIN. Invoice numbers can't repeat within a production.
  - A crew invoice goes HOD → accounts. Accounts can't skip the HOD; the producer and manager can.
  - Nobody can approve their own invoice, except the producer.
  - TDS is set at approval and applied to the amount before GST.
- **Payments:** an invoice can be in only one payment run. Marking a run paid records the bank reference on every invoice in it. Invoices in a run are locked.
- **Validation:** PAN, IFSC and GSTIN (including its check digit) are validated in the database. GSTIN must contain the PAN.
- **ID cards:** each person has a random 8-character code per production. Only the producer or manager can check people in or out.

## Tests

- **Database:** 67 checks covering every rule above, run as each role, on Postgres 16 and on the in-browser engine.

  ```sh
  createdb crewdesk_test
  psql -d crewdesk_test -f supabase/tests/supabase_stub.sql -f supabase/migrations/20261029100000_crewdesk.sql -f supabase/tests/crewdesk_test.sql
  ```
- **End to end:** `tests/e2e.mjs` drives the demo in Chromium at phone size through a whole flow. It needs `npm i playwright @electric-sql/pglite@0.2.17 qrcode-generator@1.4.4`, then `node tests/e2e.mjs . /tmp`. The flow:
  - crew sign a contract and raise an invoice;
  - the HOD approves;
  - accounts set TDS, create a payment run, download the bank file and mark it paid;
  - the producer countersigns, reads the cost report and exports to Tally (the XML is checked to parse and every voucher to balance);
  - the manager publishes a call sheet and checks crew in by ID code;
  - a new person signs up and joins by invite code;
  - every screen is checked for sideways scrolling at 390 px, with no errors, under the production security headers.

## Going live

1. **Create a Supabase project.**
   - At supabase.com, create a new project. Choose region **Mumbai (ap-south-1)** so data stays in India.
   - In **SQL Editor**, run `supabase/migrations/20261029100000_crewdesk.sql`. Do not run `supabase/tests/*` or `demo/seed.sql` on the live project.
   - Under **Authentication → Providers → Email**, keep Email on.
   - Under **Authentication → Email Templates → Magic Link**, add `{{ .Token }}` so people get a 6-digit code.
   - Under **Authentication → URL Configuration**, set the Site URL to your domain.
   - Before real use, set your own SMTP sender under **Authentication → SMTP**, because the built-in mailer is rate-limited.
2. **Connect the app.** In **Project Settings → API**, copy the Project URL and the `anon` public key into `config.js`. The anon key is meant to be public. Never put the `service_role` key in this repo.
3. **Host it.** Import the repository in Vercel or Netlify. There is no build command, and the output directory is the root. Add your domain.
4. **Make yourself a producer.** Sign up in the app and create a production. You become its producer automatically.

## Known limits (next steps)

- **E-signature:** typed name, drawn signature, timestamp and document fingerprint. That is valid for most crew agreements under the IT Act, but it is not Aadhaar eSign. For high-value or stamp-duty agreements, add a licensed eSign provider (Leegality, Digio or similar).
- **KYC:** PAN, GSTIN and IFSC are checked for format and check digit, but not against government or bank records. Live verification needs a paid API.
- **Payments:** the app produces a bank bulk-payment CSV and records the bank reference; it does not move money. Column order differs between banks, so adjust it to yours if needed. Direct payouts need a payment provider such as RazorpayX or Cashfree.
- **Tally:** the export is an XML import file (ledger masters, purchase vouchers, payment vouchers). The expense, GST, TDS and bank ledgers named in production settings must already exist in Tally. Test the first import on a copy of your company data.
- **Not built yet:** notifications (email or WhatsApp on a new contract, approval or call sheet), file attachments (invoice PDFs, receipts), a crew marketplace, and a native app-store app.

---

## CrewDesk Central (the live app, from October 2026)

The site root is now **CrewDesk Central**: company set up once, production codes, crew onboarding with photo and KYC uploads, e-signed agreements, the shoot schedule with gate check-in, invoices, payment runs, TDS/GST registers, Tally files and Excel reports. The demo with sample data stays at `/central/`. The first version of the app is kept in `legacy/` for reference.

| Part | What it is |
|---|---|
| `central/` | The screens, with sample data (the public demo) |
| `src/live.js` | The live data layer: Supabase sign-in, loading what each person may see, saving through checked database functions, private uploads |
| `tools/build-live.py` | Builds `index.html` and `app.js` at the root from the two above. Edit those, then run `python3 tools/build-live.py` |
| `supabase/migrations/20261030*` | Tables, rules, private document storage and hardening |

**Security.** Every table has row-level security and no direct-write rules; every change goes through a database function that checks the caller's role. PAN, Aadhaar, address and bank details are visible only to the person, the CFO/Commercial Head and Finance on their production. Photos and documents sit in a private storage bucket, readable through short-lived signed links under the same rules. Wrong production codes are counted and lock joining after ten an hour. Every action is written to the activity log; deal changes can be undone, and the undo is logged too. The first owner is the Commercial Head's account, so nobody else can claim the company.

**Notifications and live updates.** Database triggers write a notification for the right people when an agreement is sent, signed or approved; an invoice is submitted, checked, approved, paid or rejected; someone joins; a deal changes; or someone is checked in. The bell in the top bar shows them, and screens refresh by themselves through Supabase Realtime (waiting while you type or sign). Desktop alerts can be turned on from the bell.

**Tests.**
- Database: `supabase/tests/central_test.sql` and `central_notify_test.sql`, 118 checks run as each role on Postgres 16 (see the file header for the run order).
- End to end: `tests/live-e2e.mjs` runs the real screens in Chromium against the real schema in PGlite: company setup, production, invites, sign-up and joining by code, profile and document uploads, agreement send/sign/approve, gate check-in, invoice from check-ins, approvals, payment run, Tally batch, Excel, then a second device receiving the owner's change live.
