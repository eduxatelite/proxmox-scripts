FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir requests prometheus_client
COPY deadline_exporter.py .
EXPOSE 9300
CMD ["python", "deadline_exporter.py"]
