/**
 * @description     Unit tests for DNAMSIDPCallout using DNAMSIDPCalloutMock (no real callouts).
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSIDPCalloutTest {
    private static final String NAMED_CREDENTIAL = 'DNAMSMuleSoftIDP';
    private static final String POST_PATH = '/api/v1/organizations/org/actions/act/versions/1.0.0/executions';
    private static final String CALLBACK_URL = 'https://example.my.salesforce-sites.com/cb?t=1&sig=x';
    // 3 MB + 1 byte: length mod 3 = 1, the padding case that needs the most string work
    private static final Integer LARGE_FILE_BYTES = 3 * 1024 * 1024 + 1;
    private static final String LARGE_FILE_MARK = 'DNAMSIDPCalloutTest.largeFile';

    /**
     * @description Live settings and an action for every test.
     * @return      Action config
     **/
    private static DNAMSIDPWrapper.ActionConfig setupAction() {
        DNAMS_PackageReviewPipelineService.settingsOverride = new DNAMS_Pipeline_Setting__mdt(
            IDPMode__c = DNAMSPipelineConstants.IDP_MODE_LIVE,
            IDPNamedCredential__c = NAMED_CREDENTIAL
        );
        DNAMSIDPWrapper.ActionConfig action = new DNAMSIDPWrapper.ActionConfig();
        action.postPath = POST_PATH;
        action.getPath = POST_PATH + '/{executionId}';
        return action;
    }

    /**
     * @description Submit request with the given file body.
     * @param action   Action
     * @param fileBody File content
     * @return         Request
     **/
    private static DNAMSIDPWrapper.SubmitRequest buildRequest(DNAMSIDPWrapper.ActionConfig action, String fileBody) {
        DNAMSIDPWrapper.SubmitRequest request = new DNAMSIDPWrapper.SubmitRequest();
        request.action = action;
        request.fileName = 'dealer.pdf';
        request.fileBody = Blob.valueOf(fileBody);
        request.callbackUrl = CALLBACK_URL;
        return request;
    }

    /**
     * @description 201 with id: success; the multipart body holds both parts and the exact file bytes for every
     *              base64 padding case (file length mod 3 = 0, 1, 2).
     **/
    @IsTest
    static void testSubmitDocumentBuildsMultipartBody() {
        DNAMSIDPWrapper.ActionConfig action = setupAction();
        Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{"id":"exec-1","status":"ACKNOWLEDGED"}', 200, '{}'));
        List<String> files = new List<String>{ '%PDF-1.4 abc', '%PDF-1.4 abcd', '%PDF-1.4 abcde' };
        List<String> bodies = new List<String>();
        DNAMSIDPWrapper.SubmitResult result;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            for (String file : files) {
                result = new DNAMSIDPCallout().submitDocument(buildRequest(action, file));
                bodies.add(DNAMSIDPCalloutMock.lastRequest.getBodyAsBlob().toString());
            }
            Test.stopTest();
        }
        HttpRequest sent = DNAMSIDPCalloutMock.lastRequest;
        String boundary = sent.getHeader('Content-Type').substringAfter('boundary=');
        Assert.isTrue(result.isSuccess, 'Submit succeeds');
        Assert.areEqual('exec-1', result.executionId, 'Execution id from "id"');
        Assert.areEqual('ACKNOWLEDGED', result.executionStatus, 'Status parsed');
        Assert.areEqual('callout:' + NAMED_CREDENTIAL + POST_PATH, sent.getEndpoint(), 'Named Credential endpoint');
        for (Integer index = 0; index < files.size(); index++) {
            String body = bodies[index];
            Assert.isTrue(body.contains('name="callback"'), 'Callback part present');
            Assert.isTrue(body.contains('{"noAuthUrl":"' + CALLBACK_URL + '"}'), 'Callback JSON present');
            Assert.isTrue(body.contains('name="file"; filename="dealer.pdf"'), 'File part present');
            Assert.isTrue(body.contains('\r\n\r\n' + files[index] + '\r\n--' + boundary + '--'), 'Exact file bytes then closing boundary: ' + index);
        }
    }

    /**
     * @description 200 with executionId is accepted as well.
     **/
    @IsTest
    static void testSubmitDocumentReadsExecutionIdKey() {
        DNAMSIDPWrapper.ActionConfig action = setupAction();
        Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(200, '{"executionId":"exec-2"}', 200, '{}'));
        DNAMSIDPWrapper.SubmitResult result;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            result = new DNAMSIDPCallout().submitDocument(buildRequest(action, 'x'));
            Test.stopTest();
        }
        Assert.areEqual('exec-2', result.executionId, 'Execution id from "executionId"');
        Assert.areEqual(1, DNAMSIDPCalloutMock.postCount, 'One POST');
    }

    /**
     * @description Non-2xx, unparseable 2xx, 2xx without id and callout exception all fail without throwing.
     **/
    @IsTest
    static void testSubmitDocumentFailures() {
        DNAMSIDPWrapper.ActionConfig action = setupAction();
        List<DNAMSIDPWrapper.SubmitResult> results = new List<DNAMSIDPWrapper.SubmitResult>();
        List<DNAMSIDPCalloutMock> mocks = new List<DNAMSIDPCalloutMock>{
            new DNAMSIDPCalloutMock(500, '{"error":"boom"}', null, null),
            new DNAMSIDPCalloutMock(201, 'not json', null, null),
            new DNAMSIDPCalloutMock(201, '{"status":"ACKNOWLEDGED"}', null, null),
            new DNAMSIDPCalloutMock(null, null, null, null)
        };
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            for (DNAMSIDPCalloutMock mock : mocks) {
                Test.setMock(HttpCalloutMock.class, mock);
                results.add(new DNAMSIDPCallout().submitDocument(buildRequest(action, 'x')));
            }
            Test.stopTest();
        }
        Assert.areEqual('IDP POST returned HTTP 500', results[0].errorMessage, 'HTTP error reported');
        Assert.areEqual(500, results[0].statusCode, 'Status kept');
        Assert.isTrue(results[1].errorMessage.contains('JSONException'), 'Parse failure after 2xx handled');
        Assert.areEqual('IDP POST response has no execution id', results[2].errorMessage, 'Missing id reported');
        Assert.isTrue(results[3].errorMessage.contains('Simulated IDP callout failure'), 'Callout exception handled');
        for (DNAMSIDPWrapper.SubmitResult result : results) {
            Assert.isFalse(result.isSuccess, 'Every failure is isSuccess = false');
        }
    }

    /**
     * @description GET success replaces {executionId}; GET 404 and unparseable body fail.
     **/
    @IsTest
    static void testFetchExecution() {
        DNAMSIDPWrapper.ActionConfig action = setupAction();
        DNAMSIDPWrapper.ExecutionResult okResult;
        DNAMSIDPWrapper.ExecutionResult notFound;
        DNAMSIDPWrapper.ExecutionResult badBody;
        String endpoint;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(null, null, 200, '{"id":"exec-1","status":"SUCCEEDED","pages":[]}'));
            okResult = new DNAMSIDPCallout().fetchExecution(action, 'exec-1');
            endpoint = DNAMSIDPCalloutMock.lastRequest.getEndpoint();
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(null, null, 404, '{"error":"gone"}'));
            notFound = new DNAMSIDPCallout().fetchExecution(action, 'exec-1');
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(null, null, 200, '<html/>'));
            badBody = new DNAMSIDPCallout().fetchExecution(action, 'exec-1');
            Test.stopTest();
        }
        Assert.isTrue(okResult.isSuccess, 'GET succeeds');
        Assert.areEqual(DNAMSPipelineConstants.IDP_SUCCEEDED, okResult.executionStatus, 'Status parsed');
        Assert.areEqual('callout:' + NAMED_CREDENTIAL + POST_PATH + '/exec-1', endpoint, 'executionId placed in GetPath');
        Assert.areEqual(3, DNAMSIDPCalloutMock.getCount, 'Three GETs');
        Assert.isFalse(notFound.isSuccess, '404 fails');
        Assert.areEqual(404, notFound.statusCode, 'Status kept');
        Assert.isFalse(badBody.isSuccess, 'Unparseable body fails');
    }

    /**
     * @description A 3 MB file (worst base64 padding case) is sent inside a Queueable, where the 12 MB async heap
     *              applies, without hitting the heap limit; the multipart body carries the whole file.
     **/
    @IsTest
    static void testSubmitDocumentThreeMegabyteFileFitsAsyncHeap() {
        setupAction();
        Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{"id":"exec-large","status":"ACKNOWLEDGED"}', 200, '{}'));
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            System.enqueueJob(new LargeFileSubmitQueueable(LARGE_FILE_BYTES));
            Test.stopTest();
            List<AIReviewErrorLog__c> marks = [SELECT Message__c FROM AIReviewErrorLog__c WHERE SourceClass__c = :LARGE_FILE_MARK WITH SYSTEM_MODE LIMIT 1];
            Assert.areEqual(1, marks.size(), 'The 3 MB submit finished without a heap limit exception');
            Assert.isTrue(marks[0].Message__c.startsWith('exec-large|'), 'Submit succeeded: ' + marks[0].Message__c);
            Integer sentBytes = Integer.valueOf(marks[0].Message__c.split('\\|')[1]);
            Assert.isTrue(sentBytes > LARGE_FILE_BYTES, 'Multipart body includes the whole 3 MB file: ' + sentBytes);
        }
    }

    /**
     * @description Builds a large file and submits it from async context; records the outcome as a log row.
     **/
    @SuppressWarnings('PMD.QueueableWithoutFinalizer') // test-only job; a failure is what the test detects
    private class LargeFileSubmitQueueable implements Queueable, Database.AllowsCallouts {
        private Integer fileBytes;

        /**
         * @description Creates the job.
         * @param fileBytes Size of the generated file
         **/
        private LargeFileSubmitQueueable(Integer fileBytes) {
            this.fileBytes = fileBytes;
        }

        /**
         * @description Sends the generated file through the live client (mocked HTTP).
         * @param context Queueable context
         **/
        public void execute(QueueableContext context) {
            DNAMSIDPWrapper.SubmitRequest request = new DNAMSIDPWrapper.SubmitRequest();
            request.action = setupAction();
            request.fileName = 'large.pdf';
            request.fileBody = Blob.valueOf('A'.repeat(fileBytes));
            request.callbackUrl = CALLBACK_URL;
            DNAMSIDPWrapper.SubmitResult result = new DNAMSIDPCallout().submitDocument(request);
            Integer sentBytes = DNAMSIDPCalloutMock.lastRequest.getBodyAsBlob().size();
            insert as system new AIReviewErrorLog__c(SourceClass__c = LARGE_FILE_MARK, Message__c = result.executionId + '|' + sentBytes);
        }
    }
}
