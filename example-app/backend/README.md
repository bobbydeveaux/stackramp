# Backend

This directory would contain your backend application (e.g., a Python FastAPI app).

The StackRamp platform will:
1. Build a Docker image (using the platform's default Dockerfile or your own)
2. Push to Artifact Registry
3. Deploy to Cloud Run

To scaffold a Python backend here:
```bash
pip install fastapi uvicorn
```

Create `main.py`:
```python
from fastapi import FastAPI

app = FastAPI()

@app.get("/")
def root():
    return {"status": "ok"}
```

Create `requirements.txt`:
```
fastapi
uvicorn
```
