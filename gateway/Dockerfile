FROM python:3.12-alpine

WORKDIR /app
COPY spider_gateway_server.py /app/spider_gateway_server.py

ENV MARCO_GATEWAY_HOST=0.0.0.0 \
    MARCO_GATEWAY_PORT=9981 \
    MARCO_GATEWAY_NAME="Marco Docker Gateway"

EXPOSE 9981/tcp 41978/udp
CMD ["python3", "/app/spider_gateway_server.py"]
