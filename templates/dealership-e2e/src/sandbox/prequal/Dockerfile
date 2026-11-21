FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN useradd --create-home --uid 10001 sandbox
WORKDIR /app
COPY main.py synthetic_credit_fixtures.py ./
USER sandbox

ENTRYPOINT ["python", "main.py"]
