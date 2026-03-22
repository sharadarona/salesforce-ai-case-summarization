# Salesforce AI Case Summarization

**GenAI + Salesforce integration** — Auto-generates a structured AI summary on every new Case using a secure FastAPI middleware, OpenAI GPT, input guardrails, PII redaction, and output safety filters.

---

## Architecture

```
Salesforce Case Created
        │
        ▼
Record-Triggered Flow  (Case_AI_Summary_On_Create)
        │  (After Insert, runs async via Queueable)
        ▼
CaseAISummaryQueueable.cls
        │  HTTP POST  callout:AI_Middleware/summarise-case
        ▼
┌─────────────────────────────────────────────────────┐
│              FastAPI AI Middleware                  │
│                                                     │
│  ┌─────────────┐ ┌──────────────┐ ┌──────────────┐  │ 
│  │   Input     │ │   Security   │ │    Prompt    │  │
│  │ Guardrails  │ │    Layer     │ │   Builder    │  │
│  │             │ │              │ │              │  │
│  │ • Injection │ │ • API Key    │ │ • System     │  │
│  │   detection │ │   auth       │ │   prompt     │  │
│  │ • PII       │ │ • HMAC       │ │ • Few-shot   │  │
│  │   redaction │ │   comparison │ │   structure  │  │
│  │ • Sanitize  │ │ • Rate limit │ │ • Context    │  │
│  └─────────────┘ └──────────────┘ └──────────────┘  │
│                        │                            │
│                        ▼                            │
│                  OpenAI GPT-4o-mini                 │
│                        │                            │
│           Output Validation + Safety Filter         │
│           • Blocked patterns check                  │
│           • Length validation                       │
│           • Structure verification                  │
└─────────────────────────────────────────────────────┘
        │
        ▼  JSON: { summary, model_used, safety_status, tokens_used }
        │
        ▼
CaseAISummaryQueueable — parses response
        │
        ▼
Update Case:
  AI_Summary__c               = "• PROBLEM: ..."
  AI_Model_Used__c            = "gpt-4o-mini"
  AI_Summary_Generated_At__c  = 2026-03-14T10:30:00Z
```

---
## How it Works
----
1. A new Case is saved in Salesforce.
2. The **Record-Triggered Flow** fires after save and enqueues an async Apex job.
3. **CaseAISummaryQueueable** makes an HTTP callout to the AI Middleware via Named Credential.
4. The middleware returns a summary which is written back to the Case.
----

## Project Structure

```
sharadarona/salesforce-ai-case-summarization
│
├── salesforce-ai-case-summarization/
│   ├──force-app/main/default/
├   │   ├── classes/
│   │   │      ├── CaseAISummaryQueueable.cls
│   │   │      └── CaseAISummaryQueueableTest.cls
│   │   ├── flows/
│   │   │   └── Case_AI_Summary_On_Create.flow-meta.xml
│   │   ├── namedCredentials/
│   │   │   └── AI_Middleware.namedCredential-meta.xml
│   │   ├── objects/
│   │   │   └── Case/
│   │   │       └── fields/
│   │   │           ├── AI_Summary__c.field-meta.xml
│   │   │           ├── AI_Model_Used__c.field-meta.xml
│   │   │           └── AI_Summary_Generated_At__c.field-meta.xml
│   │   └── permissionsets/
│   │       └── AI_Case_Summary_Access.permissionset-meta.xml
│   └─ manifest/
│      └── package.xml
└── README.md
**Middleware part is in below repo**
sharadarona/salesforce-ai-case-middleware
│
├── salesforce-ai-case-middleware/
│   ├── main.py                               ← FastAPI app (all layers)
│   ├── requirements.txt
│   ├── .env.example
│   └── tests/
│       └── test_middleware.py                ← Full pytest suite
│
└── README.md
```

---
## Salesforce Components

### Apex Classes

| Class | Description |
|---|---|
| `CaseAISummaryQueueable` | Queueable Apex that calls the FastAPI middleware (`POST /summarise-case`) and updates Case AI fields.
| Implements `Database.AllowsCallouts`. |
| `CaseAISummaryQueueableTest` | Test class for `CaseAISummaryQueueable`. |

### Flow

| Flow | Trigger | Description |
|---|---|---|
| `Case_AI_Summary_On_Create` | After Case is created (RecordAfterSave) | Collects the Case ID and calls the `@InvocableMethod` on
| `CaseAISummaryQueueable` to enqueue the async job. Faults are silently absorbed so Case saves are never blocked. |

### Custom Fields (Case Object)

| Field API Name | Type | Description |
|---|---|---|
| `AI_Summary__c` | LongTextArea | AI-generated summary of the Case. |
| `AI_Model_Used__c` | Text | Name of the LLM model that generated the summary. |
| `AI_Summary_Generated_At__c` | DateTime | Timestamp when the summary was generated. |

### Named Credential

| Name | Endpoint | Auth |
|---|---|---|
| `AI_Middleware` | Your FastAPI server URL | External Credential (APIKey) |

> Update the URL in the Named Credential to point to your FastAPI server before deploying.

### Permission Set

| Permission Set | Description |
|---|---|
| `AI_Case_Summary_Access` | Grants read-only access to all three AI Summary fields on Case. Assign to Support Agents who need to view AI-generated summaries. |

---

## Deployment

### Prerequisites
- Salesforce CLI installed
- Authorized org (`sf org login web`)
- FastAPI middleware running and accessible (ngrok / Render / etc.)

### Deploy All Components

```bash
sf project deploy start --manifest manifest/package.xml
```

### Deploy Individual Components

```bash
# Apex classes
sf project deploy start --source-dir force-app/main/default/classes

# Flow
sf project deploy start --source-dir force-app/main/default/flows

# Custom fields
sf project deploy start --source-dir force-app/main/default/objects

# Named credential
sf project deploy start --source-dir force-app/main/default/namedCredentials

# Permission set
sf project deploy start --source-dir force-app/main/default/permissionsets
```

### Run Apex Tests

```bash
sf apex run test --class-names CaseAISummaryQueueableTest --result-format human
```

---

## Named Credential Setup

Update the endpoint in `force-app/main/default/namedCredentials/AI_Middleware.namedCredential-meta.xml`:

| Environment | URL |
|---|---|
| Local dev | `http://localhost:8000` |
| ngrok | `https://xxxx.ngrok-free.app` |
| Render.com | `https://your-app-name.onrender.com` |

---
## Step-by-Step Setup

### Part A — Salesforce Setup

#### Step 1: Create Custom Fields on Case Object
Either deploy the XML via SFDX or create manually:
Go to Setup → Object Manager → Case → Fields & Relationships → New

| Field Label | API Name | Type | Length |
|---|---|---|---|
| AI Summary | AI_Summary__c | Long Text Area | 32768 |
| AI Model Used | AI_Model_Used__c | Text | 100 |
| AI Summary Generated At | AI_Summary_Generated_At__c | Date/Time | — |

#### Step 2: Deploy the Apex Class
1. Open VS Code with Salesforce Extension Pack
2. Authenticate: `sf org login web --alias myorg`
3. Copy `CaseAISummaryQueueable.cls` into `force-app/main/default/classes/`
4. Deploy: `sf project deploy start --source-dir force-app`

Or paste directly into Setup → Apex Classes → New.

#### Step 3: Create the Named Credential
Either deploy the XML via SFDX or create manually:
Setup → Security → Named Credentials → New Legacy Named Credential

```
Label          : AI Middleware
Name           : AI_Middleware
URL            : https://your-app.onrender.com   (or http://localhost:8000 for dev)
Identity Type  : Named Principal
Auth Protocol  : No Authentication
Custom Header  : X-API-Key = your-secret-key     (must match MIDDLEWARE_API_KEY in .env)
Allow Merge Fields in HTTP Body   : ✅
Allow Merge Fields in HTTP Header : ✅
```

#### Step 4: Create the Flow 
Either deploy the XML via SFDX or create manually:
- Setup → Flows → New Flow → Record-Triggered Flow
- Object: Case | Trigger: After Record Is Saved | When: New Record Only
- Condition: AI_Summary__c IS NULL
- Add Action: Apex → "Enqueue AI Case Summary Generation"
- Input: pass `{!$Record.Id}` into the `caseIds` collection variable
- Save and Activate

#### Step 5: Add Fields to Case Page Layout
Setup → Object Manager → Case → Page Layouts → Edit your layout
- Add a new section "AI Insights"
- Drag in: AI Summary, AI Model Used, AI Summary Generated At
- Set AI Summary to read-only for non-admin profiles

---

### Part B — Python Middleware Setup

#### Step 1: Clone and install
```bash
cd python-middleware
python3 -m venv venv
source venv/bin/activate    # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

#### Step 2: Configure environment
```bash
cp .env.example .env
```
Edit `.env`:
```env
OPENAI_API_KEY=sk-your-real-openai-key
MIDDLEWARE_API_KEY=generate-a-strong-random-secret-here
OPENAI_MODEL=gpt-4o-mini
MAX_TOKENS=500
TEMPERATURE=0.1
```

Generate a strong API key:
```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

#### Step 3: Run locally
```bash
uvicorn main:app --reload --port 8000
```

Test it:
```bash
curl -X POST http://localhost:8000/summarise-case \
  -H "Content-Type: application/json" \
  -H "X-API-Key: your-middleware-api-key" \
  -d '{
    "case_id": "500Hs00001XyZaABC",
    "subject": "Cannot login to portal after 2.4.1 update",
    "description": "Since the release of version 2.4.1 on Friday, I am getting a 403 Forbidden error when trying to access the customer portal. This is blocking our entire team.",
    "priority": "High",
    "origin": "Web",
    "account_name": "Acme Corp"
  }'
```

Expected response:
```json
{
  "case_id": "500Hs00001XyZaABC",
  "summary": "• PROBLEM: Customer cannot access the portal after the 2.4.1 release, receiving a 403 Forbidden error.\n• SENTIMENT: Frustrated\n• ACTION: Investigate the 2.4.1 release changes to authentication; check server-side access control logs.",
  "model_used": "gpt-4o-mini",
  "safety_status": "PASSED",
  "tokens_used": 187,
  "latency_ms": 1243,
  "generated_at": "2026-03-14T10:30:00+00:00"
}
```

#### Step 4: Run tests
```bash
pytest tests/test_middleware.py -v
```

#### Step 5: Connect Salesforce to local server (development)
Install ngrok (https://ngrok.com/), then:
```bash
ngrok http 8000
```
Copy the `https://xxxx.ngrok.io` URL into your Salesforce Named Credential.

#### Step 6: Deploy to production (Render.com — free tier)
1. Push your code to a GitHub repository
2. Go to render.com → New Web Service → connect your repo
3. Build command: `pip install -r requirements.txt`
4. Start command: `uvicorn main:app --host 0.0.0.0 --port $PORT`
5. Add environment variables in Render dashboard (copy from your .env)
6. Copy the Render HTTPS URL into your Salesforce Named Credential
7. Test by creating a new Case in Salesforce — AI Summary field should populate within ~5 seconds

---

## What Each Layer Does

### Input Guardrails
Runs before anything reaches the LLM:
- **Injection detection**: 10 regex patterns catch prompt injection attempts (ignore previous instructions, jailbreak, SQL injection, etc.)
- **PII redaction**: Automatically removes emails, phone numbers, credit cards, Aadhaar numbers before sending to OpenAI
- **Text sanitization**: Strips null bytes, control characters, excessive whitespace

### Security Layer
- **API Key authentication**: Every request must include `X-API-Key` header
- **HMAC constant-time comparison**: Prevents timing-based key guessing attacks
- **Pydantic validation**: Enforces Salesforce ID format, field length limits, required fields

### Prompt Builder
Constructs a structured two-part prompt:
- **System prompt**: Instructs the LLM to output exactly 3 bullets (PROBLEM / SENTIMENT / ACTION), be factual, keep it under 200 words
- **User prompt**: Injects sanitized/redacted case fields contextually (skips empty fields)
- **Temperature 0.1**: Near-deterministic output — consistent format across all cases

### Output Validation + Safety
After the LLM responds:
- Checks minimum and maximum length
- Blocks responses containing `<script>`, AI disclaimers, ignored-instruction patterns
- Verifies expected bullet structure is present
- Returns `safety_status: BLOCKED` if any check fails (Salesforce handles this gracefully)

### Apex Queueable (not a trigger)
Using Queueable instead of a synchronous trigger is critical:
- Callouts are not allowed in synchronous Apex triggers
- Queueable runs asynchronously after the transaction commits
- Idempotency guard (`WHERE AI_Summary__c = null`) prevents duplicate summaries
- `@InvocableMethod` makes it callable from Flow without direct trigger code

---

## Cost Estimate (OpenAI gpt-4o-mini)

| Volume | Input tokens/case | Output tokens/case | Cost/case | Monthly (1000 cases) |
|---|---|---|---|---|

| Low | ~300 | ~150 | ~$0.00007 | ~$0.07 |
| Medium | ~500 | ~200 | ~$0.00010 | ~$0.10 |
| High | ~800 | ~200 | ~$0.00014 | ~$0.14 |

gpt-4o-mini is approximately 15× cheaper than gpt-4o with 80% of the quality for structured summarisation tasks.

---

## Key Design Decisions 

1. **Queueable over Trigger**: Callouts require async context. Queueable is the correct Salesforce pattern.
2. **Named Credential over hardcoded URL**: Secrets never appear in code; URL can be changed without redeployment.
3. **FastAPI over direct OpenAI from Apex**: Middleware adds guardrails, PII protection, prompt versioning, and model-switching without Salesforce redeployment.
4. **PII redaction before LLM**: Salesforce records often contain sensitive data. Redacting before the API call is a data governance requirement in enterprise contexts.
5. **Idempotency guard**: `WHERE AI_Summary__c = null` ensures a case is never summarised twice even if the Flow fires multiple times.
6. **`safety_status` field**: Allows Salesforce admins to report on how often content is blocked — useful for compliance auditing.
