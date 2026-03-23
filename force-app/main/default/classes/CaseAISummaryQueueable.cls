/**
 * @description  Queueable Apex that calls the FastAPI AI Middleware
 *               to generate an AI summary for a newly created Case.
 *               Invoked by the Record-Triggered Flow on Case creation.
 *
 * @author       Sharad Yadav
 * @created      2026
 *
 * FIX (v2): AI_Summary__c is a LongTextArea field. Salesforce does NOT
 *           allow LongTextArea fields in SOQL WHERE clauses. The original
 *           "WHERE AI_Summary__c = null" caused a compile/runtime error.
 *           Fix: fetch the Case by Id only, then check AI_Summary__c
 *           value in Apex code for the idempotency guard.
 *
 * FLOW:
 *   Record-Triggered Flow  ->  CaseAISummaryQueueable  ->  FastAPI Middleware
 *                                                       ->  OpenAI LLM
 *                                                       ->  Update Case.AI_Summary__c
 */
public class CaseAISummaryQueueable implements Queueable, Database.AllowsCallouts {

    // --- Constants ------------------------------------------------------------
    private static final String NAMED_CREDENTIAL   = 'AI_Middleware';
    private static final String ENDPOINT_PATH      = '/summarise-case';
    private static final Integer HTTP_TIMEOUT_MS   = 30000;
    private static final Integer MAX_DESC_CHARS    = 3000;
    private static final Integer MAX_SUBJECT_CHARS = 255;

    // --- Fields ---------------------------------------------------------------
    private final Id caseId;

    // --- Constructor ----------------------------------------------------------
    public CaseAISummaryQueueable(Id caseId) {
        this.caseId = caseId;
    }

    // --- Execute --------------------------------------------------------------
    public void execute(QueueableContext ctx) {
        Case c = fetchCase(caseId);
        if (c == null) return;   // null = not found OR already summarised

        String requestBody  = buildRequestBody(c);
        HttpResponse response = makeCallout(requestBody);

        if (response == null) return;

        handleResponse(response, c.Id);
    }

    // --- Private: Fetch Case --------------------------------------------------
    private Case fetchCase(Id caseId) {

        List<Case> cases = [
            SELECT Id, Subject, Description, Status, Priority,
                   Type, Origin, Account.Name, Contact.Name,
                   AI_Summary__c
            FROM   Case
            WHERE  Id = :caseId
            LIMIT  1
        ];

        // Guard 1: record not found
        if (cases.isEmpty()) {
            logError('fetchCase', caseId, 'Case record not found.');
            return null;
        }

        // Guard 2: idempotency check in Apex code (NOT in SOQL WHERE)
        // Reason: AI_Summary__c is a LongTextArea — Salesforce does not
        // allow LongTextArea fields to be used in SOQL filter conditions.
        // Attempting WHERE AI_Summary__c = null causes:
        //   "field 'AI_Summary__c' can not be filtered in a query call"
        if (String.isNotBlank(cases[0].AI_Summary__c)) {
            logError('fetchCase', caseId,
                     'Skipped — AI_Summary__c is already populated. No duplicate call made.');
            return null;
        }

        return cases[0];
    }

    // --- Private: Build JSON Request ------------------------------------------
    private String buildRequestBody(Case c) {
        String subject     = truncate(c.Subject,     MAX_SUBJECT_CHARS);
        String description = truncate(c.Description, MAX_DESC_CHARS);

        Map<String, Object> payload = new Map<String, Object>{
            'case_id'      => c.Id,
            'subject'      => subject,
            'description'  => description,
            'status'       => c.Status,
            'priority'     => c.Priority,
            'case_type'    => c.Type,
            'origin'       => c.Origin,
            'account_name' => c.Account != null ? c.Account.Name : '',
            'contact_name' => c.Contact != null ? c.Contact.Name : ''
        };

        return JSON.serialize(payload);
    }

    // --- Private: HTTP Callout ------------------------------------------------
    private HttpResponse makeCallout(String body) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + NAMED_CREDENTIAL + ENDPOINT_PATH);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(HTTP_TIMEOUT_MS);
            req.setBody(body);

            return new Http().send(req);

        } catch (CalloutException e) {
            logError('makeCallout', caseId, e.getMessage());
            return null;
        }
    }

    // --- Private: Handle Response ---------------------------------------------
    private void handleResponse(HttpResponse res, Id caseId) {

        if (res.getStatusCode() == 200) {
            try {
                Map<String, Object> responseMap =
                    (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

                String summary      = (String) responseMap.get('summary');
                String model        = (String) responseMap.get('model_used');
                String safetyStatus = (String) responseMap.get('safety_status');

                if (String.isBlank(summary)) {
                    logError('handleResponse', caseId,
                             'Empty summary returned from AI middleware.');
                    return;
                }

                if ('BLOCKED'.equals(safetyStatus)) {
                    logError('handleResponse', caseId,
                             'AI response blocked by safety filter.');
                    updateCaseWithSummary(caseId,
                        '[AI Summary unavailable - content flagged by safety filter]', model);
                    return;
                }

                updateCaseWithSummary(caseId, summary, model);

            } catch (Exception e) {
                logError('handleResponse', caseId, 'JSON parse error: ' + e.getMessage());
            }

        } else {
            logError('handleResponse', caseId,
                     'HTTP ' + res.getStatusCode() + ': ' + res.getBody());
        }
    }

    // --- Private: Update Case -------------------------------------------------
    private void updateCaseWithSummary(Id caseId, String summary, String modelUsed) {
        try {
            update new Case(
                Id                         = caseId,
                AI_Summary__c              = summary,
                AI_Model_Used__c           = modelUsed,
                AI_Summary_Generated_At__c = System.now()
            );
        } catch (DmlException e) {
            logError('updateCaseWithSummary', caseId, e.getMessage());
        }
    }

    // --- Private: Helpers -----------------------------------------------------
    private String truncate(String val, Integer maxLen) {
        if (String.isBlank(val)) return '';
        return val.length() > maxLen
            ? val.substring(0, maxLen) + '...[truncated]'
            : val;
    }

    private void logError(String context, Id recordId, String message) {
        System.debug(LoggingLevel.ERROR,
            '[CaseAISummary] ' + context + ' | CaseId: ' + recordId + ' | ' + message);
    }

    // --- Invocable Method (called from Flow) ----------------------------------
    @InvocableMethod(
        label       = 'Enqueue AI Case Summary Generation'
        description = 'Enqueues a Queueable job to call the AI middleware and generate a case summary.'
    )
    public static void enqueueSummaryGeneration(List<Id> caseIds) {
        for (Id caseId : caseIds) {
            if (caseId != null) {
                System.enqueueJob(new CaseAISummaryQueueable(caseId));
            }
        }
    }
}
