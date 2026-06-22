# Menggunakan base image VFlow Engine resmi (sesuaikan versinya jika ada spesifik)
FROM vflow/engine:latest

# Set folder kerja di dalam container
WORKDIR /app

# Salin semua file dari repo kamu (termasuk folder docs, yaml, dll) ke dalam container
COPY . .

# Ekspos port sesuai kebutuhan engine VFlow kamu
EXPOSE 7799

# Perintah untuk menjalankan engine VFlow saat container dinyalakan
CMD ["./vflow-server", "--config", "config.yaml"]