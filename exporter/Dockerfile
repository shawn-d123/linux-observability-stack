FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY tcp_exporter.py targets.yml ./

# Run as a normal user, the exporter doesn't need root to open TCP connections
RUN useradd --no-create-home exporter
USER exporter

EXPOSE 9105
CMD ["python", "tcp_exporter.py"]
