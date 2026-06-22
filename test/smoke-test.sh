#!/usr/bin/env bash
# =============================================================================
# UMKM VFlow — smoke test end-to-end
# =============================================================================
#
# Menjalankan skenario bisnis penuh (buka keranjang -> validasi stok ->
# kalkulasi tagihan -> konfirmasi pembayaran -> selesaikan pesanan) lewat
# webhook VFlow yang sudah diprovision, dan mencetak PASS/FAIL per langkah.
#
# Prasyarat:
#   - curl, jq terinstall
#   - VFLOW_BASE_URL menunjuk ke server VFlow yang sudah diprovision
#     (lihat TESTING.md §2-4)
#   - (opsional) DSN menunjuk ke PostgreSQL yang dipakai server VFlow,
#     untuk verifikasi tambahan via psql. Jika psql tidak tersedia atau
#     DSN tidak di-set, verifikasi DB dilewati (tetap lanjut, hanya warning).
#
# Pakai:
#   export VFLOW_BASE_URL="workflow-db.kelompok3.vflow.parulian.my.id"
#   export DSN="postgresql://postgres:umkm123@127.0.0.1:5432/umkm_db"
#   bash test/smoke-test.sh
#
set -uo pipefail

VFLOW_BASE_URL="${VFLOW_BASE_URL:-http://127.0.0.1:7799}"
DSN="${DSN:-}"
PASS=0
FAIL=0

color() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
pass() { PASS=$((PASS+1)); echo "$(color 32 "[PASS]") $1"; }
fail() { FAIL=$((FAIL+1)); echo "$(color 31 "[FAIL]") $1"; }
info() { echo "$(color 36 "[INFO]") $1"; }

check_field() {
  # check_field <json> <jq_expr> <expected> <label>
  local json="$1" expr="$2" expected="$3" label="$4"
  local actual
  actual=$(echo "$json" | jq -r "$expr" 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    pass "$label (got: $actual)"
  else
    fail "$label (expected: $expected, got: $actual) | raw: $json"
  fi
}

require_field_present() {
  local json="$1" expr="$2" label="$3"
  local actual
  actual=$(echo "$json" | jq -r "$expr" 2>/dev/null)
  if [[ -n "$actual" && "$actual" != "null" ]]; then
    pass "$label (got: $actual)"
    echo "$actual"
  else
    fail "$label | raw: $json"
    echo ""
  fi
}

echo "=== 0. Health check ==="
HEALTH=$(curl -sS "$VFLOW_BASE_URL/health")
check_field "$HEALTH" ".status" "healthy" "Server VFlow healthy"

echo
echo "=== 1. Workflow 1 - Buka Keranjang Pesanan ==="
RESP1=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/buka" \
  -H "Content-Type: application/json" \
  -d '{"pelanggan_id":"1","kasir_id":"kasir01"}')
check_field "$RESP1" ".status" "draft" "Pesanan dibuat dengan status draft"
PESANAN_ID=$(require_field_present "$RESP1" ".pesanan_id" "pesanan_id diterima")

echo
info "Negative test: payload tidak lengkap"
RESP1_BAD=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/buka" \
  -H "Content-Type: application/json" \
  -d '{"pelanggan_id":"1"}')
check_field "$RESP1_BAD" ".status" "rejected" "Payload tidak lengkap ditolak"

if [[ -z "$PESANAN_ID" ]]; then
  fail "pesanan_id kosong, langkah selanjutnya dilewati"
  echo
  echo "=== Ringkasan: $PASS PASS, $FAIL FAIL ==="
  exit 1
fi

echo
echo "=== 2. Workflow 2 - Validasi Ketersediaan Produk ==="
RESP2=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/produk/validasi-stok" \
  -H "Content-Type: application/json" \
  -d "{\"pesanan_id\":\"$PESANAN_ID\",\"produk_id\":\"1\",\"jumlah\":2}")
check_field "$RESP2" ".tersedia" "true" "Stok produk id=1 cukup untuk 2 item"

info "Negative test: jumlah melebihi stok"
RESP2_BAD=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/produk/validasi-stok" \
  -H "Content-Type: application/json" \
  -d "{\"pesanan_id\":\"$PESANAN_ID\",\"produk_id\":\"1\",\"jumlah\":999999}")
check_field "$RESP2_BAD" ".tersedia" "false" "Jumlah melebihi stok ditolak"

info "Negative test: produk tidak ditemukan"
RESP2_NF=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/produk/validasi-stok" \
  -H "Content-Type: application/json" \
  -d "{\"pesanan_id\":\"$PESANAN_ID\",\"produk_id\":\"999999\",\"jumlah\":1}")
check_field "$RESP2_NF" ".pesan" "Produk tidak ditemukan" "Produk tidak ditemukan terdeteksi"

echo
echo "=== 3. Workflow 3 - Kalkulasi Total Tagihan (VRule) ==="
RESP3=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/kalkulasi-tagihan" \
  -H "Content-Type: application/json" \
  -d "{
    \"pesanan_id\": \"$PESANAN_ID\",
    \"kasir_id\": \"kasir01\",
    \"subtotal\": 100000,
    \"total_item\": 3,
    \"tipe_pelanggan\": \"member\",
    \"metode_pembayaran\": \"qris\",
    \"metode_pengambilan\": \"ambil_sendiri\"
  }")
check_field "$RESP3" ".diskon" "5000" "Diskon member 5% terhitung"
check_field "$RESP3" ".biaya_admin" "700" "Biaya admin QRIS 0,7% terhitung"
check_field "$RESP3" ".biaya_pengiriman" "0" "Biaya pengiriman ambil sendiri = 0"
check_field "$RESP3" ".total_tagihan" "95700" "Total tagihan akhir benar (95700)"
info "pesanan_id & kasir_id disertakan (opsional) agar detached audit-log tertaut ke pesanan_id=$PESANAN_ID"

info "Test rule grosir (>=20 item) override diskon member"
RESP3_GROSIR=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/kalkulasi-tagihan" \
  -H "Content-Type: application/json" \
  -d '{
    "subtotal": 150000,
    "total_item": 25,
    "tipe_pelanggan": "member",
    "metode_pembayaran": "tunai",
    "metode_pengambilan": "reguler"
  }')
check_field "$RESP3_GROSIR" ".diskon" "15000" "Diskon grosir 10% menang atas member"
check_field "$RESP3_GROSIR" ".biaya_pengiriman" "8000" "Ongkir reguler Rp8.000 (di bawah ambang gratis)"

info "Test gratis ongkir di atas ambang Rp200.000"
RESP3_FREEONGKIR=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/kalkulasi-tagihan" \
  -H "Content-Type: application/json" \
  -d '{
    "subtotal": 250000,
    "total_item": 2,
    "tipe_pelanggan": "reguler",
    "metode_pembayaran": "kartu",
    "metode_pengambilan": "reguler"
  }')
check_field "$RESP3_FREEONGKIR" ".biaya_pengiriman" "0" "Gratis ongkir di atas Rp200.000"
check_field "$RESP3_FREEONGKIR" ".biaya_admin" "3750" "Biaya admin kartu 1,5% terhitung"

TOTAL_TAGIHAN=$(echo "$RESP3" | jq -r '.total_tagihan')

echo
echo "=== 4. Workflow 4 - Konfirmasi Pembayaran ==="
RESP4=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/konfirmasi-pembayaran" \
  -H "Content-Type: application/json" \
  -d "{\"pesanan_id\":\"$PESANAN_ID\",\"total_tagihan\":$TOTAL_TAGIHAN,\"nominal_dibayar\":$TOTAL_TAGIHAN}")
check_field "$RESP4" ".status_pembayaran" "lunas" "Pembayaran pas dinyatakan lunas"
check_field "$RESP4" ".kembalian" "0" "Kembalian 0 saat bayar pas"

info "Negative test: bayar kurang dari total tagihan"
RESP4_KURANG=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/konfirmasi-pembayaran" \
  -H "Content-Type: application/json" \
  -d "{\"pesanan_id\":\"$PESANAN_ID\",\"total_tagihan\":$TOTAL_TAGIHAN,\"nominal_dibayar\":1000}")
check_field "$RESP4_KURANG" ".status_pembayaran" "kurang_bayar" "Bayar kurang terdeteksi"

echo
echo "=== 5. Workflow 5 - Penyelesaian Pesanan ==="
if [[ -n "$DSN" ]] && command -v psql >/dev/null 2>&1; then
  psql "$DSN" -c "insert into detail_pesanan (pesanan_id, produk_id, jumlah, harga_satuan) values ($PESANAN_ID, 1, 2, 18000);" >/dev/null 2>&1
  info "Baris detail_pesanan disisipkan untuk pesanan_id=$PESANAN_ID"
else
  info "DSN/psql tidak tersedia — pastikan detail_pesanan untuk pesanan_id=$PESANAN_ID sudah ada secara manual"
fi

RESP5=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/pesanan/selesaikan" \
  -H "Content-Type: application/json" \
  -d "{\"pesanan_id\":\"$PESANAN_ID\"}")
check_field "$RESP5" ".status" "selesai" "Pesanan berhasil diselesaikan"

echo
echo "=== 6. Workflow 6 - Audit Log (panggilan langsung) ==="
RESP6=$(curl -sS -X POST "$VFLOW_BASE_URL/umkm/internal/audit-log" \
  -H "Content-Type: application/json" \
  -d "{
    \"pesanan_id\": \"$PESANAN_ID\",
    \"aktor_id\": \"kasir01\",
    \"aktivitas_tipe\": \"SMOKE_TEST\",
    \"payload_log\": {\"sumber\": \"smoke-test.sh\"},
    \"waktu_kejadian\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
  }")
check_field "$RESP6" ".status" "SUCCESS" "Audit log manual berhasil disimpan"

echo
echo "=== 7. Verifikasi DB (opsional) ==="
if [[ -n "$DSN" ]] && command -v psql >/dev/null 2>&1; then
  STOK=$(psql "$DSN" -t -A -c "select stok from produk where id = 1;" 2>/dev/null)
  info "Stok produk id=1 setelah Workflow 5: $STOK"

  AUDIT_COUNT=$(psql "$DSN" -t -A -c "select count(*) from audit_log where pesanan_id = '$PESANAN_ID';" 2>/dev/null)
  if [[ "$AUDIT_COUNT" -ge 2 ]]; then
    pass "Audit log untuk pesanan_id=$PESANAN_ID >= 2 baris (manual + detached dari Workflow 3)"
  else
    fail "Audit log untuk pesanan_id=$PESANAN_ID hanya $AUDIT_COUNT baris — cek detached edge Workflow 3 (URL call_audit_log sudah benar?)"
  fi
else
  info "Verifikasi DB dilewati (DSN/psql tidak tersedia)"
fi

echo
echo "============================================="
echo " Ringkasan: $(color 32 "$PASS PASS"), $(color 31 "$FAIL FAIL")"
echo "============================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
