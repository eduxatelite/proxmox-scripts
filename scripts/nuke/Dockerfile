FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY nuke_exporter.py .
EXPOSE 9200
CMD ["python", "nuke_exporter.py"]
