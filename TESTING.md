# Panduan Setup & Pengetesan — UMKM VFlow

Dokumen ini menjelaskan langkah konkret dari nol: siapkan database, provision
rule pack + 6 workflow ke VFlow Server kelompok 3, sampai mengetes tiap
endpoint dengan `curl`.

---

## 0. Yang Perlu Disiapkan

| Kebutuhan | Sumber |
|---|---|
| Endpoint VFlow Server kelompok 3 | `workflow-db.kelompok3.vflow.parulian.my.id` (lihat `vflow-test-main/README.md`) |
| PostgreSQL (lokal/laptop, di-tunnel ke server) | Cloudflare Tunnel TCP — lihat §1 |
| `node` (untuk `vflow-admin.js`) | terinstall di laptop |
| `psql`, `curl`, `jq` | terinstall di laptop |

Karena server VFlow berjalan di AWS sedangkan PostgreSQL biasanya ada di
laptop praktikan, **PostgreSQL harus bisa diakses oleh server AWS** —
itulah alasan dokumen spesifikasi menyebut Cloudflare Tunnel TCP (Bab 3 & 10).

---

## 1. Siapkan PostgreSQL + Cloudflare Tunnel

### 1.1 Jalankan PostgreSQL lokal & buat schema

```bash
# contoh kalau pakai docker
docker run -d --name umkm-pg -p 5432:5432 \
  -e POSTGRES_PASSWORD=umkm123 -e POSTGRES_DB=umkm_db postgres:16

psql "postgresql://postgres:umkm123@127.0.0.1:5432/umkm_db" -f db/schema.sql
```

Cek isinya:

```bash
psql "postgresql://postgres:umkm123@127.0.0.1:5432/umkm_db" -c "select id, nama, stok from produk;"
```

### 1.2 Buka Cloudflare Tunnel TCP supaya server VFlow di AWS bisa connect

Ikuti `CLOUDFLARE_UPSTREAM_SETUP.md` di repo (`vflow-test-main/`). Singkatnya:

```bash
cloudflared tunnel login
cloudflared tunnel create vflow-kelompok3
cloudflared tunnel route dns vflow-kelompok3 workflow-db.kelompok3.vflow.<domain>
```

`~/.cloudflared/vflow-kelompok3.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /home/<user>/.cloudflared/<TUNNEL_ID>.json
ingress:
  - hostname: workflow-db.kelompok3.vflow.<domain>
    service: tcp://127.0.0.1:5432
  - service: http_status:404
```

```bash
cloudflared tunnel --config ~/.cloudflared/vflow-kelompok3.yml run vflow-kelompok3
```

DSN yang akan dipakai server VFlow (lihat §2):

```
postgresql://postgres:umkm123@workflow-db.kelompok3.vflow.<domain>:5432/umkm_db
```

> Jika seluruh tim sudah punya PostgreSQL bersama (di server/cloud, bukan
> laptop pribadi), langkah Cloudflare Tunnel ini bisa dilewati — cukup
> pastikan DSN-nya bisa dijangkau dari `3.84.212.7`.

---

## 2. Set Environment & Cek Koneksi ke VFlow Server

```bash
cd vflow-test-main      # repo client (vflow-admin.sh dkk)

export VFLOW_BASE_URL="workflow-db.kelompok3.vflow.parulian.my.id"   # kelompok_3
export VFLOW_TENANT="_default"

# DSN postgres yang dipakai SEMUA connector `postgres` di workflow kita
# (lihat 03-connectors.md: connector bare-KIND postgres pakai env VFLOW_POSTGRES_URL
#  -- env ini harus di-set di SISI SERVER VFlow, bukan di laptop, kecuali
#  tim punya akses set env server / pakai pack-scoped connection)
```

Cek server hidup:

```bash
curl -sS "$VFLOW_BASE_URL/health"
curl -sS "$VFLOW_BASE_URL/_vflow/api/overview"
```

Hasil yang diharapkan: `{"status":"healthy", ...}`.

> **Penting soal `VFLOW_POSTGRES_URL`**: connector `postgres` bare-kind
> membaca DSN dari environment variable **di proses `vflow-server`**, bukan
> dari laptop kita. Karena kita tidak SSH ke server, koordinasikan dengan
> pemilik server (atau gunakan pack-scoped connection `pack://umkm/db` yang
> didefinisikan lewat `pack.yaml` jika tersedia endpoint provisioning pack).
> Tanyakan ke pengelola server kelompok 3 apakah `VFLOW_POSTGRES_URL` sudah
> diarahkan ke DSN tunnel di atas sebelum lanjut ke langkah 4.

---

## 3. Provision Rule Pack VDICL

```bash
jq -n \
  --rawfile r rules/aturan_harga_umkm_v1.vdicl \
  --rawfile s schemas/harga_fact_v1.yaml \
  '{rule_set_id:"aturan_harga_umkm_v1", rules_yaml:$r, schema_yaml:$s}' \
  | curl -sS -X POST \
      -H 'Content-Type: application/json' \
      -d @- \
      "$VFLOW_BASE_URL/api/admin/vrule/compile"
```

Output sukses (mirip contoh di README repo):

```json
{
  "rule_set_id": "aturan_harga_umkm_v1",
  "pack_size": 2900,
  "loaded_at": 1750000000
}
```

Cek terdaftar:

```bash
curl -sS "$VFLOW_BASE_URL/api/admin/vrules"
# atau
./scripts/vflow-admin.sh rules list
```

---

## 4. Provision 6 Workflow

Gunakan `vflow-admin.sh` (lebih simpel) atau curl manual. Path di bawah
relatif ke folder `umkm-vflow/` hasil sebelumnya.

```bash
for f in umkm-vflow/workflows/*.yaml; do
  echo "== provisioning $f =="
  ./scripts/vflow-admin.sh workflows provision "$f"
done
```

Atau satu-satu via curl (kalau mau lihat response detail tiap workflow):

```bash
curl -sS -X POST \
  -H "Content-Type: application/yaml" \
  -H "X-Tenant-Id: _default" \
  --data-binary @umkm-vflow/workflows/01-buka-keranjang.yaml \
  "$VFLOW_BASE_URL/api/admin/workflow/upload"
```

Ulangi untuk `02-...` sampai `06-...`. Tiap sukses akan mengembalikan:

```json
{ "id": "wf_xxxxxxxx", "tenant_id": "_default", "version": 1, "active": true }
```

**Catat `id` (`wf_xxxxxxxx`) tiap workflow** — dipakai kalau mau
`unprovision` saat iterasi ulang.

Cek semua sudah aktif:

```bash
curl -sS "$VFLOW_BASE_URL/_vflow/api/workflows?tenant=_default"
# harapan: count: 6, masing-masing active: true
```

---

## 5. Test Tiap Endpoint dengan `curl`

> Webhook trigger di-hit di **port admin yang sama** (`7799`), dengan path
> sesuai `webhook_config.path` di masing-masing workflow YAML — bukan port
> terpisah. Ini konsisten dengan contoh resmi (`020-retail-order-intake`,
> dst).

### 5.1 Workflow 1 — Buka Keranjang Pesanan

```bash
curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/buka" \
  -H "Content-Type: application/json" \
  -d '{"pelanggan_id": "1", "kasir_id": "kasir01"}'
```

Ekspektasi:

```json
{"pesanan_id": 1, "status": "draft", "created_at": "..."}
```

Catat `pesanan_id` untuk langkah berikutnya.

Negative test (payload tidak lengkap → harus masuk error edge):

```bash
curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/buka" \
  -H "Content-Type: application/json" \
  -d '{"pelanggan_id": "1"}'
```

Ekspektasi:

```json
{"status":"rejected","code":"INVALID_PAYLOAD","message":"pelanggan_id dan kasir_id wajib diisi"}
```

### 5.2 Workflow 2 — Validasi Ketersediaan Produk

```bash
curl -sS -X POST "$VFLOW_BASE_URL/umkm/produk/validasi-stok" \
  -H "Content-Type: application/json" \
  -d '{"pesanan_id": "1", "produk_id": "1", "jumlah": 5}'
```

Ekspektasi (asumsi stok produk id=1 awalnya 50):

```json
{"tersedia": true, "stok_sisa": 45, "pesan": "Stok tersedia"}
```

Coba jumlah melebihi stok:

```bash
curl -sS -X POST "$VFLOW_BASE_URL/umkm/produk/validasi-stok" \
  -H "Content-Type: application/json" \
  -d '{"pesanan_id": "1", "produk_id": "1", "jumlah": 9999}'
```

Ekspektasi:

```json
{"tersedia": false, "stok_sisa": 50, "pesan": "Stok tidak cukup untuk jumlah yang dipesan"}
```

Produk tidak ada:

```bash
curl -sS -X POST "$VFLOW_BASE_URL/umkm/produk/validasi-stok" \
  -H "Content-Type: application/json" \
  -d '{"pesanan_id": "1", "produk_id": "9999", "jumlah": 1}'
```

Ekspektasi: `{"tersedia": false, "stok_sisa": 0, "pesan": "Produk tidak ditemukan"}`

### 5.3 Workflow 3 — Kalkulasi Total Tagihan (VRule)

Input wajib hanya `subtotal, total_item, tipe_pelanggan, metode_pembayaran,
metode_pengambilan` (sesuai Bab 5 spesifikasi). `pesanan_id` dan `kasir_id`
**opsional** — jika disertakan, dipakai untuk menautkan audit log detached
ke pesanan yang bersangkutan (lihat `build_audit_payload` di
`03-kalkulasi-tagihan.yaml`); jika tidak dikirim, audit log tetap tercatat
dengan `pesanan_id: "unknown"`.

Coba tiap kombinasi diskon/admin/ongkir untuk menguji rule pack:

```bash
# Member, QRIS, ambil sendiri -> diskon 5%, admin 0.7%, ongkir 0
curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/kalkulasi-tagihan" \
  -H "Content-Type: application/json" \
  -d '{
    "pesanan_id": "1",
    "kasir_id": "kasir01",
    "subtotal": 100000,
    "total_item": 3,
    "tipe_pelanggan": "member",
    "metode_pembayaran": "qris",
    "metode_pengambilan": "ambil_sendiri"
  }'
```

Ekspektasi: `diskon=5000`, `biaya_admin=700`, `biaya_pengiriman=0`,
`total_tagihan = 100000 - 5000 + 700 + 0 = 95700`.

```bash
# Grosir (>=20 item) + tunai + pengiriman reguler di bawah ambang gratis ongkir
curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/kalkulasi-tagihan" \
  -H "Content-Type: application/json" \
  -d '{
    "subtotal": 150000,
    "total_item": 25,
    "tipe_pelanggan": "reguler",
    "metode_pembayaran": "tunai",
    "metode_pengambilan": "reguler"
  }'
```

Ekspektasi: `diskon=15000` (10% grosir, menang lawan reguler-0%),
`biaya_admin=0`, `biaya_pengiriman=8000` (di bawah Rp200.000),
`total_tagihan=143000`.

```bash
# Subtotal >= 200rb -> gratis ongkir reguler
curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/kalkulasi-tagihan" \
  -H "Content-Type: application/json" \
  -d '{
    "subtotal": 250000,
    "total_item": 2,
    "tipe_pelanggan": "reguler",
    "metode_pembayaran": "kartu",
    "metode_pengambilan": "reguler"
  }'
```

Ekspektasi: `biaya_pengiriman=0`, `biaya_admin = round(250000*0.015) = 3750`,
`diskon=0`, `total_tagihan=253750`. Response juga membawa `findings` —
cek apakah finding `ADMIN_KARTU_HIGH_FEE` (WARN) dan/atau
`FREE_ONGKIR_CHECK` (INFO) muncul.

Setelah request ini, **Workflow 6 (audit log) terpanggil otomatis secara
detached** (lihat §5.6 cara verifikasinya).

### 5.4 Workflow 4 — Konfirmasi Pembayaran

```bash
curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/konfirmasi-pembayaran" \
  -H "Content-Type: application/json" \
  -d '{"pesanan_id": "1", "total_tagihan": 95700, "nominal_dibayar": 100000}'
```

Ekspektasi: `{"status_pembayaran":"lunas","kembalian":4300,"pesanan_id":"1"}`

Bayar kurang:

```bash
curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/konfirmasi-pembayaran" \
  -H "Content-Type: application/json" \
  -d '{"pesanan_id": "1", "total_tagihan": 95700, "nominal_dibayar": 50000}'
```

Ekspektasi: `{"status_pembayaran":"kurang_bayar","kembalian":0,"kekurangan":45700,...}`

Verifikasi di DB:

```bash
psql "$DSN" -c "select id, status, total_tagihan from pesanan where id = 1;"
```

### 5.5 Workflow 5 — Penyelesaian Pesanan

Pastikan dulu ada baris di `detail_pesanan` untuk `pesanan_id = 1`:

```bash
psql "$DSN" -c "insert into detail_pesanan (pesanan_id, produk_id, jumlah, harga_satuan) values (1, 1, 3, 18000);"
```

Lalu:

```bash
curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/selesaikan" \
  -H "Content-Type: application/json" \
  -d '{"pesanan_id": "1"}'
```

Ekspektasi: `{"status":"selesai","pesanan_id":"1"}`

Verifikasi stok produk id=1 berkurang 3 dan status pesanan jadi `selesai`:

```bash
psql "$DSN" -c "select id, stok from produk where id = 1;"
psql "$DSN" -c "select id, status from pesanan where id = 1;"
```

### 5.6 Workflow 6 — Audit Log

Test langsung (tanpa lewat Workflow 3):

```bash
curl -sS -X POST "$VFLOW_BASE_URL/umkm/internal/audit-log" \
  -H "Content-Type: application/json" \
  -d '{
    "pesanan_id": "1",
    "aktor_id": "kasir01",
    "aktivitas_tipe": "TEST_MANUAL",
    "payload_log": {"catatan": "uji coba audit log"},
    "waktu_kejadian": "2026-06-22T10:00:00Z"
  }'
```

Ekspektasi: `{"status": "SUCCESS"}`

Verifikasi tersimpan:

```bash
psql "$DSN" -c "select id, pesanan_id, aktivitas_tipe, payload_log from audit_log order by id desc limit 5;"
```

**Verifikasi pemanggilan otomatis dari Workflow 3 (detached edge):**
setelah memanggil `/umkm/pesanan/kalkulasi-tagihan` (§5.3), cek baris baru
dengan `aktivitas_tipe = 'KALKULASI_TAGIHAN'` muncul **setelah** respons
checkout sudah balik ke client (boleh ada delay singkat — itu memang
sifat detached, dijadwalkan setelah respons diemit):

```bash
psql "$DSN" -c "select * from audit_log where aktivitas_tipe = 'KALKULASI_TAGIHAN' order by id desc limit 1;"
```

> Catatan: Workflow 3 memanggil `workflow-db.kelompok3.vflow.parulian.my.id/umkm/internal/audit-log`
> (endpoint kelompok 3, sama dengan `VFLOW_BASE_URL` default). Jika kalian
> deploy ke server/kelompok lain, ganti `url` di node `call_audit_log` pada
> `03-kalkulasi-tagihan.yaml` menjadi `$VFLOW_BASE_URL` server kalian yang
> sesungguhnya sebelum test ini (lihat §6 troubleshooting).

---

## 6. Skenario End-to-End (Simulasi Satu Transaksi Penuh)

Jalankan urut seperti alur bisnis asli (Bab 4 spesifikasi):

```bash
# 1) Buka keranjang
PESANAN_ID=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/buka" \
  -H "Content-Type: application/json" \
  -d '{"pelanggan_id":"2","kasir_id":"kasir01"}' | jq -r '.pesanan_id')
echo "pesanan_id=$PESANAN_ID"

# 2) Validasi stok
curl -sS -X POST "$VFLOW_BASE_URL/umkm/produk/validasi-stok" \
  -H "Content-Type: application/json" \
  -d "{\"pesanan_id\":\"$PESANAN_ID\",\"produk_id\":\"1\",\"jumlah\":2}"

# (di sini idealnya backend Express juga INSERT ke detail_pesanan -
#  pada demo manual, lakukan manual seperti §5.5)
psql "$DSN" -c "insert into detail_pesanan (pesanan_id, produk_id, jumlah, harga_satuan) values ($PESANAN_ID, 1, 2, 18000);"

# 3) Kalkulasi tagihan
TOTAL=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/kalkulasi-tagihan" \
  -H "Content-Type: application/json" \
  -d '{"subtotal":36000,"total_item":2,"tipe_pelanggan":"member","metode_pembayaran":"tunai","metode_pengambilan":"ambil_sendiri"}' \
  | jq -r '.total_tagihan')
echo "total_tagihan=$TOTAL"

# 4) Konfirmasi pembayaran
curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/konfirmasi-pembayaran" \
  -H "Content-Type: application/json" \
  -d "{\"pesanan_id\":\"$PESANAN_ID\",\"total_tagihan\":$TOTAL,\"nominal_dibayar\":$TOTAL}"

# 5) Selesaikan pesanan
curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/selesaikan" \
  -H "Content-Type: application/json" \
  -d "{\"pesanan_id\":\"$PESANAN_ID\"}"

# 6) Cek audit log untuk pesanan ini
psql "$DSN" -c "select aktivitas_tipe, waktu_kejadian from audit_log where pesanan_id = '$PESANAN_ID' order by id;"
```

Pakai script otomatis di §7 untuk versi siap-pakai dari skenario ini.

---

## 7. Script Smoke Test Otomatis

Lihat `test/smoke-test.sh` (disertakan dalam paket). Cara pakai:

```bash
export VFLOW_BASE_URL="workflow-db.kelompok3.vflow.parulian.my.id"
export DSN="postgresql://postgres:umkm123@127.0.0.1:5432/umkm_db"  # untuk verifikasi DB, jalankan dari mesin yang punya akses psql ke DB yang sama
bash test/smoke-test.sh
```

Script ini menjalankan seluruh skenario §6 secara otomatis dan mencetak
`PASS`/`FAIL` per langkah berdasarkan field kunci di response JSON.

---

## 8. Troubleshooting

| Gejala | Kemungkinan Sebab | Solusi |
|---|---|---|
| `curl: (28) Connection timed out` | Security group AWS belum buka port 7799, atau endpoint IP berubah | Cek ulang `VFLOW_BASE_URL`, hubungi pengelola server |
| `HTTP 404` saat hit `/umkm/...` | Workflow belum diprovision, atau route belum sempat teregister | `curl $VFLOW_BASE_URL/_vflow/api/workflows` untuk cek `active:true`; tunggu beberapa saat setelah provision |
| Connector postgres error (`relation "pesanan" does not exist`) | `db/schema.sql` belum dijalankan, atau DSN salah | Jalankan ulang §1.1; pastikan `VFLOW_POSTGRES_URL` di server mengarah ke DB yang sudah berisi schema |
| Workflow 3 sukses tapi `audit_log` tidak terisi | Node `call_audit_log` menghardcode `workflow-db.kelompok3.vflow.parulian.my.id` (endpoint kelompok 3); beda di environment lain | Edit `03-kalkulasi-tagihan.yaml` node `call_audit_log.input_mappings.url` ke endpoint server yang sesuai lalu re-provision workflow 3 |
| `rule_set_id not found` saat panggil Workflow 3 | Rule pack belum di-compile, atau `rule_set_id` di YAML beda dengan yang di-compile | Cek `curl $VFLOW_BASE_URL/api/admin/vrules`; pastikan id `aturan_harga_umkm_v1` ada |
| Hasil kalkulasi diskon tidak sesuai ekspektasi | Override LWW: rule diskon yang ditulis lebih akhir (document order di `.vdicl`) menang saat kondisi tumpang tindih | Cek ulang urutan rule di `aturan_harga_umkm_v1.vdicl`, atau pertajam kondisi `when` agar mutually exclusive |
| Ingin reset / ulang dari awal | Workflow/rule pack masih versi lama tersangkut | `vflow-admin.sh workflows unprovision <id>` lalu provision ulang; `rules remove aturan_harga_umkm_v1` lalu compile ulang |

---

## 9. Checklist Sebelum Demo / Submit

- [ ] `curl $VFLOW_BASE_URL/health` → `healthy`
- [ ] `curl $VFLOW_BASE_URL/_vflow/api/workflows?tenant=_default` → `count: 6`, semua `active: true`
- [ ] `curl $VFLOW_BASE_URL/api/admin/vrules` → memuat `aturan_harga_umkm_v1`
- [ ] Workflow 1–6 masing-masing dites manual sesuai §5, response sesuai ekspektasi
- [ ] Skenario end-to-end §6 berjalan tanpa error dari awal sampai akhir
- [ ] `audit_log` terisi otomatis setiap kali Workflow 3 dipanggil (verifikasi detached edge)
- [ ] Stok produk di tabel `produk` berkurang setelah Workflow 5 dipanggil
