/**
 * @description     Tests of "Re-run changes only" for the Extraction stage (DNAMSExtractionStarterQueueable): unchanged
 *                  files reuse the baseline extraction without an IDP call, new versions and IDP action version changes
 *                  are sent again, an all-reused run completes extraction at once, and an All run behaves as before.
 *                  IDP is reached only through DNAMSIDPCalloutMock or the stub client.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-10
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-10   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSRerunExtractionTest {
    private static final Integer FILE_COUNT = DNAMSPipelineTestHelper.ELEMENT_TYPE_BY_DOCUMENT_TYPE.size();
    private static final String ORG_CHART = 'Org Chart';
    private static final String DEALER_APPLICATION = 'Dealer Application';
    private static final String CLEANUP_JOB_PREFIX = 'DNAMS IDP cleanup ';

    /**
     * @description Turns the fixture run into a finished baseline: one Completed extraction row per file (real IDP
     *              action ids), completed by DNAMSExtractionCompletionHelper (schema Passed, consolidated JSON), then
     *              the run is marked Completed.
     * @param fixture Extraction fixture
     * @return        Baseline rows keyed by document type
     **/
    private static Map<String, AIReviewStageResult__c> completeBaseline(DNAMSPipelineTestHelper.PipelineFixture fixture) {
        Map<Id, ContentVersion> versionById = new Map<Id, ContentVersion>(
            [SELECT Id, ContentDocumentId, Title, FileExtension FROM ContentVersion WHERE Id IN :fixture.versionIdByDocumentType.values()]
        );
        Map<String, DNAMSIDPWrapper.ActionConfig> actionByType = DNAMSIDPActionUtil.getActionsByDocumentType();
        Map<String, AIReviewStageResult__c> rowByType = DNAMSPipelineTestHelper.createStageResults(fixture, DNAMSPipelineConstants.ROW_COMPLETED);
        for (String documentType : rowByType.keySet()) {
            AIReviewStageResult__c row = rowByType.get(documentType);
            ContentVersion version = versionById.get(fixture.versionIdByDocumentType.get(documentType));
            DNAMSIDPWrapper.ActionConfig action = actionByType.get(documentType.toLowerCase());
            row.ContentDocumentId__c = version.ContentDocumentId;
            row.DocumentTitle__c = version.Title + '.' + version.FileExtension;
            row.IDPActionName__c = action.developerName;
            row.IDPActionId__c = action.actionId;
            row.IDPActionVersion__c = action.actionVersion;
            row.MuleSoftExecutionId__c = 'exec-baseline-' + action.developerName;
            DNAMSExtractionCompletionHelper.expectedStructureOverride.put(action.developerName, DNAMSPipelineTestHelper.TEST_EXPECTED_STRUCTURE);
        }
        Database.insert(rowByType.values(), true);
        DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ fixture.runId });
        Database.update(new AI_Package_Review_Run__c(Id = fixture.runId, Status__c = DNAMS_PackageReviewPipelineService.RUN_COMPLETED), true);
        return rowByType;
    }

    /**
     * @description Inserts the re-run that follows the baseline, ready for extraction.
     * @param fixture Extraction fixture (its run is the baseline)
     * @param mode    DNAMSPipelineConstants.RERUN_MODE_ALL or RERUN_MODE_CHANGES_ONLY
     * @return        The new run id
     **/
    private static Id insertRerun(DNAMSPipelineTestHelper.PipelineFixture fixture, String mode) {
        Boolean isChangesOnly = mode == DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY;
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(
            Package__c = fixture.packageId,
            Status__c = DNAMS_PackageReviewPipelineService.RUN_RUNNING,
            Trigger_Source__c = DNAMS_PackageReviewPipelineService.SOURCE_DEALER_SUBMIT,
            Classification_Processing_Status__c = 'Completed',
            ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_PENDING,
            Started_At__c = System.now(),
            RerunMode__c = mode,
            BaselineRun__c = isChangesOnly ? fixture.runId : null,
            ChangeSummary__c = 'Compared with the baseline.'
        );
        Database.insert(run, true);
        return run.Id;
    }

    /**
     * @description Extraction rows of a run keyed by document type, with the fields the tests assert on.
     * @param runId Run id
     * @return      Rows by DocumentType__c
     **/
    private static Map<String, AIReviewStageResult__c> rowsOf(Id runId) {
        Map<String, AIReviewStageResult__c> rowByType = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : [
            SELECT Id, DocumentType__c, ProcessingStatus__c, ReusedFromResult__c, CallbackToken__c, MuleSoftExecutionId__c,
                IDPActionVersion__c, ContentVersionId__c, SubmittedAt__c, SchemaValidationStatus__c, RawStageResponseJSON__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :runId AND Stage__c = :DNAMSPipelineConstants.STAGE_EXTRACTION
        ]) {
            rowByType.put(row.DocumentType__c, row);
        }
        return rowByType;
    }

    /**
     * @description Reloads a run with the fields the tests assert on.
     * @param runId Run id
     * @return      The run
     **/
    private static AI_Package_Review_Run__c reloadRun(Id runId) {
        return [
            SELECT Status__c, ExtractionProcessingStatus__c, ExtractionSchemaValidation__c, ConsolidatedExtractionJSON__c,
                RuleValidationProcessingStatus__c, ChangeSummary__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
        ];
    }

    /**
     * @description Number of scheduled extraction cleanup jobs for a run.
     * @param runId Run id
     * @return      Job count
     **/
    private static Integer cleanupJobCount(Id runId) {
        String jobName = CLEANUP_JOB_PREFIX + runId + '%';
        return [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :jobName];
    }

    /**
     * @description Live-mode settings with a mocked IDP, so every POST is counted and nothing leaves the org.
     **/
    private static void useMockedIdp() {
        DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_LIVE);
        Test.setMock(HttpCalloutMock.class, new DNAMSIDPCalloutMock(201, '{"id":"exec-rerun-1"}', 200, DNAMSPipelineTestHelper.TEST_RESPONSE_JSON));
    }

    @IsTest
    static void testChangesOnlyAllUnchangedReusesEverythingAndMovesToRuleValidation() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>();
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            useMockedIdp();
            Map<String, AIReviewStageResult__c> baselineRows = completeBaseline(fixture);
            String baselineJson = reloadRun(fixture.runId).ConsolidatedExtractionJSON__c;
            Id rerunId = insertRerun(fixture, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);

            Test.startTest();
            new DNAMSExtractionStarterQueueable(new Set<Id>{ rerunId }).execute(null);
            Test.stopTest(); // the rule validation queued by completion runs here (no rules -> GREEN)

            Assert.areEqual(0, DNAMSIDPCalloutMock.postCount, 'Nothing is sent to IDP when every extraction is reused');
            Assert.areEqual(0, cleanupJobCount(rerunId), 'No timeout cleanup is scheduled when nothing was submitted');
            Map<String, AIReviewStageResult__c> rows = rowsOf(rerunId);
            Assert.areEqual(FILE_COUNT, rows.size(), 'One reused row per file');
            for (String documentType : rows.keySet()) {
                AIReviewStageResult__c row = rows.get(documentType);
                Assert.areEqual(baselineRows.get(documentType).Id, row.ReusedFromResult__c, documentType + ' points at the baseline row');
                Assert.areEqual(DNAMSPipelineConstants.ROW_COMPLETED, row.ProcessingStatus__c, documentType + ' stays Completed');
                Assert.areEqual(DNAMSPipelineConstants.SCHEMA_PASSED, row.SchemaValidationStatus__c, documentType + ' keeps its schema status');
                Assert.areEqual(DNAMSPipelineTestHelper.TEST_RESPONSE_JSON, row.RawStageResponseJSON__c, documentType + ' carries the IDP result');
                Assert.isNull(row.CallbackToken__c, documentType + ' has no callback token');
                Assert.isNull(row.MuleSoftExecutionId__c, documentType + ' has no execution id');
            }
            AI_Package_Review_Run__c run = reloadRun(rerunId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.ExtractionProcessingStatus__c, 'Extraction completes at once');
            Assert.areEqual(DNAMSPipelineConstants.SCHEMA_PASSED, run.ExtractionSchemaValidation__c, 'ExtractionSchemaValidation__c has the expected value');
            Assert.areEqual(baselineJson, run.ConsolidatedExtractionJSON__c, 'Consolidated JSON equals the full run');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.RuleValidationProcessingStatus__c, 'The run moved on to rule validation');
            Assert.isTrue(run.ChangeSummary__c.contains('\nExtraction: ' + FILE_COUNT + ' reused, 0 re-run'), run.ChangeSummary__c);
            for (DNAMS_Package_Element__c element : [SELECT Extraction_Status__c FROM DNAMS_Package_Element__c WHERE Id IN :fixture.elementIdByType.values()]) {
                Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_PASSED, element.Extraction_Status__c, 'Extraction_Status__c has the expected value');
            }
        }
    }

    @IsTest
    static void testChangesOnlyNewVersionIsResubmittedOthersReused() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            useMockedIdp();
            completeBaseline(fixture);
            String baselineJson = reloadRun(fixture.runId).ConsolidatedExtractionJSON__c;
            Id oldVersionId = fixture.versionIdByDocumentType.get(ORG_CHART);
            ContentVersion newVersion = new ContentVersion(
                ContentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :oldVersionId].ContentDocumentId,
                Title = 'Org Chart test',
                PathOnClient = 'Org Chart test.pdf',
                VersionData = Blob.valueOf('%PDF-1.4 Org Chart test v2'),
                DocumentClassifiedAs__c = ORG_CHART
            );
            Database.insert(newVersion, true);
            Id rerunId = insertRerun(fixture, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);

            Test.startTest();
            new DNAMSExtractionStarterQueueable(new Set<Id>{ rerunId }).execute(null);
            Test.stopTest(); // submit batch runs here

            Assert.areEqual(1, DNAMSIDPCalloutMock.postCount, 'Only the new version is sent to IDP');
            Map<String, AIReviewStageResult__c> rows = rowsOf(rerunId);
            Assert.areEqual(FILE_COUNT, rows.size(), 'One row per file');
            AIReviewStageResult__c orgChart = rows.get(ORG_CHART);
            Assert.isNull(orgChart.ReusedFromResult__c, 'The new version is produced in this run');
            Assert.areEqual(DNAMSPipelineConstants.ROW_IN_PROGRESS, orgChart.ProcessingStatus__c, 'The new version waits for its callback');
            Assert.areEqual(String.valueOf(newVersion.Id), orgChart.ContentVersionId__c, 'The latest version is extracted');
            for (String documentType : rows.keySet()) {
                if (documentType != ORG_CHART) {
                    Assert.isNotNull(rows.get(documentType).ReusedFromResult__c, documentType + ' is reused');
                }
            }
            AI_Package_Review_Run__c waiting = reloadRun(rerunId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_IN_PROGRESS, waiting.ExtractionProcessingStatus__c, 'Extraction waits for the re-run file');
            Assert.areEqual(1, cleanupJobCount(rerunId), 'The timeout cleanup covers the submitted file');
            Assert.isTrue(
                waiting.ChangeSummary__c.contains('Extraction: ' + (FILE_COUNT - 1) + ' reused, 1 re-run (Org Chart / Org Chart test.pdf: new version)'),
                waiting.ChangeSummary__c
            );

            // The callback result arrives; completion consolidates reused and fresh rows together
            Database.update(
                new AIReviewStageResult__c(
                    Id = orgChart.Id,
                    ProcessingStatus__c = DNAMSPipelineConstants.ROW_COMPLETED,
                    RawStageResponseJSON__c = DNAMSPipelineTestHelper.TEST_RESPONSE_JSON
                ),
                true
            );
            DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ rerunId });
            AI_Package_Review_Run__c completed = reloadRun(rerunId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, completed.ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');
            Assert.areEqual(
                baselineJson.replace(String.valueOf(oldVersionId), String.valueOf(newVersion.Id)),
                completed.ConsolidatedExtractionJSON__c,
                'Consolidated JSON holds every file, reused and fresh'
            );
        }
    }

    @IsTest
    static void testChangesOnlyIdpActionVersionChangeIsResubmitted() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            useMockedIdp();
            completeBaseline(fixture);
            Map<String, DNAMSIDPWrapper.ActionConfig> actions = new Map<String, DNAMSIDPWrapper.ActionConfig>(DNAMSIDPActionUtil.getActionsByDocumentType());
            DNAMSIDPWrapper.ActionConfig current = actions.get(DEALER_APPLICATION.toLowerCase());
            DNAMSIDPWrapper.ActionConfig bumped = (DNAMSIDPWrapper.ActionConfig) JSON.deserialize(JSON.serialize(current), DNAMSIDPWrapper.ActionConfig.class);
            bumped.actionVersion = '9.9.9';
            actions.put(DEALER_APPLICATION.toLowerCase(), bumped);
            DNAMSIDPActionUtil.actionsOverride = actions;
            Id rerunId = insertRerun(fixture, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);

            Test.startTest();
            new DNAMSExtractionStarterQueueable(new Set<Id>{ rerunId }).execute(null);
            Test.stopTest();

            Assert.areEqual(1, DNAMSIDPCalloutMock.postCount, 'Only the file whose IDP action changed is sent');
            Map<String, AIReviewStageResult__c> rows = rowsOf(rerunId);
            AIReviewStageResult__c dealerApplication = rows.get(DEALER_APPLICATION);
            Assert.isNull(dealerApplication.ReusedFromResult__c, 'The changed action runs again');
            Assert.areEqual('9.9.9', dealerApplication.IDPActionVersion__c, 'The new action version is used');
            Assert.areEqual(DNAMSPipelineConstants.ROW_IN_PROGRESS, dealerApplication.ProcessingStatus__c, 'ProcessingStatus__c has the expected value');
            Assert.isNotNull(rows.get(ORG_CHART).ReusedFromResult__c, 'Unchanged files are reused');
            String summary = reloadRun(rerunId).ChangeSummary__c;
            Assert.isTrue(
                summary.contains('1 re-run (Dealer Application / Dealer Application test.pdf: IDP action version ' + current.actionVersion + ' -> 9.9.9)'),
                summary
            );
        }
    }

    @IsTest
    static void testChangesOnlyReuseOfReusedRowKeepsOriginRow() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            useMockedIdp();
            Map<String, AIReviewStageResult__c> baselineRows = completeBaseline(fixture);
            Id secondRunId = insertRerun(fixture, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);
            new DNAMSExtractionStarterQueueable(new Set<Id>{ secondRunId }).execute(null);
            Database.update(new AI_Package_Review_Run__c(Id = secondRunId, Status__c = DNAMS_PackageReviewPipelineService.RUN_COMPLETED), true);
            AI_Package_Review_Run__c third = new AI_Package_Review_Run__c(
                Package__c = fixture.packageId,
                Status__c = DNAMS_PackageReviewPipelineService.RUN_RUNNING,
                Trigger_Source__c = DNAMS_PackageReviewPipelineService.SOURCE_DEALER_SUBMIT,
                Classification_Processing_Status__c = 'Completed',
                ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_PENDING,
                RerunMode__c = DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY,
                BaselineRun__c = secondRunId
            );
            Database.insert(third, true);

            Test.startTest();
            new DNAMSExtractionStarterQueueable(new Set<Id>{ third.Id }).execute(null);
            Test.stopTest();

            Assert.areEqual(0, DNAMSIDPCalloutMock.postCount, 'Nothing is sent to IDP');
            Map<String, AIReviewStageResult__c> rows = rowsOf(third.Id);
            Assert.areEqual(FILE_COUNT, rows.size(), 'One reused row per file');
            for (String documentType : rows.keySet()) {
                Assert.areEqual(baselineRows.get(documentType).Id, rows.get(documentType).ReusedFromResult__c, documentType + ' points at the origin row');
            }
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, reloadRun(third.Id).ExtractionProcessingStatus__c, 'Extraction completes at once');
        }
    }

    @IsTest
    static void testAllRunSubmitsEveryFileAndKeepsChangeSummary() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            // Stub client: unique execution ids per file, no HTTP
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_STUB);
            completeBaseline(fixture);
            Id rerunId = insertRerun(fixture, DNAMSPipelineConstants.RERUN_MODE_ALL);

            Test.startTest();
            new DNAMSExtractionStarterQueueable(new Set<Id>{ rerunId }).execute(null);
            Test.stopTest();

            Map<String, AIReviewStageResult__c> rows = rowsOf(rerunId);
            Assert.areEqual(FILE_COUNT, rows.size(), 'One row per file');
            for (AIReviewStageResult__c row : rows.values()) {
                Assert.isNull(row.ReusedFromResult__c, row.DocumentType__c + ' is produced in this run');
                Assert.isNotNull(row.SubmittedAt__c, row.DocumentType__c + ' was submitted to IDP');
            }
            AI_Package_Review_Run__c run = reloadRun(rerunId);
            Assert.areEqual('Compared with the baseline.', run.ChangeSummary__c, 'An All run adds no Extraction line');
        }
    }
}
