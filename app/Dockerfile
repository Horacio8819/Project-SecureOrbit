FROM python:3.9-slim
RUN pip install flask
WORKDIR /app
COPY app.py .
EXPOSE 5000
CMD ["python", "app.py"]
