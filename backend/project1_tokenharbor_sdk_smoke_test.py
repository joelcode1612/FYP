import os
from pathlib import Path
from dotenv import load_dotenv
from openai import OpenAI

# Load backend/.env
env_path = Path(__file__).resolve().parent / ".env"
load_dotenv(dotenv_path=env_path, override=False)

api_key = os.getenv("TOKENHARBOR_API_KEY")

if not api_key:
    raise RuntimeError("TOKENHARBOR_API_KEY is missing")

client = OpenAI(
    api_key=api_key,
    base_url="https://tokenharbor.ai/v1",
    max_retries=0,
)

res = client.chat.completions.create(
    model="mimo-v2.6-flash:free",
    messages=[
        {"role": "user", "content": "Why is the sky blue?"}
    ],
)

print(res.choices[0].message.content)