---
model: gpt-4-0613
---

# user

Get me the current weather in New York.

---

# assistant

### function_call: get_current_weather

```json
{
  "location": "New York"
}

```

---

# function

### function: get_current_weather

{"temperature": "15", "unit": "celsius", "description": "Partly cloudy", "location": "New York"}

---

# assistant

The current weather in New York is partly cloudy with a temperature of 15°C.

---
