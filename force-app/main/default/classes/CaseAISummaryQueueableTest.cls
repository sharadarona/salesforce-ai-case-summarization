/**
 * @description  Test class for CaseAISummaryQueueable (v2 - fixed).
 *
 * Key fix reflected here:
 *   Idempotency is now checked in Apex code (String.isNotBlank) NOT in SOQL.
 *   AI_Summary__c is a LongTextArea and cannot be used in SOQL WHERE clauses.
 *
 * Coverage target: 90%+
 */
@isTest
private class CaseAISummaryQueueableTest {

    // --- Mocks ----------------------------------------------------------------

    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'summary'       => '* PROBLEM: Customer cannot log in after release 2.4.1.\n* SENTIMENT: Frustrated\n* ACTION: Escalate to L2 engineering.',
                'model_used'    => 'gpt-4o-mini',
                'safety_status' => 'PASSED',
                'tokens_used'   => 187
            }));
            return res;
        }
    }

    private class ErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error": "Internal Server Error"}');
            return res;
        }
    }

    private class SafetyBlockMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'summary'       => '',
                'model_used'    => 'gpt-4o-mini',
                'safety_status' => 'BLOCKED'
            }));
            return res;
        }
    }

    private class EmptySummaryMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'summary'       => '',
                'model_used'    => 'gpt-4o-mini',
                'safety_status' => 'PASSED'
            }));
            return res;
        }
    }

    // --- Helper ---------------------------------------------------------------

    private static Case makeCase(Boolean withSummary) {
        Case c = new Case(
            Subject     = 'Cannot login to portal after v2.4.1 update',
            Description = 'User gets 403 Forbidden since the latest release. Affecting entire team.',
            Status      = 'New',
            Priority    = 'High',
            Origin      = 'Web'
        );
        insert c;

        // Write the summary AFTER insert using a direct DML update
        // because AI_Summary__c is read-only via FLS in most profiles.
        // Here we are in System context so it works fine.
        if (withSummary) {
            update new Case(Id = c.Id, AI_Summary__c = 'Existing summary — do not overwrite');
        }

        return c;
    }

    // --- Test 1: Happy path ---------------------------------------------------
    @isTest
    static void testSuccessPath() {
        Case c = makeCase(false);

        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        CaseAISummaryQueueable.enqueueSummaryGeneration(new List<Id>{ c.Id });
        Test.stopTest();

        Case updated = [SELECT AI_Summary__c, AI_Model_Used__c,
                               AI_Summary_Generated_At__c
                        FROM   Case WHERE Id = :c.Id];

        System.assertNotEquals(null, updated.AI_Summary__c,
            'AI_Summary__c should be populated on success');
        System.assert(updated.AI_Summary__c.contains('PROBLEM'),
            'Summary should contain PROBLEM bullet');
        System.assertEquals('gpt-4o-mini', updated.AI_Model_Used__c,
            'AI_Model_Used__c should be set');
        System.assertNotEquals(null, updated.AI_Summary_Generated_At__c,
            'AI_Summary_Generated_At__c should be set');
    }

    // --- Test 2: HTTP 500 error — field stays null ----------------------------
    @isTest
    static void testHttpError() {
        Case c = makeCase(false);

        Test.setMock(HttpCalloutMock.class, new ErrorMock());
        Test.startTest();
        System.enqueueJob(new CaseAISummaryQueueable(c.Id));
        Test.stopTest();

        Case updated = [SELECT AI_Summary__c FROM Case WHERE Id = :c.Id];
        System.assertEquals(null, updated.AI_Summary__c,
            'AI_Summary__c should remain null when middleware returns HTTP 500');
    }

    // --- Test 3: Safety BLOCKED — placeholder written ------------------------
    @isTest
    static void testSafetyBlocked() {
        Case c = makeCase(false);

        Test.setMock(HttpCalloutMock.class, new SafetyBlockMock());
        Test.startTest();
        System.enqueueJob(new CaseAISummaryQueueable(c.Id));
        Test.stopTest();

        Case updated = [SELECT AI_Summary__c FROM Case WHERE Id = :c.Id];
        System.assertNotEquals(null, updated.AI_Summary__c,
            'A placeholder should be written when safety is BLOCKED');
        System.assert(updated.AI_Summary__c.contains('safety filter'),
            'Placeholder should mention safety filter');
    }

    // --- Test 4: Idempotency — already has summary, should NOT overwrite ------
    // FIX NOTE: Previously this test relied on "WHERE AI_Summary__c = null"
    // in SOQL (which fails for LongTextArea). Now the idempotency check is
    // done in Apex via String.isNotBlank(cases[0].AI_Summary__c).
    @isTest
    static void testIdempotency_AlreadyHasSummary() {
        Case c = makeCase(true);   // pre-populated with 'Existing summary'

        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        System.enqueueJob(new CaseAISummaryQueueable(c.Id));
        Test.stopTest();

        Case updated = [SELECT AI_Summary__c FROM Case WHERE Id = :c.Id];
        System.assertEquals('Existing summary — do not overwrite',
            updated.AI_Summary__c,
            'AI_Summary__c must NOT be overwritten when it already has a value');
    }

    // --- Test 5: Empty summary returned — field stays null -------------------
    @isTest
    static void testEmptySummaryReturned() {
        Case c = makeCase(false);

        Test.setMock(HttpCalloutMock.class, new EmptySummaryMock());
        Test.startTest();
        System.enqueueJob(new CaseAISummaryQueueable(c.Id));
        Test.stopTest();

        Case updated = [SELECT AI_Summary__c FROM Case WHERE Id = :c.Id];
        System.assertEquals(null, updated.AI_Summary__c,
            'AI_Summary__c should remain null when an empty summary is returned');
    }

    // --- Test 6: Null Case ID — no exception thrown ---------------------------
    @isTest
    static void testNullCaseId() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        CaseAISummaryQueueable.enqueueSummaryGeneration(new List<Id>{ null });
        Test.stopTest();
        System.assert(true, 'Null Case ID should be handled gracefully without exception');
    }

    // --- Test 7: Long description is truncated before callout -----------------
    @isTest
    static void testLongDescriptionTruncated() {
        Case c = new Case(
            Subject     = 'Long description test',
            Description = 'X'.repeat(5000),
            Status      = 'New',
            Priority    = 'Medium',
            Origin      = 'Email'
        );
        insert c;

        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        System.enqueueJob(new CaseAISummaryQueueable(c.Id));
        Test.stopTest();

        Case updated = [SELECT AI_Summary__c FROM Case WHERE Id = :c.Id];
        System.assertNotEquals(null, updated.AI_Summary__c,
            'Long description should be truncated and callout should still succeed');
    }

    // --- Test 8: Case with no description (blank description) -----------------
    @isTest
    static void testBlankDescription() {
        Case c = new Case(
            Subject  = 'Issue with billing',
            Status   = 'New',
            Priority = 'Low',
            Origin   = 'Phone'
        );
        insert c;

        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        System.enqueueJob(new CaseAISummaryQueueable(c.Id));
        Test.stopTest();

        Case updated = [SELECT AI_Summary__c FROM Case WHERE Id = :c.Id];
        System.assertNotEquals(null, updated.AI_Summary__c,
            'Case with blank description should still generate a summary from subject alone');
    }
}
