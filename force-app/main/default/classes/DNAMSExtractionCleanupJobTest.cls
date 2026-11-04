/**
 * @description     Tests DNAMSExtractionCleanupJob: a final GET for sent rows (finished -> Completed, still running ->
 *                  stranded), never-sent rows time out, one-off scheduling, and no-op on a cancelled run.
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
private class DNAMSExtractionCleanupJobTest {
    @IsTest
    static void testExecuteOpenRowsFailedTimeoutAndRunNeedsReview() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            AIReviewStageResult__c submitted = DNAMSExtractionPipelineTest.insertRow(fixture, 'Org Chart', DNAMSPipelineConstants.ROW_IN_PROGRESS);
            AIReviewStageResult__c pending = DNAMSExtractionPipelineTest.insertRow(fixture, 'Utility Bill', DNAMSPipelineConstants.ROW_PENDING);
            // Both rows have waited longer than the 10 minute timeout
            Datetime longAgo = System.now().addMinutes(-30);
            submitted.SubmittedAt__c = longAgo;
            update as system submitted;
            Test.setCreatedDate(pending.Id, longAgo);
            // IDP still reports the sent row as running at the final check
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{}', 200, '{"id":"exec","status":"IN_PROGRESS"}'));

            Test.startTest();
            new DNAMSExtractionCleanupJob(fixture.runId).execute(null);
            Test.stopTest();

            Assert.areEqual(0, DNAMSIDPCalloutMock.postCount, 'Cleanup never re-submits');
            Assert.areEqual(1, DNAMSIDPCalloutMock.getCount, 'One final GET for the sent row only');
            for (AIReviewStageResult__c row : DNAMSExtractionPipelineTest.rowsByDocumentType(fixture.runId).values()) {
                Assert.areEqual(DNAMSPipelineConstants.ROW_TIMEOUT, row.ProcessingStatus__c, row.DocumentType__c);
                Assert.isNotNull(row.ProcessingCompletedAt__c, 'ProcessingCompletedAt__c is set');
            }
            Assert.areEqual(2, DNAMSExtractionPipelineTest.logsOf(fixture.runId, DNAMSPipelineConstants.ERROR_TIMEOUT).size(), 'logsOf size has the expected value');
            AI_Package_Review_Run__c run = DNAMSExtractionPipelineTest.reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, run.ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RESULT_NEEDS_REVIEW, run.Overall_Result__c, 'Overall_Result__c has the expected value');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_COMPLETED, run.Status__c, 'Status__c has the expected value');
        }
    }

    @IsTest
    static void testScheduleCleanupCreatesOneOffJobAtTimeout() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            String jobName = 'DNAMS IDP cleanup ' + fixture.runId + '%';
            DateTime earliest = DateTime.now().addMinutes(9);

            Test.startTest();
            DNAMSExtractionCleanupJob.scheduleCleanup(fixture.runId, 10);
            // Read before stopTest: stopTest runs the scheduled job immediately
            List<CronTrigger> jobs = [SELECT CronExpression, NextFireTime FROM CronTrigger WHERE CronJobDetail.Name LIKE :jobName];
            Test.stopTest();

            Assert.areEqual(1, jobs.size(), 'Collection size has the expected value');
            Assert.isTrue(jobs[0].CronExpression.endsWith(' ? ' + DateTime.now().addMinutes(10).format('yyyy')), jobs[0].CronExpression);
            Assert.isTrue(jobs[0].NextFireTime >= earliest && jobs[0].NextFireTime <= DateTime.now().addMinutes(11), 'Fires about 10 minutes from now');
        }
    }

    @IsTest
    static void testExecuteCancelledRunSettlesCancellationAndLeavesRows() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            DNAMSExtractionPipelineTest.insertRow(fixture, 'Org Chart', DNAMSPipelineConstants.ROW_IN_PROGRESS);
            DNAMS_PackageReviewPipelineService.cancelActiveRun(fixture.packageId);

            Test.startTest();
            new DNAMSExtractionCleanupJob(fixture.runId).execute(null);
            Test.stopTest();

            Assert.areEqual(
                DNAMSPipelineConstants.ROW_IN_PROGRESS,
                DNAMSExtractionPipelineTest.rowsByDocumentType(fixture.runId).get('Org Chart').ProcessingStatus__c, 'ProcessingStatus__c has the expected value');
            Assert.areEqual(0, [SELECT COUNT() FROM AIReviewErrorLog__c WHERE ReviewRun__c = :fixture.runId], 'Record count has the expected value');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_CANCELLED, DNAMSExtractionPipelineTest.reloadRun(fixture.runId).Status__c, 'Status__c has the expected value');
        }
    }

    /**
     * @description Final check finds the sent row finished at IDP: it is completed like a normal callback, not stranded.
     **/
    @IsTest
    static void testExecuteFinishedAtIdpCompletesInsteadOfTimeout() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            AIReviewStageResult__c submitted = DNAMSExtractionPipelineTest.insertRow(fixture, 'Org Chart', DNAMSPipelineConstants.ROW_IN_PROGRESS);
            submitted.SubmittedAt__c = System.now().addMinutes(-30);
            update as system submitted;
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{}', 200, '{"id":"exec","status":"SUCCEEDED","fields":{},"tables":{}}'));

            Test.startTest();
            new DNAMSExtractionCleanupJob(fixture.runId).execute(null);
            Test.stopTest();

            AIReviewStageResult__c row = DNAMSExtractionPipelineTest.rowsByDocumentType(fixture.runId).get('Org Chart');
            Assert.areEqual(DNAMSPipelineConstants.ROW_COMPLETED, row.ProcessingStatus__c, 'Finished at IDP: completed, not stranded');
            Assert.areEqual(1, DNAMSIDPCalloutMock.getCount, 'One final GET');
            Assert.areEqual(0, DNAMSExtractionPipelineTest.logsOf(fixture.runId, DNAMSPipelineConstants.ERROR_TIMEOUT).size(), 'No timeout log');
        }
    }
}
