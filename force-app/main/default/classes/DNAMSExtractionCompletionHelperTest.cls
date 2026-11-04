/**
 * @description     Tests for DNAMSExtractionCompletionHelper: all-pass consolidation, schema mismatch, error rows,
 *                  in-flight rows, cancelled runs and the Admin Team email hand-off.
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
private class DNAMSExtractionCompletionHelperTest {
    private static final String TEST_QUEUE = 'DNAMSCompletionTestQueue';
    private static final String MISMATCH_STRUCTURE =
        '{"configuration":{"content":{"output":{"fields":{"SignerName":{"required":false}},"tables":{}}}}}';

    /**
     * @description Narrative writer stub, so the narrative queueable makes no model call.
     **/
    private class StubWriter implements DNAMS_NarrativeWriter {
        /**
         * @description Returns a fixed narrative.
         * @param promptTemplate Ignored
         * @param runId          Ignored
         * @return The narrative
         **/
        public String write(String promptTemplate, Id runId) {
            return 'Stub narrative';
        }
    }

    /**
     * @description Inserts an admin user who is the only member of a test admin queue (setup DML, before runAs).
     * @return The admin user
     **/
    private static User adminInQueue() {
        User admin = DNAMSPipelineTestHelper.getAdminUser();
        Group queue = new Group(Name = TEST_QUEUE, DeveloperName = TEST_QUEUE, Type = 'Queue');
        insert queue;
        insert new GroupMember(GroupId = queue.Id, UserOrGroupId = admin.Id);
        return admin;
    }

    /**
     * @description Points settings at the test queue, stubs the narrative writer and makes every action expect TEST_EXPECTED_STRUCTURE.
     **/
    private static void useTestConfig() {
        DNAMS_Pipeline_Setting__mdt setting = DNAMSPipelineTestHelper.getPipelineSettings();
        setting.AdminQueue__c = TEST_QUEUE;
        DNAMS_PackageReviewPipelineService.settingsOverride = setting;
        DNAMS_PackageNarrativeQueueable.writer = new StubWriter();
        for (String actionName : DNAMSPipelineTestHelper.ACTION_NAME_BY_DOCUMENT_TYPE.values()) {
            DNAMSExtractionCompletionHelper.expectedStructureOverride.put(actionName, DNAMSPipelineTestHelper.TEST_EXPECTED_STRUCTURE);
        }
    }

    /**
     * @description Reloads the run fields set by completion.
     * @param runId The run
     * @return The run
     **/
    private static AI_Package_Review_Run__c reloadRun(Id runId) {
        return [
            SELECT
                Status__c, Overall_Result__c, Ended_At__c, Issue_Summary__c, ExtractionProcessingStatus__c,
                ExtractionSchemaValidation__c, ConsolidatedExtractionJSON__c, Package__r.Health__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
        ];
    }

    /**
     * @description Extraction status keyed by element name.
     * @param packageId The package
     * @return Element by name
     **/
    private static Map<String, DNAMS_Package_Element__c> elementsByName(Id packageId) {
        Map<String, DNAMS_Package_Element__c> byName = new Map<String, DNAMS_Package_Element__c>();
        for (DNAMS_Package_Element__c element : [
            SELECT Name, Extraction_Status__c, Element_Narrative__c
            FROM DNAMS_Package_Element__c
            WHERE Package__c = :packageId
        ]) {
            byName.put(element.Name, element);
        }
        return byName;
    }

    /**
     * @description Names of the queueable classes queued in the test.
     * @return Apex class names
     **/
    private static Set<String> queuedClasses() {
        Set<String> names = new Set<String>();
        for (AsyncApexJob job : [SELECT ApexClass.Name FROM AsyncApexJob WHERE JobType = 'Queueable' LIMIT 50]) {
            names.add(job.ApexClass.Name);
        }
        return names;
    }

    @IsTest
    static void allRowsPassConsolidatesAndStartsRuleValidation() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>();
            useTestConfig();
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            Map<String, AIReviewStageResult__c> rows = DNAMSPipelineTestHelper.createStageResults(fixture, DNAMSPipelineConstants.ROW_COMPLETED);
            insert rows.values();

            Test.startTest();
            DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ fixture.runId });
            Test.stopTest();

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.ExtractionProcessingStatus__c, 'Extraction completes');
            Assert.areEqual(DNAMSPipelineConstants.SCHEMA_PASSED, run.ExtractionSchemaValidation__c, 'Schema passes');
            Map<String, Object> consolidated = (Map<String, Object>) JSON.deserializeUntyped(run.ConsolidatedExtractionJSON__c);
            Assert.areEqual(
                new Set<String>(DNAMSPipelineTestHelper.ACTION_NAME_BY_DOCUMENT_TYPE.values()),
                consolidated.keySet(),
                'One key per IDP action'
            );
            List<Object> utilityBills = (List<Object>) consolidated.get('UtilityBill');
            Map<String, Object> utilityBill = (Map<String, Object>) utilityBills[0];
            Assert.areEqual(String.valueOf(fixture.versionIdByDocumentType.get('Utility Bill')), utilityBill.get('contentVersionId'), 'Version Id kept');
            Assert.areEqual('Address Verification', utilityBill.get('elementType'), 'Element type kept');
            Assert.areEqual('TCE00087', ((Map<String, Object>) utilityBill.get('data')).get('DealerCode'), 'Normalized data kept');
            Assert.isTrue(queuedClasses().contains('DNAMSRuleValidationStarterQueueable'), 'Rule validation queued');
            Assert.areEqual(
                DNAMS_PackageReviewPipelineService.STAGE_PASSED,
                elementsByName(fixture.packageId).get('Org Chart').Extraction_Status__c,
                'Elements pass'
            );
            Assert.areEqual(
                5,
                [SELECT COUNT() FROM AIReviewStageResult__c WHERE SchemaValidationStatus__c = :DNAMSPipelineConstants.SCHEMA_PASSED],
                'Every row is marked Passed'
            );
        }
    }

    @IsTest
    static void schemaMismatchFailsRunAndLogsFields() {
        User admin = adminInQueue();
        System.runAs(admin) {
            useTestConfig();
            DNAMSExtractionCompletionHelper.expectedStructureOverride.put('DealerApplication', MISMATCH_STRUCTURE);
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            insert DNAMSPipelineTestHelper.createStageResults(fixture, DNAMSPipelineConstants.ROW_COMPLETED).values();

            Test.startTest();
            DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ fixture.runId });
            Test.stopTest();

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_COMPLETED, run.Status__c, 'Failed extraction completes the run');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RESULT_NEEDS_REVIEW, run.Overall_Result__c, 'Run needs review');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, run.ExtractionProcessingStatus__c, 'Extraction failed');
            Assert.areEqual(DNAMSPipelineConstants.SCHEMA_FAILED, run.ExtractionSchemaValidation__c, 'Schema failed');
            Assert.areEqual('Red', run.Package__r.Health__c, 'Package health is Red');
            Assert.isNotNull(run.Ended_At__c, 'Run end time set');
            Assert.isTrue(
                run.Issue_Summary__c.startsWith('- Dealer Application / Dealer Application test [Schema Mismatch]: Missing fields: SignerName'),
                run.Issue_Summary__c
            );
            AIReviewErrorLog__c log = [
                SELECT Name, ErrorType__c, MissingFields__c, UnexpectedFields__c, StageResult__c, DocumentType__c
                FROM AIReviewErrorLog__c
                WHERE ReviewRun__c = :fixture.runId
            ];
            Assert.areEqual(DNAMSPipelineConstants.ERROR_SCHEMA_MISMATCH, log.ErrorType__c, 'Schema mismatch logged');
            Assert.areEqual('SignerName', log.MissingFields__c, 'Missing field logged');
            Assert.areEqual('DealerCode', log.UnexpectedFields__c, 'Unexpected field logged');
            Assert.areEqual('Dealer Application', log.DocumentType__c, 'Document type logged');
            Map<String, DNAMS_Package_Element__c> elements = elementsByName(fixture.packageId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_FAILED, elements.get('Dealer Application').Extraction_Status__c, 'Element fails');
            Assert.isTrue(elements.get('Dealer Application').Element_Narrative__c.startsWith('Extraction failed.'), 'Element narrative set');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_PASSED, elements.get('Org Chart').Extraction_Status__c, 'Valid element passes');
            Assert.isTrue(queuedClasses().contains('DNAMS_PackageNarrativeQueueable'), 'Narrative queued');
            Assert.areEqual(1, DNAMSNotificationHelper.sentEmails.size(), 'One admin email for the one queue member');
            Assert.isTrue(DNAMSNotificationHelper.sentEmails[0].getPlainTextBody().contains(log.Name), 'Admin email lists the error log');
        }
    }

    @IsTest
    static void errorAndTimeoutRowsFailRun() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            useTestConfig();
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            Map<String, AIReviewStageResult__c> rows = DNAMSPipelineTestHelper.createStageResults(fixture, DNAMSPipelineConstants.ROW_COMPLETED);
            rows.get('Org Chart').ProcessingStatus__c = DNAMSPipelineConstants.ROW_ERROR;
            rows.get('Utility Bill').ProcessingStatus__c = DNAMSPipelineConstants.ROW_TIMEOUT;
            insert rows.values();

            Test.startTest();
            DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ fixture.runId });
            Test.stopTest();

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, run.ExtractionProcessingStatus__c, 'Extraction failed');
            Assert.areEqual(DNAMSPipelineConstants.SCHEMA_PASSED, run.ExtractionSchemaValidation__c, 'Completed rows still passed the schema');
            Assert.isTrue(run.Issue_Summary__c.contains('- Org Chart / Org Chart test [Error]:'), run.Issue_Summary__c);
            Assert.isTrue(run.Issue_Summary__c.contains('- Address Verification / Utility Bill test [Timeout]:'), run.Issue_Summary__c);
            Assert.isNull(run.ConsolidatedExtractionJSON__c, 'No consolidated JSON on failure');
            Map<String, DNAMS_Package_Element__c> elements = elementsByName(fixture.packageId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_FAILED, elements.get('Address Verification').Extraction_Status__c, 'Timed-out element fails');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_PASSED, elements.get('Dealer Application').Extraction_Status__c, 'Valid element passes');
            Assert.areEqual('Stub narrative', [SELECT AI_Narrative__c FROM DNAMS_Package__c WHERE Id = :fixture.packageId].AI_Narrative__c, 'Narrative written');
            Assert.isTrue(DNAMSNotificationHelper.sentEmails.isEmpty(), 'Test queue does not exist here, so no admin email');
        }
    }

    @IsTest
    static void inFlightRowLeavesRunUntouched() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            useTestConfig();
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            Map<String, AIReviewStageResult__c> rows = DNAMSPipelineTestHelper.createStageResults(fixture, DNAMSPipelineConstants.ROW_COMPLETED);
            rows.get('Org Chart').ProcessingStatus__c = DNAMSPipelineConstants.ROW_IN_PROGRESS;
            insert rows.values();

            Test.startTest();
            DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ fixture.runId });
            Test.stopTest();

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_RUNNING, run.Status__c, 'Run keeps running');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_PENDING, run.ExtractionProcessingStatus__c, 'Extraction not settled');
            Assert.areEqual(0, [SELECT COUNT() FROM AIReviewStageResult__c WHERE SchemaValidationStatus__c != NULL], 'No row validated yet');
            Assert.isTrue(queuedClasses().isEmpty(), 'Nothing queued');
        }
    }

    @IsTest
    static void cancellingRunIsSettledAndNotCompleted() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            useTestConfig();
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            insert DNAMSPipelineTestHelper.createStageResults(fixture, DNAMSPipelineConstants.ROW_COMPLETED).values();
            update new AI_Package_Review_Run__c(Id = fixture.runId, Status__c = DNAMS_PackageReviewPipelineService.RUN_CANCELLING);

            Test.startTest();
            DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ fixture.runId });
            Test.stopTest();

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_CANCELLED, run.Status__c, 'Cancellation settled');
            Assert.isNull(run.ConsolidatedExtractionJSON__c, 'Cancelled run is not consolidated');
        }
    }

    @IsTest
    static void runWithoutRowsPassesWithEmptyConsolidation() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            useTestConfig();
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();

            Test.startTest();
            DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ fixture.runId });
            DNAMSExtractionCompletionHelper.completeExtraction(null);
            Test.stopTest();

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual('{}', run.ConsolidatedExtractionJSON__c, 'Nothing mapped gives an empty consolidation');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.ExtractionProcessingStatus__c, 'Extraction completes');
        }
    }
}
