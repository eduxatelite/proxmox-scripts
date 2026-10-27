FROM python:3.11-slim
WORKDIR /app
COPY rlmutil .
RUN chmod +x rlmutil
COPY nuke_exporter.py .
EXPOSE 9200
CMD ["python", "nuke_exporter.py"]
