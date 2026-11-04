/**
 * @description     Tests DNAMSExtractionSubmitBatch: successful POST, POST failure, a whole scope in one execute,
 *                  cancelled run and a missing signing key.
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
private class DNAMSExtractionSubmitBatchTest {
    private static final String ORG_CHART = 'Org Chart';

    /** Test client: unique execution ids per submit, records the requests. */
    private class RecordingClient implements IDocumentExtractionClient {
        private List<DNAMSIDPWrapper.SubmitRequest> requests = new List<DNAMSIDPWrapper.SubmitRequest>();

        /**
         * @description Records the request and returns a unique execution id.
         * @param request Submit request
         * @return        Successful submit result
         **/
        public DNAMSIDPWrapper.SubmitResult submitDocument(DNAMSIDPWrapper.SubmitRequest request) {
            requests.add(request);
            DNAMSIDPWrapper.SubmitResult result = new DNAMSIDPWrapper.SubmitResult();
            result.isSuccess = true;
            result.statusCode = 201;
            result.executionId = 'exec-' + requests.size();
            result.executionStatus = 'ACKNOWLEDGED';
            return result;
        }

        /**
         * @description Never expected from the submit batch.
         * @param action      IDP action
         * @param executionId Execution id
         * @return            Never returns
         **/
        public DNAMSIDPWrapper.ExecutionResult fetchExecution(DNAMSIDPWrapper.ActionConfig action, String executionId) {
            throw new DNAMSPipelineException('The submit batch must not fetch results');
        }
    }

    @IsTest
    static void testExecutePostSucceedsRowInProgressAndCleanupScheduled() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            DNAMSExtractionPipelineTest.insertRow(fixture, ORG_CHART, DNAMSPipelineConstants.ROW_PENDING);
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{"id":"exec-1","status":"ACKNOWLEDGED"}', 200, '{}'));

            Test.startTest();
            Database.executeBatch(new DNAMSExtractionSubmitBatch(fixture.runId), 10);
            Test.stopTest();

            AIReviewStageResult__c row = DNAMSExtractionPipelineTest.rowsByDocumentType(fixture.runId).get(ORG_CHART);
            String jobName = 'DNAMS IDP cleanup ' + fixture.runId + '%';
            Assert.areEqual(1, DNAMSIDPCalloutMock.postCount, 'postCount has the expected value');
            Assert.areEqual(DNAMSPipelineConstants.ROW_IN_PROGRESS, row.ProcessingStatus__c, 'ProcessingStatus__c has the expected value');
            Assert.areEqual('exec-1', row.MuleSoftExecutionId__c, 'MuleSoftExecutionId__c has the expected value');
            Assert.areEqual('ACKNOWLEDGED', row.MuleSoftExecutionStatus__c, 'MuleSoftExecutionStatus__c has the expected value');
            Assert.isNotNull(row.SubmittedAt__c, 'SubmittedAt__c is set');
            Assert.areEqual(
                1,
                [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :jobName],
                'Timeout cleanup scheduled once'
            );
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_RUNNING, DNAMSExtractionPipelineTest.reloadRun(fixture.runId).Status__c, 'Run waits for the callback');
        }
    }

    @IsTest
    static void testExecutePostFailsRowErrorAndPostErrorLog() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            AIReviewStageResult__c inserted = DNAMSExtractionPipelineTest.insertRow(fixture, ORG_CHART, DNAMSPipelineConstants.ROW_PENDING);
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(400, '{"error":"bad file"}', 200, '{}'));

            Test.startTest();
            Database.executeBatch(new DNAMSExtractionSubmitBatch(fixture.runId), 10);
            Test.stopTest();

            AIReviewStageResult__c row = DNAMSExtractionPipelineTest.rowsByDocumentType(fixture.runId).get(ORG_CHART);
            Assert.areEqual(DNAMSPipelineConstants.ROW_ERROR, row.ProcessingStatus__c, 'ProcessingStatus__c has the expected value');
            Assert.isTrue(row.ProcessingErrorDetails__c.contains('HTTP 400'), row.ProcessingErrorDetails__c);
            List<AIReviewErrorLog__c> logs = DNAMSExtractionPipelineTest.logsOf(fixture.runId, DNAMSPipelineConstants.ERROR_POST);
            Assert.areEqual(1, logs.size(), 'Collection size has the expected value');
            Assert.areEqual(inserted.Id, logs[0].StageResult__c, 'StageResult__c has the expected value');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, DNAMSExtractionPipelineTest.reloadRun(fixture.runId).ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');
        }
    }

    @IsTest
    static void testExecuteWholeScopeOneCallbackUrlPerRow() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            for (String documentType : DNAMSPipelineTestHelper.ELEMENT_TYPE_BY_DOCUMENT_TYPE.keySet()) {
                DNAMSExtractionPipelineTest.insertRow(fixture, documentType, DNAMSPipelineConstants.ROW_PENDING);
            }
            RecordingClient client = new RecordingClient();
            DNAMSIDPActionUtil.clientOverride = client;

            Test.startTest();
            Database.executeBatch(new DNAMSExtractionSubmitBatch(fixture.runId), 10);
            Test.stopTest();

            Map<String, AIReviewStageResult__c> rows = DNAMSExtractionPipelineTest.rowsByDocumentType(fixture.runId);
            Assert.areEqual(rows.size(), client.requests.size(), 'One submit per row in a single execute');
            String baseUrl = DNAMS_PackageReviewPipelineService.settingsOverride.IDPCallbackSiteURL__c + DNAMSPipelineConstants.CALLBACK_PATH;
            for (DNAMSIDPWrapper.SubmitRequest request : client.requests) {
                AIReviewStageResult__c row = rows.get(request.action.documentType);
                Assert.isTrue(request.callbackUrl.startsWith(baseUrl), request.callbackUrl);
                List<String> segments = request.callbackUrl.substringAfter(baseUrl + '/').split('/');
                Assert.areEqual(row.CallbackToken__c, segments[0], 'Token (first path segment) identifies the row');
                Assert.areEqual(4, segments.size(), 'Path carries token, action id, version and signature');
                Assert.isFalse(request.callbackUrl.contains('?'), 'No query string to lose');
                Assert.isNotNull(request.fileBody, 'File body loaded');
                Assert.areEqual(DNAMSPipelineConstants.ROW_IN_PROGRESS, row.ProcessingStatus__c, 'ProcessingStatus__c has the expected value');
            }
        }
    }

    @IsTest
    static void testExecuteCancelledRunNoSubmission() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            DNAMSExtractionPipelineTest.insertRow(fixture, ORG_CHART, DNAMSPipelineConstants.ROW_PENDING);
            DNAMS_PackageReviewPipelineService.cancelActiveRun(fixture.packageId);
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{"id":"exec-1"}', 200, '{}'));

            Test.startTest();
            Database.executeBatch(new DNAMSExtractionSubmitBatch(fixture.runId), 10);
            Test.stopTest();

            Assert.areEqual(0, DNAMSIDPCalloutMock.postCount, 'Nothing is posted for a cancelled run');
            Assert.areEqual(DNAMSPipelineConstants.ROW_PENDING, DNAMSExtractionPipelineTest.rowsByDocumentType(fixture.runId).get(ORG_CHART).ProcessingStatus__c, 'ProcessingStatus__c has the expected value');
        }
    }

    @IsTest
    static void testExecuteMissingSigningKeyFailsRun() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            DNAMSExtractionPipelineTest.insertRow(fixture, ORG_CHART, DNAMSPipelineConstants.ROW_PENDING);
            Database.delete([SELECT Id FROM DNAMSIDPSecret__c LIMIT 1], true);
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{"id":"exec-1"}', 200, '{}'));

            Test.startTest();
            Database.executeBatch(new DNAMSExtractionSubmitBatch(fixture.runId), 10);
            Test.stopTest();

            Assert.areEqual(0, DNAMSIDPCalloutMock.postCount, 'No unsigned callback URL is sent');
            AI_Package_Review_Run__c run = DNAMSExtractionPipelineTest.reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_FAILED, run.Status__c, 'Status__c has the expected value');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, run.ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');
            Assert.isFalse(DNAMSExtractionPipelineTest.logsOf(fixture.runId, DNAMSPipelineConstants.ERROR_PROCESSING).isEmpty(), 'isEmpty does not hold');
        }
    }
}
