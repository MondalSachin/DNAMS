/**
 * @description     Tests DNAMSIDPCallbackQueueable: SUCCEEDED, failed IDP status, pending IDP status, HTTP error and
 *                  cancelled run, with the GET mocked by DNAMSIDPCalloutMock.
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
private class DNAMSIDPCallbackQueueableTest {
    private static final String ORG_CHART = 'Org Chart';

    /**
     * @description Reloads a stage result row with the fields the tests assert on.
     * @param rowId Stage result id
     * @return      The row
     **/
    private static AIReviewStageResult__c reloadRow(Id rowId) {
        return [
            SELECT ProcessingStatus__c, MuleSoftExecutionStatus__c, RawStageResponseJSON__c, ProcessingErrorDetails__c, ProcessingCompletedAt__c
            FROM AIReviewStageResult__c
            WHERE Id = :rowId
        ];
    }

    /**
     * @description Runs the callback processor for one row inside start/stopTest.
     * @param rowId Stage result id
     **/
    private static void runCallback(Id rowId) {
        Test.startTest();
        new DNAMSIDPCallbackQueueable(new Set<Id>{ rowId }).execute(null);
        Test.stopTest();
    }

    @IsTest
    static void testExecuteSucceededRowCompletedAndRunPasses() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            AIReviewStageResult__c row = DNAMSExtractionPipelineTest.insertRow(fixture, ORG_CHART, DNAMSPipelineConstants.ROW_IN_PROGRESS);
            // Match the small test response to a small expected structure so completion passes the schema check
            DNAMSExtractionCompletionHelper.expectedStructureOverride.put(row.IDPActionName__c, DNAMSPipelineTestHelper.TEST_EXPECTED_STRUCTURE);
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{}', 200, DNAMSPipelineTestHelper.TEST_RESPONSE_JSON));

            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>();
            runCallback(row.Id); // the rule validation queued by completion runs at stopTest (no rules -> GREEN)

            AIReviewStageResult__c saved = reloadRow(row.Id);
            Assert.areEqual(1, DNAMSIDPCalloutMock.getCount, 'getCount has the expected value');
            Assert.areEqual(DNAMSPipelineConstants.ROW_COMPLETED, saved.ProcessingStatus__c, 'ProcessingStatus__c has the expected value');
            Assert.areEqual(DNAMSPipelineConstants.IDP_SUCCEEDED, saved.MuleSoftExecutionStatus__c, 'MuleSoftExecutionStatus__c has the expected value');
            Assert.areEqual(DNAMSPipelineTestHelper.TEST_RESPONSE_JSON, saved.RawStageResponseJSON__c, 'RawStageResponseJSON__c has the expected value');
            Assert.isNotNull(saved.ProcessingCompletedAt__c, 'ProcessingCompletedAt__c is set');
            AI_Package_Review_Run__c run = DNAMSExtractionPipelineTest.reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.RuleValidationProcessingStatus__c, 'Rule validation completed');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_RUNNING, run.Status__c, 'A GREEN run waits for transmittal drafting');
        }
    }

    @IsTest
    static void testExecuteIdpFailedStatusRowErrorAndIdpFailureLog() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            AIReviewStageResult__c row = DNAMSExtractionPipelineTest.insertRow(fixture, ORG_CHART, DNAMSPipelineConstants.ROW_IN_PROGRESS);
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{}', 200, '{"id":"exec-1","status":"FAILED"}'));

            runCallback(row.Id);

            AIReviewStageResult__c saved = reloadRow(row.Id);
            Assert.areEqual(DNAMSPipelineConstants.ROW_ERROR, saved.ProcessingStatus__c, 'ProcessingStatus__c has the expected value');
            Assert.areEqual('FAILED', saved.MuleSoftExecutionStatus__c, 'MuleSoftExecutionStatus__c has the expected value');
            Assert.isTrue(saved.ProcessingErrorDetails__c.contains('FAILED'), saved.ProcessingErrorDetails__c);
            List<AIReviewErrorLog__c> logs = DNAMSExtractionPipelineTest.logsOf(fixture.runId, DNAMSPipelineConstants.ERROR_IDP_FAILURE);
            Assert.areEqual(1, logs.size(), 'Collection size has the expected value');
            Assert.areEqual(row.Id, logs[0].StageResult__c, 'StageResult__c has the expected value');
            AI_Package_Review_Run__c run = DNAMSExtractionPipelineTest.reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, run.ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RESULT_NEEDS_REVIEW, run.Overall_Result__c, 'Overall_Result__c has the expected value');
        }
    }

    @IsTest
    static void testExecuteIdpStillRunningRowStaysInProgress() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            AIReviewStageResult__c row = DNAMSExtractionPipelineTest.insertRow(fixture, ORG_CHART, DNAMSPipelineConstants.ROW_IN_PROGRESS);
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{}', 200, '{"id":"exec-1","status":"IN_PROGRESS"}'));

            runCallback(row.Id);

            AIReviewStageResult__c saved = reloadRow(row.Id);
            Assert.areEqual(DNAMSPipelineConstants.ROW_IN_PROGRESS, saved.ProcessingStatus__c, 'Cleanup or a later callback settles it');
            Assert.areEqual('IN_PROGRESS', saved.MuleSoftExecutionStatus__c, 'MuleSoftExecutionStatus__c has the expected value');
            Assert.isNull(saved.ProcessingCompletedAt__c, 'ProcessingCompletedAt__c is empty');
            Assert.areEqual(0, [SELECT COUNT() FROM AIReviewErrorLog__c WHERE ReviewRun__c = :fixture.runId], 'Record count has the expected value');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_RUNNING, DNAMSExtractionPipelineTest.reloadRun(fixture.runId).Status__c, 'Status__c has the expected value');
        }
    }

    @IsTest
    static void testExecuteHttpErrorRowErrorWithStatusCode() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            AIReviewStageResult__c row = DNAMSExtractionPipelineTest.insertRow(fixture, ORG_CHART, DNAMSPipelineConstants.ROW_IN_PROGRESS);
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{}', 503, 'Service Unavailable'));

            runCallback(row.Id);

            AIReviewStageResult__c saved = reloadRow(row.Id);
            Assert.areEqual(DNAMSPipelineConstants.ROW_ERROR, saved.ProcessingStatus__c, 'ProcessingStatus__c has the expected value');
            Assert.isTrue(saved.ProcessingErrorDetails__c.contains('503'), saved.ProcessingErrorDetails__c);
            Assert.areEqual(1, DNAMSExtractionPipelineTest.logsOf(fixture.runId, DNAMSPipelineConstants.ERROR_IDP_FAILURE).size(), 'logsOf size has the expected value');
        }
    }

    @IsTest
    static void testExecuteCancelledRunCallbackIgnored() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            AIReviewStageResult__c row = DNAMSExtractionPipelineTest.insertRow(fixture, ORG_CHART, DNAMSPipelineConstants.ROW_IN_PROGRESS);
            DNAMS_PackageReviewPipelineService.cancelActiveRun(fixture.packageId);
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{}', 200, DNAMSPipelineTestHelper.TEST_RESPONSE_JSON));

            runCallback(row.Id);

            Assert.areEqual(0, DNAMSIDPCalloutMock.getCount, 'No GET for a run that is not Running');
            Assert.areEqual(DNAMSPipelineConstants.ROW_IN_PROGRESS, reloadRow(row.Id).ProcessingStatus__c, 'ProcessingStatus__c has the expected value');
        }
    }
}