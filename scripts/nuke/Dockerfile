FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir prometheus-client requests
COPY nuke_exporter.py .
EXPOSE 9200
CMD ["python", "nuke_exporter.py"]
