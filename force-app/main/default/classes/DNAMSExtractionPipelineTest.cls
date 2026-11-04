/**
 * @description     Functional end-to-end tests of the extraction orchestration (starter → submit batch → callback →
 *                  completion → rule validation placeholder) plus the shared helpers used by the other extraction
 *                  orchestration tests. IDP is reached only through DNAMSIDPCalloutMock or the stub client.
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
public class DNAMSExtractionPipelineTest {
    private static final Integer FILE_COUNT = DNAMSPipelineTestHelper.ELEMENT_TYPE_BY_DOCUMENT_TYPE.size();

    // ------------------------------------------------------------------ shared helpers

    /**
     * @description Installs the test pipeline settings with the given IDP mode.
     * @param idpMode DNAMSPipelineConstants.IDP_MODE_LIVE or IDP_MODE_STUB
     **/
    public static void useSettings(String idpMode) {
        DNAMS_Pipeline_Setting__mdt setting = DNAMSPipelineTestHelper.getPipelineSettings();
        setting.IDPMode__c = idpMode;
        DNAMS_PackageReviewPipelineService.settingsOverride = setting;
    }

    /**
     * @description Inserts an extraction stage row for a fixture document type with its real IDP action ids.
     * @param fixture      Extraction fixture
     * @param documentType Fixture document type, e.g. 'Org Chart'
     * @param status       ProcessingStatus__c value; In Progress rows get execution id 'exec-<IDPActionName__c>'
     * @return             The inserted row
     **/
    public static AIReviewStageResult__c insertRow(DNAMSPipelineTestHelper.PipelineFixture fixture, String documentType, String status) {
        AIReviewStageResult__c row = DNAMSPipelineTestHelper.createStageResults(fixture, status).get(documentType);
        DNAMSIDPWrapper.ActionConfig action = DNAMSIDPActionUtil.getActionsByDocumentType().get(documentType.toLowerCase());
        row.IDPActionId__c = action.actionId;
        row.IDPActionVersion__c = action.actionVersion;
        row.MuleSoftExecutionId__c = status == DNAMSPipelineConstants.ROW_IN_PROGRESS ? 'exec-' + row.IDPActionName__c : null;
        Database.insert(row, true);
        return row;
    }

    /**
     * @description Reloads a run with the fields the extraction tests assert on.
     * @param runId Run id
     * @return      The run
     **/
    public static AI_Package_Review_Run__c reloadRun(Id runId) {
        return [
            SELECT Status__c, Overall_Result__c, Reason__c, Ended_At__c, ExtractionProcessingStatus__c, ExtractionSchemaValidation__c,
                ConsolidatedExtractionJSON__c, Package__r.Health__c, RuleValidationProcessingStatus__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
        ];
    }

    /**
     * @description Stage rows of a run keyed by document type.
     * @param runId Run id
     * @return      Rows by DocumentType__c
     **/
    public static Map<String, AIReviewStageResult__c> rowsByDocumentType(Id runId) {
        Map<String, AIReviewStageResult__c> rowByType = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : [
            SELECT Id, DocumentType__c, ProcessingStatus__c, MuleSoftExecutionId__c, MuleSoftExecutionStatus__c, SubmittedAt__c,
                RawStageResponseJSON__c, ProcessingErrorDetails__c, ProcessingCompletedAt__c, CallbackToken__c, IDPActionName__c,
                ContentVersionId__c, PackageElement__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :runId AND Stage__c = :DNAMSPipelineConstants.STAGE_EXTRACTION
        ]) {
            rowByType.put(row.DocumentType__c, row);
        }
        return rowByType;
    }

    /**
     * @description Error logs of a run by ErrorType__c.
     * @param runId     Run id
     * @param errorType ErrorType__c value
     * @return          Matching logs
     **/
    public static List<AIReviewErrorLog__c> logsOf(Id runId, String errorType) {
        return [SELECT Id, StageResult__c, Message__c FROM AIReviewErrorLog__c WHERE ReviewRun__c = :runId AND ErrorType__c = :errorType];
    }

    // ------------------------------------------------------------------ end-to-end

    @IsTest
    static void testPipelineAllDocumentsSucceedRunCompletesThroughRuleValidation() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            // Stub client: unique execution ids per file and stub results that match each action's expected structure
            useSettings(DNAMSPipelineConstants.IDP_MODE_STUB);

            Test.startTest();
            new DNAMSExtractionStarterQueueable(new Set<Id>{ fixture.runId }).execute(null);
            Test.stopTest(); // submit batch runs here

            Map<String, AIReviewStageResult__c> submitted = rowsByDocumentType(fixture.runId);
            Assert.areEqual(FILE_COUNT, submitted.size(), 'One stage row per classified, mapped file');
            for (AIReviewStageResult__c row : submitted.values()) {
                Assert.areEqual(DNAMSPipelineConstants.ROW_IN_PROGRESS, row.ProcessingStatus__c, row.DocumentType__c + ' is awaiting its callback');
                Assert.isTrue(row.MuleSoftExecutionId__c.startsWith('stub-'), 'Execution id stored');
            }
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_IN_PROGRESS, reloadRun(fixture.runId).ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');

            // Simulate the IDP callbacks (the callback API publishes one event per row; the queueable is what runs)
            new DNAMSIDPCallbackQueueable(new Map<Id, AIReviewStageResult__c>(submitted.values()).keySet()).execute(null);
            AI_Package_Review_Run__c extracted = reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, extracted.ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');
            Assert.areEqual(DNAMSPipelineConstants.SCHEMA_PASSED, extracted.ExtractionSchemaValidation__c, 'ExtractionSchemaValidation__c has the expected value');
            Assert.isTrue(extracted.ConsolidatedExtractionJSON__c.contains('"DealerApplication"'), 'Consolidated JSON is keyed by action');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_RUNNING, extracted.Status__c, 'Run waits for rule validation');
            for (DNAMS_Package_Element__c element : [SELECT Extraction_Status__c FROM DNAMS_Package_Element__c WHERE Id IN :fixture.elementIdByType.values()]) {
                Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_PASSED, element.Extraction_Status__c, 'Extraction_Status__c has the expected value');
            }

            // Nested async does not run in tests: run the rule validation that completion queued (no rules -> GREEN),
            // then the transmittal placeholder that rule validation queued
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>();
            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);
            AI_Package_Review_Run__c validated = reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, validated.RuleValidationProcessingStatus__c, 'Rule validation completes');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_RUNNING, validated.Status__c, 'A GREEN run waits for transmittal drafting');
            new DNAMSTransmittalStarterQueueable(fixture.runId).execute(null);
            AI_Package_Review_Run__c completed = reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_COMPLETED, completed.Status__c, 'Status__c has the expected value');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RESULT_PASSED, completed.Overall_Result__c, 'Overall_Result__c has the expected value');
            Assert.isNotNull(completed.Ended_At__c, 'Ended_At__c is set');
            Assert.isTrue(completed.Reason__c.contains(DNAMSTransmittalStarterQueueable.PLACEHOLDER_REASON), completed.Reason__c);
        }
    }

    @IsTest
    static void testPipelinePostFailsRunNeedsReview() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(500, '{"error":"unavailable"}', 200, '{}'));

            Test.startTest();
            new DNAMSExtractionStarterQueueable(new Set<Id>{ fixture.runId }).execute(null);
            Test.stopTest();

            Assert.areEqual(FILE_COUNT, DNAMSIDPCalloutMock.postCount, 'Every file was submitted once');
            for (AIReviewStageResult__c row : rowsByDocumentType(fixture.runId).values()) {
                Assert.areEqual(DNAMSPipelineConstants.ROW_ERROR, row.ProcessingStatus__c, 'ProcessingStatus__c has the expected value');
                Assert.isTrue(row.ProcessingErrorDetails__c.contains('500'), row.ProcessingErrorDetails__c);
            }
            Assert.areEqual(FILE_COUNT, logsOf(fixture.runId, DNAMSPipelineConstants.ERROR_POST).size(), 'One POST Error log per file');
            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, run.ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RESULT_NEEDS_REVIEW, run.Overall_Result__c, 'Overall_Result__c has the expected value');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_COMPLETED, run.Status__c, 'Status__c has the expected value');
            Assert.areEqual('Red', run.Package__r.Health__c, 'Health__c has the expected value');
        }
    }

    @IsTest
    static void testStarterUnmappedDocumentTypeElementNotApplicable() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            useSettings(DNAMSPipelineConstants.IDP_MODE_STUB);
            Database.update(new ContentVersion(Id = fixture.versionIdByDocumentType.get('Org Chart'), DocumentClassifiedAs__c = 'Bank Statement'), true);

            Test.startTest();
            new DNAMSExtractionStarterQueueable(new Set<Id>{ fixture.runId }).execute(null);
            Test.stopTest();

            Map<String, AIReviewStageResult__c> rows = rowsByDocumentType(fixture.runId);
            Assert.areEqual(FILE_COUNT - 1, rows.size(), 'No stage row for the unmapped file');
            Assert.isFalse(rows.containsKey('Bank Statement'), 'containsKey does not hold');
            Map<Id, DNAMS_Package_Element__c> elements = new Map<Id, DNAMS_Package_Element__c>(
                [SELECT Id, Extraction_Status__c, Current_Stage__c FROM DNAMS_Package_Element__c WHERE Package__c = :fixture.packageId]
            );
            Assert.areEqual(DNAMSPipelineConstants.ELEMENT_NOT_APPLICABLE, elements.get(fixture.elementIdByType.get('Org Chart')).Extraction_Status__c, 'Extraction_Status__c has the expected value');
            DNAMS_Package_Element__c dealerApplication = elements.get(fixture.elementIdByType.get('Dealer Application'));
            Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_IN_PROGRESS, dealerApplication.Extraction_Status__c, 'Extraction_Status__c has the expected value');
            Assert.areEqual(DNAMSPipelineConstants.STAGE_EXTRACTION, dealerApplication.Current_Stage__c, 'Current_Stage__c has the expected value');
        }
    }

    @IsTest
    static void testStarterNothingMappedRunCompletesWithoutIdp() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>();
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
            Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{"id":"exec-1"}', 200, '{}'));
            List<ContentVersion> versions = new List<ContentVersion>();
            for (Id versionId : fixture.versionIdByDocumentType.values()) {
                versions.add(new ContentVersion(Id = versionId, DocumentClassifiedAs__c = 'Bank Statement'));
            }
            Database.update(versions, true);

            Test.startTest();
            new DNAMSExtractionStarterQueueable(new Set<Id>{ fixture.runId }).execute(null);
            Test.stopTest(); // the rule validation queued by completion runs here (no rules -> GREEN)

            Assert.areEqual(0, DNAMSIDPCalloutMock.postCount, 'Nothing is sent to IDP');
            Assert.isTrue(rowsByDocumentType(fixture.runId).isEmpty(), 'isEmpty holds');
            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.RuleValidationProcessingStatus__c, 'Rule validation completes');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_RUNNING, run.Status__c, 'A GREEN run waits for transmittal drafting');
        }
    }

    @IsTest
    static void testPipelineCancelledRunStopsWithoutRowsOrCompletion() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            useSettings(DNAMSPipelineConstants.IDP_MODE_STUB);
            DNAMS_PackageReviewPipelineService.cancelActiveRun(fixture.packageId);

            Test.startTest();
            new DNAMSExtractionStarterQueueable(new Set<Id>{ fixture.runId }).execute(null);
            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);
            Test.stopTest();

            Assert.isTrue(rowsByDocumentType(fixture.runId).isEmpty(), 'A cancelled run creates no stage rows');
            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_CANCELLED, run.Status__c, 'Status__c has the expected value');
            Assert.isNull(run.Overall_Result__c, 'The placeholder does not complete a cancelled run');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_PENDING, run.ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');
        }
    }

    @IsTest
    static void testStarterSeveralRunsProcessesFirstAndRepublishesOthers() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            useSettings(DNAMSPipelineConstants.IDP_MODE_STUB);
            AI_Package_Review_Run__c otherRun = new AI_Package_Review_Run__c(
                Package__c = fixture.packageId,
                Status__c = DNAMS_PackageReviewPipelineService.RUN_COMPLETED
            );
            Database.insert(otherRun, true);

            Test.startTest();
            new DNAMSExtractionStarterQueueable(new Set<Id>{ fixture.runId, otherRun.Id }).execute(null);
            Test.getEventBus().deliver(); // the republished event for the second run reaches the trigger
            Test.stopTest();

            Assert.areEqual(FILE_COUNT, rowsByDocumentType(fixture.runId).size(), 'First run started');
            Assert.isTrue(rowsByDocumentType(otherRun.Id).isEmpty(), 'A run that is not Running is skipped');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_COMPLETED, reloadRun(otherRun.Id).Status__c, 'Status__c has the expected value');
        }
    }

    /** Finalizer context of a job that died with an uncatchable exception. */
    private class FailedJobContext implements FinalizerContext {
        /**
         * @description No job id in a unit test.
         * @return      null
         **/
        public Id getAsyncApexJobId() {
            return null;
        }

        /**
         * @description The simulated failure.
         * @return      The exception
         **/
        public Exception getException() {
            return new DNAMSPipelineException('Simulated limit failure');
        }

        /**
         * @description No request id in a unit test.
         * @return      Empty string
         **/
        public String getRequestId() {
            return '';
        }

        /**
         * @description Unhandled exception result.
         * @return      ParentJobResult.UNHANDLED_EXCEPTION
         **/
        public ParentJobResult getResult() {
            return ParentJobResult.UNHANDLED_EXCEPTION;
        }
    }

    @IsTest
    static void testRunFailureFinalizerUnhandledExceptionFailsRun() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            useSettings(DNAMSPipelineConstants.IDP_MODE_STUB);

            Test.startTest();
            new DNAMSExtractionStarterQueueable.RunFailureFinalizer(new Set<Id>{ fixture.runId }, 'TestJob').execute(new FailedJobContext());
            Test.stopTest();

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_FAILED, run.Status__c, 'An unhandled job failure fails the run');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, run.ExtractionProcessingStatus__c, 'Failure is recorded on the extraction stage');
            Assert.areEqual(1, logsOf(fixture.runId, DNAMSPipelineConstants.ERROR_PROCESSING).size(), 'One Processing Error log');
        }
    }
}
