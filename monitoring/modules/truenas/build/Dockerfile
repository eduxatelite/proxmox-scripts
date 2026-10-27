FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir "websocket-client==1.8.0" "prometheus_client==0.21.1"
COPY truenas_exporter.py .
EXPOSE 9310
USER nobody
CMD ["python", "-u", "truenas_exporter.py"]
