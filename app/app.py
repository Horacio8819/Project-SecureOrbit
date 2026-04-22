from flask import Flask
app = Flask(__name__)

@app.route("/health")
def health():
    return {"status": "healthy"}, 200

@app.route("/")
def index():
    return {"message": "GDS Mission Dashboard running"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
