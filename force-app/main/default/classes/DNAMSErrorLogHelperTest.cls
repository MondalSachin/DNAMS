/**
 * @description     Tests for DNAMSErrorLogHelper: log building and truncation, bulk insert, and logException
 *                  (with and without a run, and never throwing).
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
private class DNAMSErrorLogHelperTest {
    /**
     * @description Exception raised by the tests.
     **/
    private class TestPipelineException extends Exception {
    }

    @IsTest
    static void buildAndInsertLogsKeepsDetail() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
            detail.runId = fixture.runId;
            detail.elementId = fixture.elementIdByType.get('Org Chart');
            detail.errorType = DNAMSPipelineConstants.ERROR_POST;
            detail.sourceClass = 'DNAMSErrorLogHelperTest';
            detail.message = 'POST returned 500';
            detail.documentTitle = 'x'.repeat(300);
            detail.documentType = 'Org Chart';
            detail.rawPayload = '{"error":"server"}';

            Test.startTest();
            DNAMSErrorLogHelper.insertLogs(new List<AIReviewErrorLog__c>{ DNAMSErrorLogHelper.buildLog(detail) });
            DNAMSErrorLogHelper.insertLogs(new List<AIReviewErrorLog__c>());
            Test.stopTest();

            AIReviewErrorLog__c log = [
                SELECT ReviewRun__c, PackageElement__c, Stage__c, Severity__c, ErrorType__c, Message__c, DocumentTitle__c, RawPayload__c
                FROM AIReviewErrorLog__c
            ];
            Assert.areEqual(fixture.runId, log.ReviewRun__c, 'Run linked');
            Assert.areEqual(fixture.elementIdByType.get('Org Chart'), log.PackageElement__c, 'Element linked');
            Assert.areEqual(DNAMSPipelineConstants.STAGE_EXTRACTION, log.Stage__c, 'Extraction stage');
            Assert.areEqual(DNAMSPipelineConstants.SEVERITY_ERROR, log.Severity__c, 'Error severity');
            Assert.areEqual(DNAMSPipelineConstants.ERROR_POST, log.ErrorType__c, 'Error type kept');
            Assert.areEqual(255, log.DocumentTitle__c.length(), 'Title truncated to the field length');
            Assert.areEqual('{"error":"server"}', log.RawPayload__c, 'Raw payload kept separately');
        }
    }

    @IsTest
    static void logExceptionLogsAndFailsRun() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();

            Test.startTest();
            DNAMSErrorLogHelper.logException(new TestPipelineException('boom'), fixture.runId, 'DNAMSErrorLogHelperTest');
            Test.stopTest();

            AIReviewErrorLog__c log = [SELECT ErrorType__c, Message__c, SourceClass__c FROM AIReviewErrorLog__c WHERE ReviewRun__c = :fixture.runId];
            Assert.areEqual(DNAMSPipelineConstants.ERROR_PROCESSING, log.ErrorType__c, 'Processing error logged');
            Assert.isTrue(log.Message__c.contains('boom'), 'Exception message logged');
            Assert.areEqual('DNAMSErrorLogHelperTest', log.SourceClass__c, 'Source class logged');
            AI_Package_Review_Run__c run = [SELECT Status__c, ExtractionProcessingStatus__c FROM AI_Package_Review_Run__c WHERE Id = :fixture.runId];
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_FAILED, run.Status__c, 'Run failed');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, run.ExtractionProcessingStatus__c, 'Extraction stage failed');
        }
    }

    @IsTest
    static void logExceptionWithoutRunOnlyLogs() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            DNAMSErrorLogHelper.logException(new TestPipelineException('no run'), null, 'DNAMSErrorLogHelperTest');
            DNAMSErrorLogHelper.logException(null, null, 'DNAMSErrorLogHelperTest');
            Test.stopTest();

            List<AIReviewErrorLog__c> logs = [SELECT ReviewRun__c, Message__c FROM AIReviewErrorLog__c ORDER BY CreatedDate, Name];
            Assert.areEqual(2, logs.size(), 'Both calls logged');
            Assert.isNull(logs[0].ReviewRun__c, 'No run linked');
            Assert.isTrue(logs[1].Message__c.startsWith('Unknown error'), 'Null exception logged generically');
        }
    }

    @IsTest
    static void logExceptionNeverThrowsForDeletedRun() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            delete new AI_Package_Review_Run__c(Id = fixture.runId);
            Boolean hasThrown = false;

            Test.startTest();
            try {
                DNAMSErrorLogHelper.logException(new TestPipelineException('late'), fixture.runId, 'DNAMSErrorLogHelperTest');
            } catch (Exception e) {
                hasThrown = true;
            }
            Test.stopTest();

            Assert.isFalse(hasThrown, 'The logger swallows its own failures');
        }
    }
}
